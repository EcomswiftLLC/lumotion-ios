import Foundation
import CoreGraphics

/// Steadies a hand-held clip: every frame is shifted by one global translation so that it lines up with the frozen
/// picture of the cinemagraph. The shift is found by a search on a small brightness copy of the frames (the sum of
/// squared differences over the overlapping area, refined to a fraction of a pixel), so it needs no extra memory worth
/// mentioning and gives the same answer on every device.
///
/// What it does: removes slow drift and shake of the whole picture. What it does not do: rotation, zoom or perspective
/// changes, or parallax. The part of the picture that moves on purpose pulls the estimate a little, which is why the
/// search is limited to a small range and the moving area is normally small in a cinemagraph.
enum Stabilizer {
    /// A brightness picture reduced by a whole number `scale` from the frame it came from.
    struct Grid {
        let width: Int
        let height: Int
        let scale: Int
        var luma: [Float]
    }

    /// Longest side of the brightness copies the search runs on.
    static let analysisEdge = 96

    /// Brightness (0...255) of `buffer`, averaged in blocks so the long side is at most about `longEdge`.
    static func grid(_ buffer: PixelBuffer, longEdge: Int = analysisEdge) -> Grid {
        let f = max(1, Int((Double(max(buffer.width, buffer.height)) / Double(max(8, longEdge))).rounded(.up)))
        let gw = max(1, buffer.width / f), gh = max(1, buffer.height / f)
        var luma = [Float](repeating: 0, count: gw * gh)
        let src = buffer.data
        let w = buffer.width
        let norm = 1 / Float(f * f)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var sum: Float = 0
                for yy in 0..<f {
                    let row = ((gy * f + yy) * w + gx * f) * 4
                    for xx in 0..<f {
                        let i = row + xx * 4
                        sum += 0.114 * Float(src[i]) + 0.587 * Float(src[i + 1]) + 0.299 * Float(src[i + 2])
                    }
                }
                luma[gy * gw + gx] = sum * norm
            }
        }
        return Grid(width: gw, height: gh, scale: f, luma: luma)
    }

    /// The offset `(dx, dy)` in grid pixels for which `reference(x, y)` best matches `image(x + dx, y + dy)`. Searches
    /// whole-pixel offsets up to `maxShift` and refines the best one to a fraction of a pixel. Prefers no shift when
    /// the picture has too little detail to tell.
    static func shift(of image: Grid, relativeTo reference: Grid, maxShift: Int) -> (dx: Double, dy: Double) {
        guard image.width == reference.width, image.height == reference.height else { return (0, 0) }
        let w = image.width, h = image.height
        let r = max(0, min(maxShift, min(w, h) / 4))
        if r == 0 { return (0, 0) }
        let side = 2 * r + 1
        var cost = [Float](repeating: .greatestFiniteMagnitude, count: side * side)
        image.luma.withUnsafeBufferPointer { img in
            reference.luma.withUnsafeBufferPointer { ref in
                for sy in -r...r {
                    let y0 = max(0, -sy), y1 = min(h, h - sy)
                    for sx in -r...r {
                        let x0 = max(0, -sx), x1 = min(w, w - sx)
                        var sum: Float = 0
                        for y in y0..<y1 {
                            let a = y * w, b = (y + sy) * w + sx
                            for x in x0..<x1 {
                                let d = ref[a + x] - img[b + x]
                                sum += d * d
                            }
                        }
                        cost[(sy + r) * side + (sx + r)] = sum / Float(max(1, (x1 - x0) * (y1 - y0)))
                    }
                }
            }
        }
        // Start from "no shift" and only move away when another offset is clearly better.
        var bestX = 0, bestY = 0
        var best = cost[r * side + r]
        for sy in -r...r {
            for sx in -r...r {
                let c = cost[(sy + r) * side + (sx + r)]
                if c < best * 0.995 - 0.0001 { best = c; bestX = sx; bestY = sy }
            }
        }
        func at(_ x: Int, _ y: Int) -> Float { cost[(y + r) * side + (x + r)] }
        var fx = 0.0, fy = 0.0
        if abs(bestX) < r {
            let a = at(bestX - 1, bestY), b = at(bestX, bestY), c = at(bestX + 1, bestY)
            let denom = a - 2 * b + c
            if denom > 1e-6 { fx = Double(min(max(0.5 * (a - c) / denom, -0.5), 0.5)) }
        }
        if abs(bestY) < r {
            let a = at(bestX, bestY - 1), b = at(bestX, bestY), c = at(bestX, bestY + 1)
            let denom = a - 2 * b + c
            if denom > 1e-6 { fy = Double(min(max(0.5 * (a - c) / denom, -0.5), 0.5)) }
        }
        return (Double(bestX) + fx, Double(bestY) + fy)
    }

    /// `buffer` resampled so that the output at (x, y) is the input at (x + dx, y + dy), with the edge pixels repeated.
    static func shifted(_ buffer: PixelBuffer, dx: Double, dy: Double) -> PixelBuffer {
        let out = PixelBuffer(width: buffer.width, height: buffer.height)
        let w = buffer.width, h = buffer.height
        let src = UnsafePointer<UInt8>(buffer.data)
        let dst = out.data
        let fx = Float(dx), fy = Float(dy)
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                for x in 0..<w {
                    let p = bilinear(src, w, h, Float(x) + fx, Float(y) + fy)
                    let i = (y * w + x) * 4
                    dst[i] = clamp255(p.b); dst[i + 1] = clamp255(p.g); dst[i + 2] = clamp255(p.r); dst[i + 3] = clamp255(p.a)
                }
            }
        }
        return out
    }

    /// The shift of `frame` against `reference` in the frames' own pixels.
    static func shift(of frame: PixelBuffer, relativeTo reference: PixelBuffer) -> (dx: Double, dy: Double) {
        let ref = grid(reference)
        let img = grid(frame)
        let s = shift(of: img, relativeTo: ref, maxShift: max(2, ref.width / 12))
        return (s.dx * Double(ref.scale), s.dy * Double(ref.scale))
    }

    /// Every frame shifted onto `reference`. Frames that already line up (less than a tenth of a pixel off) are returned as they are.
    static func align(_ frames: [PixelBuffer], to reference: PixelBuffer, token: RenderToken? = nil) -> [PixelBuffer] {
        let ref = grid(reference)
        let range = max(2, ref.width / 12)
        var out = [PixelBuffer]()
        out.reserveCapacity(frames.count)
        for frame in frames {
            if token?.isCancelled == true { return frames }
            guard frame.width == reference.width, frame.height == reference.height else { out.append(frame); continue }
            let s = shift(of: grid(frame), relativeTo: ref, maxShift: range)
            let dx = s.dx * Double(ref.scale), dy = s.dy * Double(ref.scale)
            out.append(abs(dx) < 0.1 && abs(dy) < 0.1 ? frame : shifted(frame, dx: dx, dy: dy))
        }
        return out
    }
}
