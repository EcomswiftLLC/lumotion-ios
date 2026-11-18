import Foundation
import CoreGraphics

// MARK: - Camera poses

/// Where the virtual camera is at one moment: zoom, offset of the view centre (as a share of the frame) and rotation.
struct CameraPose {
    var zoom: Float = 1
    var offX: Float = 0
    var offY: Float = 0
    var rotation: Float = 0

    var isIdentity: Bool { zoom == 1 && offX == 0 && offY == 0 && rotation == 0 }
}

enum CameraMath {
    /// Progress 0...1 for zoom and pan. With `loops` it goes there and back so frame N equals frame 0.
    static func progress(_ p: Double, loops: Bool, easing: Easing) -> Double {
        let t = loops ? 1 - abs(2 * p - 1) : p
        return easing.apply(t)
    }

    /// The camera pose at loop phase `p`. `frameAspect` is the longer side divided by the shorter side of the frame.
    static func pose(_ cam: CameraMotion, phase p: Double, frameAspect: Double) -> CameraPose {
        let amount = min(max(cam.amount, 0), 1)
        let twoPi = 2 * Double.pi
        var pose = CameraPose()
        switch cam.kind {
        case .none:
            break
        case .zoomIn:
            let e = progress(p, loops: cam.loops, easing: cam.easing)
            pose.zoom = Float(1 + 0.35 * amount * e)
        case .zoomOut:
            let e = progress(p, loops: cam.loops, easing: cam.easing)
            pose.zoom = Float(1 + 0.35 * amount * (1 - e))
        case .pan:
            let e = progress(p, loops: cam.loops, easing: cam.easing)
            let m = 0.12 * amount
            let v = cam.direction.vector
            pose.zoom = Float(1 + 2 * m)
            pose.offX = Float(v.x * m * (2 * e - 1))
            pose.offY = Float(v.y * m * (2 * e - 1))
        case .drift:
            let m = 0.06 * amount
            pose.zoom = Float(1 + 2.2 * m)
            pose.offX = Float(m * sin(twoPi * p))
            pose.offY = Float(m * 0.7 * sin(2 * twoPi * p))
        case .rotate:
            let rm = 0.10 * amount
            pose.rotation = Float(rm * sin(twoPi * p))
            pose.zoom = Float(cos(rm) + frameAspect * sin(rm))
        case .shake:
            let m = 0.012 * amount
            pose.zoom = Float(1 + 3 * m)
            pose.offX = Float(m * (0.6 * sin(twoPi * 3 * p + 1.1) + 0.4 * sin(twoPi * 7 * p + 0.3)))
            pose.offY = Float(m * (0.5 * sin(twoPi * 4 * p + 2.1) + 0.5 * sin(twoPi * 5 * p + 0.7)))
            pose.rotation = Float(0.004 * amount * sin(twoPi * 2 * p + 0.5))
        case .breathe:
            pose.zoom = Float(1 + 0.06 * amount * (1 - cos(twoPi * p)) / 2)
        case .custom:
            let e = progress(p, loops: cam.loops, easing: cam.easing)
            pose.zoom = Float(cam.start.zoom + (cam.end.zoom - cam.start.zoom) * e)
            pose.offX = Float(cam.start.offsetX + (cam.end.offsetX - cam.start.offsetX) * e)
            pose.offY = Float(cam.start.offsetY + (cam.end.offsetY - cam.start.offsetY) * e)
            pose.rotation = Float((cam.start.rotation + (cam.end.rotation - cam.start.rotation) * e) * Double.pi / 180)
        }
        pose.zoom = max(0.2, pose.zoom)
        return pose
    }
}

// MARK: - Depth

enum DepthBuilder {
    /// The depth source that will really be used: falls back to the gradient when the chosen one is not available.
    static func effectiveSource(_ settings: ParallaxSettings, subject: MaskBuffer?, embedded: MaskBuffer?) -> DepthSource {
        switch settings.depthSource {
        case .subjectMask: return subject != nil ? .subjectMask : .gradient
        case .embeddedDepth: return embedded != nil ? .embeddedDepth : .gradient
        case .manualBrush: return settings.depthStrokes.isEmpty ? .gradient : .manualBrush
        case .gradient: return .gradient
        }
    }

    /// Depth in canvas space, 1 is near and 0 is far, at working resolution.
    static func build(settings: ParallaxSettings, subject: MaskBuffer?, embedded: MaskBuffer?, mapping: CanvasMapping,
                      sourceAspect: Double, canvasW: Int, canvasH: Int) -> FloatField {
        let work = StrokeRaster.size(aspect: Double(canvasW) / Double(max(1, canvasH)), longEdge: 384)
        let ww = work.width, wh = work.height
        let blurRadius = max(1, ww / 48)
        var depth = [UInt8](repeating: 0, count: ww * wh)
        func gradientValue(_ j: Int) -> Float { (Float(j) + 0.5) / Float(wh) }
        switch effectiveSource(settings, subject: subject, embedded: embedded) {
        case .subjectMask:
            let canvasSubject = StrokeRaster.blur(StrokeRaster.toCanvas(subject!, mapping: mapping, width: ww, height: wh), radius: blurRadius, passes: 2)
            for j in 0..<wh {
                let bg = 0.05 + 0.3 * gradientValue(j)
                for i in 0..<ww {
                    let s = Float(canvasSubject.data[j * ww + i]) / 255
                    let d = bg * (1 - s) + 0.95 * s
                    depth[j * ww + i] = UInt8(min(255, max(0, d * 255)))
                }
            }
        case .embeddedDepth:
            let canvasDepth = StrokeRaster.blur(StrokeRaster.toCanvas(embedded!, mapping: mapping, width: ww, height: wh), radius: max(1, blurRadius / 2), passes: 2)
            var lo: UInt8 = 255, hi: UInt8 = 0
            for v in canvasDepth.data { lo = min(lo, v); hi = max(hi, v) }
            let span = Float(max(1, Int(hi) - Int(lo)))
            for i in 0..<depth.count {
                depth[i] = UInt8(min(255, max(0, (Float(canvasDepth.data[i]) - Float(lo)) / span * 255)))
            }
        case .manualBrush:
            let srcSize = StrokeRaster.size(aspect: sourceAspect, longEdge: 384)
            var base = [UInt8](repeating: 0, count: srcSize.width * srcSize.height)
            for j in 0..<srcSize.height {
                let v = (Float(j) + 0.5) / Float(srcSize.height)
                let value = UInt8(min(255, max(0, (0.05 + 0.3 * v) * 255)))
                for i in 0..<srcSize.width { base[j * srcSize.width + i] = value }
            }
            let painted = StrokeRaster.paintDepth(settings.depthStrokes, base: MaskBuffer(width: srcSize.width, height: srcSize.height, data: base))
            let canvasDepth = StrokeRaster.blur(StrokeRaster.toCanvas(painted, mapping: mapping, width: ww, height: wh, outside: 0), radius: max(1, blurRadius / 2), passes: 2)
            depth = canvasDepth.data
        case .gradient:
            for j in 0..<wh {
                let value = UInt8(min(255, max(0, gradientValue(j) * 255)))
                for i in 0..<ww { depth[j * ww + i] = value }
            }
        }
        let field = FloatField(width: ww, height: wh)
        for i in 0..<(ww * wh) {
            let d = Float(depth[i]) / 255
            field.data[i] = settings.invertDepth ? 1 - d : d
        }
        return field
    }
}

// MARK: - Geometry stage

/// Maps every output pixel to a position in the picture, combining the camera pose and the parallax shift.
struct GeometryMap {
    let w: Float
    let h: Float
    let offXpx: Float
    let offYpx: Float
    let invZoom: Float
    let cosR: Float
    let sinR: Float
    let depth: FloatField?
    let focus: Float
    let shiftX: Float
    let shiftY: Float
    let dolly: Float

    var isIdentity: Bool { depth == nil && offXpx == 0 && offYpx == 0 && invZoom == 1 && sinR == 0 }

    init(width: Int, height: Int, pose: CameraPose, parallax: ParallaxSettings?, depth: FloatField?, phase p: Double) {
        w = Float(width)
        h = Float(height)
        offXpx = pose.offX * w
        offYpx = pose.offY * h
        cosR = cos(pose.rotation)
        sinR = sin(pose.rotation)
        var zoom = pose.zoom
        var sx: Float = 0, sy: Float = 0, dol: Float = 0
        if let par = parallax, par.enabled, let depth {
            let s = Float(min(max(par.strength, 0), 1))
            let twoPi = 2 * Float.pi
            let q = Float(p)
            let tri = 1 - abs(2 * q - 1)
            let ease = tri * tri * (3 - 2 * tri)
            let long = max(w, h)
            switch par.style {
            case .dolly:
                dol = ease * s * 0.14
            case .push:
                dol = ease * s * 0.18
                zoom *= 1 + 0.5 * ease * s * 0.1
            case .orbit:
                sx = -cos(twoPi * q) * s * 0.05 * long
                sy = -sin(twoPi * q) * s * 0.03 * long
            case .swing:
                sx = -sin(twoPi * q) * s * 0.05 * long
            }
            zoom *= 1 + 0.12 * s
            self.depth = depth
        } else {
            self.depth = nil
        }
        invZoom = 1 / zoom
        shiftX = sx
        shiftY = sy
        dolly = dol
        focus = 0.5
    }

    /// Source position for the output pixel (x, y).
    @inline(__always)
    func map(_ x: Float, _ y: Float) -> (Float, Float) {
        let relx = x - w * 0.5
        let rely = y - h * 0.5
        let px = w * 0.5 + offXpx + (cosR * relx - sinR * rely) * invZoom
        let py = h * 0.5 + offYpx + (sinR * relx + cosR * rely) * invZoom
        guard let depth else { return (px, py) }
        var sx = px, sy = py
        for _ in 0..<2 {
            let d = depth.sample(u: sx / w, v: sy / h)
            let delta = d - focus
            let zf = 1 + dolly * (0.25 + d)
            sx = w * 0.5 + (px - w * 0.5) / zf + shiftX * delta * 2
            sy = h * 0.5 + (py - h * 0.5) / zf + shiftY * delta * 2
        }
        return (sx, sy)
    }
}

enum GeometryStage {
    /// Reflects a coordinate back into 0...n-1.
    @inline(__always)
    static func reflect(_ v: Float, _ n: Float) -> Float {
        let span = n - 1
        if span <= 0 { return 0 }
        let period = 2 * span
        var t = v.truncatingRemainder(dividingBy: period)
        if t < 0 { t += period }
        return t > span ? period - t : t
    }

    /// A small blurred copy of a frame (1/8 size) used to fill picture area that the camera reveals.
    static func blurredSmall(_ src: PixelBuffer) -> PixelBuffer {
        let f = 8
        let sw = max(1, src.width / f), sh = max(1, src.height / f)
        let small = PixelBuffer(width: sw, height: sh)
        for y in 0..<sh {
            for x in 0..<sw {
                var b = 0, g = 0, r = 0, a = 0, n = 0
                for yy in (y * f)..<min(src.height, y * f + f) {
                    for xx in (x * f)..<min(src.width, x * f + f) {
                        let i = (yy * src.width + xx) * 4
                        b += Int(src.data[i]); g += Int(src.data[i + 1]); r += Int(src.data[i + 2]); a += Int(src.data[i + 3]); n += 1
                    }
                }
                let o = (y * sw + x) * 4
                if n > 0 {
                    small.data[o] = UInt8(b / n); small.data[o + 1] = UInt8(g / n); small.data[o + 2] = UInt8(r / n); small.data[o + 3] = UInt8(a / n)
                }
            }
        }
        // Two quick box passes on the small picture.
        for _ in 0..<2 {
            let tmp = small.clone()
            for y in 0..<sh {
                for x in 0..<sw {
                    var acc = (0, 0, 0, 0)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let xx = min(max(x + dx, 0), sw - 1), yy = min(max(y + dy, 0), sh - 1)
                            let i = (yy * sw + xx) * 4
                            acc.0 += Int(tmp.data[i]); acc.1 += Int(tmp.data[i + 1]); acc.2 += Int(tmp.data[i + 2]); acc.3 += Int(tmp.data[i + 3])
                        }
                    }
                    let o = (y * sw + x) * 4
                    small.data[o] = UInt8(acc.0 / 9); small.data[o + 1] = UInt8(acc.1 / 9); small.data[o + 2] = UInt8(acc.2 / 9); small.data[o + 3] = UInt8(acc.3 / 9)
                }
            }
        }
        return small
    }

    /// Resamples `src` through `map`. Positions outside the picture follow `edge`.
    static func render(_ src: PixelBuffer, map: GeometryMap, edge: EdgeFill) -> PixelBuffer {
        let w = src.width, h = src.height
        let out = PixelBuffer(width: w, height: h)
        let blurred: PixelBuffer? = (edge == .blur && map.depth != nil) ? blurredSmall(src) : nil
        let srcPtr = UnsafePointer<UInt8>(src.data)
        let outPtr = out.data
        let wf = Float(w - 1), hf = Float(h - 1)
        let bw = blurred?.width ?? 1, bh = blurred?.height ?? 1
        let blurPtr: UnsafePointer<UInt8>? = blurred.map { UnsafePointer<UInt8>($0.data) }
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                for x in 0..<w {
                    var (sx, sy) = map.map(Float(x), Float(y))
                    var px: Pix4
                    let outside = sx < -0.5 || sy < -0.5 || sx > wf + 0.5 || sy > hf + 0.5
                    if outside && edge == .mirror {
                        sx = reflect(sx, Float(w)); sy = reflect(sy, Float(h))
                        px = bilinear(srcPtr, w, h, sx, sy)
                    } else if outside, edge == .blur, let bp = blurPtr {
                        px = bilinear(bp, bw, bh, (sx + 0.5) / 8 - 0.5, (sy + 0.5) / 8 - 0.5)
                    } else {
                        px = bilinear(srcPtr, w, h, sx, sy)
                    }
                    let i = (y * w + x) * 4
                    outPtr[i] = clamp255(px.b)
                    outPtr[i + 1] = clamp255(px.g)
                    outPtr[i + 2] = clamp255(px.r)
                    outPtr[i + 3] = clamp255(px.a)
                }
            }
        }
        return out
    }

    /// The subject mask carried through the same camera and parallax motion, so overlays can be placed behind the subject.
    static func warpField(_ field: FloatField, map: GeometryMap, width w: Int, height h: Int) -> FloatField {
        let out = FloatField(width: w, height: h)
        let outPtr = out.data
        let invW = 1 / Float(w), invH = 1 / Float(h)
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                for x in 0..<w {
                    let (sx, sy) = map.map(Float(x), Float(y))
                    outPtr[y * w + x] = field.sample(u: sx * invW, v: sy * invH)
                }
            }
        }
        return out
    }
}
