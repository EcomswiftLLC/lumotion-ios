import Foundation
import CoreGraphics

// MARK: - Canvas mapping

/// Maps between canvas coordinates (what the person sees after the aspect ratio and reframe are applied) and photo
/// coordinates (where strokes, arrows and masks are stored). Both are normalised 0...1 with y down.
/// The UI uses this to turn a finger position on the preview into a stroke point.
struct FrameMapping {
    var ax: Double
    var bx: Double
    var ay: Double
    var by: Double

    /// photo = (ax * canvasU + bx, ay * canvasV + by)
    init(ax: Double, bx: Double, ay: Double, by: Double) {
        self.ax = ax; self.bx = bx; self.ay = ay; self.by = by
    }

    init(project: Project) {
        self.init(canvas: project.canvas, sourceAspect: project.source.aspect)
    }

    init(canvas: CanvasSpec, sourceAspect: Double) {
        let aS = max(0.05, sourceAspect)
        let aC = canvas.aspect.ratio(sourceAspect: aS)
        switch canvas.fit {
        case .fill:
            var vw = 1.0, vh = 1.0
            if aC > aS { vh = aS / aC } else { vw = aC / aS }
            let zoom = min(max(canvas.zoom, 1), 8)
            vw /= zoom
            vh /= zoom
            let cx = min(max(canvas.centerX, vw / 2), 1 - vw / 2)
            let cy = min(max(canvas.centerY, vh / 2), 1 - vh / 2)
            self.init(ax: vw, bx: cx - vw / 2, ay: vh, by: cy - vh / 2)
        case .fit:
            var fw = 1.0, fh = 1.0
            if aC > aS { fw = aS / aC } else { fh = aC / aS }
            let ox = (1 - fw) / 2
            let oy = (1 - fh) / 2
            self.init(ax: 1 / fw, bx: -ox / fw, ay: 1 / fh, by: -oy / fh)
        }
    }

    func toSource(_ p: NPoint) -> NPoint { NPoint(ax * p.x + bx, ay * p.y + by) }

    func toCanvas(_ p: NPoint) -> NPoint {
        NPoint(ax != 0 ? (p.x - bx) / ax : 0, ay != 0 ? (p.y - by) / ay : 0)
    }

    /// True when canvas point (u, v) falls on the photo (false in the background bands of a `fit` canvas).
    func isOnPhoto(u: Double, v: Double) -> Bool {
        let su = ax * u + bx
        let sv = ay * v + by
        return su >= 0 && su <= 1 && sv >= 0 && sv <= 1
    }
}

// MARK: - Brush stroke rasteriser

/// Turns brush strokes into masks, with its own rasteriser (no CoreGraphics), so results are identical on every device.
enum StrokeRaster {
    /// Working size for a photo-shaped mask whose long edge is `longEdge`.
    static func size(aspect: Double, longEdge: Int) -> (width: Int, height: Int) {
        let a = max(0.05, aspect)
        if a >= 1 { return (longEdge, max(1, Int((Double(longEdge) / a).rounded()))) }
        return (max(1, Int((Double(longEdge) * a).rounded())), longEdge)
    }

    /// Calls `body` once per stroke with the stroke's alpha (0...1) over a rectangle of the mask.
    /// `featherBoost` widens every stroke's soft edge.
    static func forEachStroke(_ strokes: [BrushStroke], width w: Int, height h: Int, featherBoost: Double,
                              _ body: (BrushStroke, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ alpha: [Float]) -> Void) {
        for stroke in strokes {
            // Points that are not finite numbers (a damaged file) are skipped, and the rest are kept in a sane range so
            // the Int conversions below can never trap.
            let pts = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
            if pts.isEmpty { continue }
            let rawRadius = stroke.radius.isFinite ? stroke.radius : 0.04
            let r = Float(min(2, max(0.0005, rawRadius))) * Float(max(w, h))
            let rawFeather = stroke.feather.isFinite ? stroke.feather : 0.5
            let f = Float(min(1, max(0, rawFeather + (featherBoost.isFinite ? featherBoost : 0))))
            let ramp = max(r * f, 1)
            let innerR = max(0, r - ramp)
            var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            var px = [Float](), py = [Float]()
            px.reserveCapacity(pts.count); py.reserveCapacity(pts.count)
            for p in pts {
                let x = Float(min(max(p.x, -8), 9)) * Float(w)
                let y = Float(min(max(p.y, -8), 9)) * Float(h)
                px.append(x); py.append(y)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            let x0 = max(0, Int((minX - r - 1).rounded(.down)))
            let y0 = max(0, Int((minY - r - 1).rounded(.down)))
            let x1 = min(w - 1, Int((maxX + r + 1).rounded(.up)))
            let y1 = min(h - 1, Int((maxY + r + 1).rounded(.up)))
            if x1 < x0 || y1 < y0 { continue }
            let bw = x1 - x0 + 1
            let bh = y1 - y0 + 1
            var alpha = [Float](repeating: 0, count: bw * bh)
            let segments = max(1, pts.count - 1)
            for i in 0..<segments {
                let ax = px[i], ay = py[i]
                let bx = px[min(i + 1, pts.count - 1)], by = py[min(i + 1, pts.count - 1)]
                let sx0 = max(x0, Int((min(ax, bx) - r - 1).rounded(.down)))
                let sx1 = min(x1, Int((max(ax, bx) + r + 1).rounded(.up)))
                let sy0 = max(y0, Int((min(ay, by) - r - 1).rounded(.down)))
                let sy1 = min(y1, Int((max(ay, by) + r + 1).rounded(.up)))
                if sx1 < sx0 || sy1 < sy0 { continue }
                let abx = bx - ax, aby = by - ay
                let len2 = abx * abx + aby * aby
                for y in sy0...sy1 {
                    let cy = Float(y) + 0.5
                    for x in sx0...sx1 {
                        let cx = Float(x) + 0.5
                        var t: Float = 0
                        if len2 > 0 { t = min(max(((cx - ax) * abx + (cy - ay) * aby) / len2, 0), 1) }
                        let dx = cx - (ax + abx * t)
                        let dy = cy - (ay + aby * t)
                        let d = (dx * dx + dy * dy).squareRoot()
                        if d >= r { continue }
                        var a: Float = 1
                        if d > innerR {
                            let u = (d - innerR) / ramp
                            a = 1 - u * u * (3 - 2 * u)
                        }
                        let idx = (y - y0) * bw + (x - x0)
                        if a > alpha[idx] { alpha[idx] = a }
                    }
                }
            }
            body(stroke, x0, y0, x1, y1, alpha)
        }
    }

    /// Paint mask for `strokes`. Paint strokes add, erase strokes remove, in order. Returns nil when nothing is painted.
    static func paintMask(_ strokes: [BrushStroke], width w: Int, height h: Int, featherBoost: Double = 0) -> MaskBuffer? {
        guard strokes.contains(where: { !$0.erase }) else { return nil }
        var acc = [Float](repeating: 0, count: w * h)
        forEachStroke(strokes, width: w, height: h, featherBoost: featherBoost) { stroke, x0, y0, x1, y1, alpha in
            let bw = x1 - x0 + 1
            for y in y0...y1 {
                for x in x0...x1 {
                    let a = alpha[(y - y0) * bw + (x - x0)]
                    if a <= 0 { continue }
                    let i = y * w + x
                    if stroke.erase { acc[i] *= (1 - a) } else if a > acc[i] { acc[i] = a }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        var anyPaint = false
        for i in 0..<out.count {
            let v = UInt8(min(255, max(0, (acc[i] * 255).rounded())))
            out[i] = v
            if v > 0 { anyPaint = true }
        }
        return anyPaint ? MaskBuffer(width: w, height: h, data: out) : nil
    }

    /// Depth map: starts from `base`, each stroke moves the covered pixels towards the stroke's `value`.
    static func paintDepth(_ strokes: [BrushStroke], base: MaskBuffer) -> MaskBuffer {
        let w = base.width, h = base.height
        var acc = base.data.map { Float($0) / 255 }
        let original = acc
        forEachStroke(strokes, width: w, height: h, featherBoost: 0) { stroke, x0, y0, x1, y1, alpha in
            let bw = x1 - x0 + 1
            let target = Float(min(1, max(0, stroke.value)))
            for y in y0...y1 {
                for x in x0...x1 {
                    let a = alpha[(y - y0) * bw + (x - x0)]
                    if a <= 0 { continue }
                    let i = y * w + x
                    let goal = stroke.erase ? original[i] : target
                    acc[i] += (goal - acc[i]) * a
                }
            }
        }
        return MaskBuffer(width: w, height: h, data: acc.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) })
    }

    /// Resamples a photo-space mask into canvas space (`width` x `height`). Canvas pixels that fall outside the photo get `outside`.
    static func toCanvas(_ mask: MaskBuffer, mapping: FrameMapping, width: Int, height: Int, outside: UInt8 = 0) -> MaskBuffer {
        var out = [UInt8](repeating: outside, count: width * height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            let sv = mapping.ay * v + mapping.by
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let su = mapping.ax * u + mapping.bx
                if su < 0 || su > 1 || sv < 0 || sv > 1 { continue }
                out[y * width + x] = UInt8(min(255, max(0, (mask.sample(u: su, v: sv) * 255).rounded())))
            }
        }
        return MaskBuffer(width: width, height: height, data: out)
    }

    /// Separable box blur of a mask, `passes` times (3 passes approximate a gaussian).
    static func blur(_ mask: MaskBuffer, radius: Int, passes: Int = 2) -> MaskBuffer {
        if radius < 1 { return mask }
        let w = mask.width, h = mask.height
        var a = mask.data.map { Float($0) }
        var b = [Float](repeating: 0, count: a.count)
        let window = Float(radius * 2 + 1)
        for _ in 0..<max(1, passes) {
            // horizontal a -> b
            for y in 0..<h {
                var sum: Float = 0
                let row = y * w
                for k in -radius...radius { sum += a[row + min(max(k, 0), w - 1)] }
                for x in 0..<w {
                    b[row + x] = sum / window
                    let addX = min(x + radius + 1, w - 1)
                    let subX = max(x - radius, 0)
                    sum += a[row + addX] - a[row + subX]
                }
            }
            // vertical b -> a
            for x in 0..<w {
                var sum: Float = 0
                for k in -radius...radius { sum += b[min(max(k, 0), h - 1) * w + x] }
                for y in 0..<h {
                    a[y * w + x] = sum / window
                    let addY = min(y + radius + 1, h - 1)
                    let subY = max(y - radius, 0)
                    sum += b[addY * w + x] - b[subY * w + x]
                }
            }
        }
        return MaskBuffer(width: w, height: h, data: a.map { UInt8(min(255, max(0, $0.rounded()))) })
    }
}

// MARK: - Gradient mask

extension GradientMask {
    /// Value 0...1 at canvas point (u, v). `aspect` is canvas width / height so the ramp is measured in true distance.
    func value(u: Float, v: Float, aspect: Float) -> Float {
        let sx = Float(start.x) * aspect, sy = Float(start.y)
        let ex = Float(end.x) * aspect, ey = Float(end.y)
        let dx = ex - sx, dy = ey - sy
        let len2 = dx * dx + dy * dy
        var t: Float = 0.5
        if len2 > 1e-8 {
            t = min(max(((u * aspect - sx) * dx + (v - sy) * dy) / len2, 0), 1)
        }
        let s = Float(min(max(softness, 0), 1))
        let eased = t * t * (3 - 2 * t)
        var r = t + (eased - t) * s
        if invert { r = 1 - r }
        return r
    }
}

// MARK: - Cache

/// A small thread-safe cache with a byte budget; the least recently used entries are dropped first.
final class Memo {
    private struct Entry {
        let value: Any
        let cost: Int
    }

    private let lock = NSRecursiveLock()
    private var entries: [MemoKey: Entry] = [:]
    private var order: [MemoKey] = []
    private var total = 0
    private let budget: Int

    init(budgetBytes: Int) { budget = budgetBytes }

    /// Returns the cached value for `key`, or builds it with `make` (called while the cache is locked, so builds are not duplicated).
    func get<T>(_ key: MemoKey, cost: (T) -> Int, make: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[key], let value = hit.value as? T {
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return value
        }
        let value = make()
        let c = cost(value)
        entries[key] = Entry(value: value, cost: c)
        order.append(key)
        total += c
        while total > budget && order.count > 1 {
            let oldest = order.removeFirst()
            if oldest == key { order.append(oldest); continue }
            if let e = entries.removeValue(forKey: oldest) { total -= e.cost }
        }
        return value
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); order.removeAll(); total = 0
    }
}

struct MemoKey: Hashable {
    var tag: String
    var a: Int = 0
    var b: Int = 0
    var w: Int = 0
    var h: Int = 0
}
