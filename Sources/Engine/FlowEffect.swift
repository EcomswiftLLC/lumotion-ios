import Foundation
import CoreGraphics

/// A one-channel Float picture with a raw pointer for fast sampling in inner loops.
final class FloatField {
    let w: Int
    let h: Int
    let data: UnsafeMutablePointer<Float>

    init(width: Int, height: Int) {
        w = max(1, width)
        h = max(1, height)
        data = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        data.initialize(repeating: 0, count: w * h)
    }

    convenience init(mask: MaskBuffer) {
        self.init(width: mask.width, height: mask.height)
        for i in 0..<(w * h) { data[i] = Float(mask.data[i]) / 255 }
    }

    deinit { data.deallocate() }

    var byteCost: Int { w * h * 4 }

    /// Sample with canvas-normalised coordinates u, v in 0...1.
    @inline(__always)
    func sample(u: Float, v: Float) -> Float {
        bilinearField(data, w, h, u * Float(w) - 0.5, v * Float(h) - 0.5)
    }
}

/// A painted flow region baked into canvas space at working resolution: how much each pixel is affected and which way it flows.
final class FlowField {
    let mask: FloatField
    let dx: FloatField
    let dy: FloatField
    /// Normalised bounds (0...1) of the area where the mask is above a small threshold.
    let minU: Float
    let minV: Float
    let maxU: Float
    let maxV: Float
    let hasMotion: Bool

    init(mask: FloatField, dx: FloatField, dy: FloatField, minU: Float, minV: Float, maxU: Float, maxV: Float, hasMotion: Bool) {
        self.mask = mask; self.dx = dx; self.dy = dy
        self.minU = minU; self.minV = minV; self.maxU = maxU; self.maxV = maxV
        self.hasMotion = hasMotion
    }

    var byteCost: Int { mask.byteCost * 3 }

    /// Bakes a region for a canvas of `canvasW` x `canvasH` pixels. Nil when nothing is painted.
    static func bake(region: FlowRegion, mapping: CanvasMapping, sourceAspect: Double, canvasW: Int, canvasH: Int) -> FlowField? {
        let src = StrokeRaster.size(aspect: sourceAspect, longEdge: 768)
        guard let painted = StrokeRaster.paintMask(region.strokes, width: src.width, height: src.height,
                                                   featherBoost: min(max(region.softness, 0), 1) * 0.5) else { return nil }
        let long = 384
        let work = StrokeRaster.size(aspect: Double(canvasW) / Double(max(1, canvasH)), longEdge: long)
        let ww = work.width, wh = work.height
        let canvasMask = StrokeRaster.toCanvas(painted, mapping: mapping, width: ww, height: wh)
        let mask = FloatField(mask: canvasMask)
        let fdx = FloatField(width: ww, height: wh)
        let fdy = FloatField(width: ww, height: wh)

        // Arrows in canvas pixel units.
        struct Seg { var ax: Float; var ay: Float; var bx: Float; var by: Float; var ux: Float; var uy: Float }
        var segs = [Seg]()
        let cw = Float(canvasW), ch = Float(canvasH)
        for arrow in region.arrows {
            let a = mapping.toCanvas(arrow.from)
            let b = mapping.toCanvas(arrow.to)
            let ax = Float(a.x) * cw, ay = Float(a.y) * ch, bx = Float(b.x) * cw, by = Float(b.y) * ch
            let len = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
            if len < 0.5 { continue }
            segs.append(Seg(ax: ax, ay: ay, bx: bx, by: by, ux: (bx - ax) / len, uy: (by - ay) / len))
        }
        let eps = (0.06 * max(cw, ch)) * (0.06 * max(cw, ch))
        var minU: Float = 1, minV: Float = 1, maxU: Float = 0, maxV: Float = 0
        for j in 0..<wh {
            let v = (Float(j) + 0.5) / Float(wh)
            for i in 0..<ww {
                let u = (Float(i) + 0.5) / Float(ww)
                let idx = j * ww + i
                if mask.data[idx] > 0.004 {
                    minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
                }
                if segs.isEmpty { continue }
                let px = u * cw, py = v * ch
                var sx: Float = 0, sy: Float = 0, sw: Float = 0
                for s in segs {
                    let abx = s.bx - s.ax, aby = s.by - s.ay
                    let len2 = abx * abx + aby * aby
                    let t = min(max(((px - s.ax) * abx + (py - s.ay) * aby) / len2, 0), 1)
                    let ex = px - (s.ax + abx * t), ey = py - (s.ay + aby * t)
                    let wgt = 1 / (ex * ex + ey * ey + eps)
                    sx += s.ux * wgt; sy += s.uy * wgt; sw += wgt
                }
                fdx.data[idx] = sx / sw
                fdy.data[idx] = sy / sw
            }
        }
        if maxU < minU { return nil }
        return FlowField(mask: mask, dx: fdx, dy: fdy, minU: minU, minV: minV, maxU: maxU, maxV: maxV, hasMotion: !segs.isEmpty)
    }
}

/// The two-phase flow warp. Every pixel samples the picture twice, a half cycle apart, and the two samples are
/// cross-faded with a triangle weight that is zero exactly when a sample jumps back to its start. After a whole number
/// of cycles every term repeats exactly, so the loop closes without a seam.
enum FlowApply {
    /// - Parameters:
    ///   - src: the untouched picture to sample from.
    ///   - dst: receives the result; it already holds a copy of the picture (or earlier effects) and only masked pixels change.
    ///   - phase: loop phase 0...1.
    ///   - cycles: whole number of flow cycles per loop (at least 1).
    ///   - cycleScale: real cycles divided by `cycles`, so non-integer speeds still move at the right rate.
    static func apply(field: FlowField, region: FlowRegion, src: PixelBuffer, dst: PixelBuffer, phase: Double, cycles: Int, cycleScale: Double) {
        guard field.hasMotion else { return }
        let w = dst.width, h = dst.height
        let s = Float(max(w, h))
        let amplitude = Float(min(max(region.strength, 0), 1)) * 0.08 * s * Float(cycleScale)
        if amplitude < 0.01 { return }
        let t = Float(phase) * Float(cycles)
        let x0 = max(0, Int((field.minU * Float(w)).rounded(.down)) - 2)
        let x1 = min(w - 1, Int((field.maxU * Float(w)).rounded(.up)) + 2)
        let y0 = max(0, Int((field.minV * Float(h)).rounded(.down)) - 2)
        let y1 = min(h - 1, Int((field.maxV * Float(h)).rounded(.up)) + 2)
        if x1 < x0 || y1 < y0 { return }
        let srcPtr = UnsafePointer<UInt8>(src.data)
        let dstPtr = dst.data
        let mask = field.mask, fdx = field.dx, fdy = field.dy
        let invW = 1 / Float(w), invH = 1 / Float(h)
        parallelRows(y0, y1 + 1) { ra, rb in
            for y in ra..<rb {
                let v = (Float(y) + 0.5) * invH
                for x in x0...x1 {
                    let u = (Float(x) + 0.5) * invW
                    let m = mask.sample(u: u, v: v)
                    if m < 0.004 { continue }
                    let ddx = fdx.sample(u: u, v: v)
                    let ddy = fdy.sample(u: u, v: v)
                    // A little spatial variation in timing keeps the cross-fade from pumping everywhere at once.
                    let jitter = (valueNoise(Float(x) / s * 5, Float(y) / s * 5, 31) - 0.5) * 0.3
                    var f0 = t + jitter
                    f0 -= f0.rounded(.down)
                    let f1 = f0 >= 0.5 ? f0 - 0.5 : f0 + 0.5
                    let w0 = 1 - abs(1 - 2 * f0)
                    let w1 = 1 - w0
                    let o0 = (f0 - 0.5) * amplitude
                    let o1 = (f1 - 0.5) * amplitude
                    let a = bilinear(srcPtr, w, h, Float(x) - ddx * o0, Float(y) - ddy * o0)
                    let b = bilinear(srcPtr, w, h, Float(x) - ddx * o1, Float(y) - ddy * o1)
                    let i = (y * w + x) * 4
                    let inv = 1 - m
                    dstPtr[i] = clamp255(Float(dstPtr[i]) * inv + (a.b * w0 + b.b * w1) * m)
                    dstPtr[i + 1] = clamp255(Float(dstPtr[i + 1]) * inv + (a.g * w0 + b.g * w1) * m)
                    dstPtr[i + 2] = clamp255(Float(dstPtr[i + 2]) * inv + (a.r * w0 + b.r * w1) * m)
                    dstPtr[i + 3] = clamp255(Float(dstPtr[i + 3]) * inv + (a.a * w0 + b.a * w1) * m)
                }
            }
        }
    }
}
