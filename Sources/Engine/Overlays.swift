import Foundation
import CoreGraphics

/// Procedural overlays (rain, snow, sparks and so on), drawn in code with CoreGraphics. No images are used.
/// Every particle has fixed random properties taken from the layer's seed and its own index, and every motion is a
/// function of the loop phase with a whole number of cycles, so the result is deterministic and the loop closes.
enum OverlayRenderer {
    /// The four layers overlays are drawn into. Additive layers are added to the picture, normal layers are composited over it.
    struct Layers {
        var overNormal: PixelBuffer?
        var overAdditive: PixelBuffer?
        var underNormal: PixelBuffer?
        var underAdditive: PixelBuffer?

        var hasUnder: Bool { underNormal != nil || underAdditive != nil }
        var isEmpty: Bool { overNormal == nil && overAdditive == nil && underNormal == nil && underAdditive == nil }
    }

    /// Kinds that glow: they are added to the picture instead of covering it.
    static func isAdditive(_ kind: OverlayKind) -> Bool {
        switch kind {
        case .fireflies, .sparkles, .bokeh, .dust, .embers, .lensFlare, .lightLeaks, .stars, .shootingStars, .fireworks: return true
        default: return false
        }
    }

    /// Cycles per second of the main motion at speed 1.
    static func baseHz(_ kind: OverlayKind) -> Double {
        switch kind {
        case .rain: return 2.2
        case .heavyRain: return 3.0
        case .snow: return 0.18
        case .blizzard: return 0.6
        case .leaves: return 0.16
        case .petals: return 0.14
        case .fireflies: return 0.25
        case .sparkles: return 0.5
        case .bokeh: return 0.06
        case .dust: return 0.1
        case .embers: return 0.3
        case .fog: return 0.04
        case .lensFlare: return 0.12
        case .lightLeaks: return 0.25
        case .stars: return 0.35
        case .confetti: return 0.3
        case .hearts: return 0.2
        case .bubbles: return 0.18
        case .shootingStars: return 0.5
        case .fireworks: return 0.4
        }
    }

    /// Draws every enabled overlay for loop phase `phase`. Returns nil layers for placements that are not used.
    static func draw(overlays: [OverlayLayer], loop: LoopSpec, phase: Double, width w: Int, height h: Int) -> Layers {
        var layers = Layers()
        for overlay in overlays where overlay.enabled && overlay.intensity > 0 {
            let additive = isAdditive(overlay.kind)
            let buffer: PixelBuffer
            switch (overlay.placement, additive) {
            case (.over, false):
                if layers.overNormal == nil { layers.overNormal = PixelBuffer(width: w, height: h) }
                buffer = layers.overNormal!
            case (.over, true):
                if layers.overAdditive == nil { layers.overAdditive = PixelBuffer(width: w, height: h) }
                buffer = layers.overAdditive!
            case (.under, false):
                if layers.underNormal == nil { layers.underNormal = PixelBuffer(width: w, height: h) }
                buffer = layers.underNormal!
            case (.under, true):
                if layers.underAdditive == nil { layers.underAdditive = PixelBuffer(width: w, height: h) }
                buffer = layers.underAdditive!
            }
            buffer.withContext { ctx in
                ctx.topLeftOrigin(height: h)
                ctx.setShouldAntialias(true)
                var canvas = OverlayCanvas(ctx: ctx, w: Double(w), h: Double(h), loop: loop, phase: phase, layer: overlay)
                canvas.draw()
            }
        }
        return layers
    }
}

// MARK: - Gradient cache

private final class GradientCache {
    static let shared = GradientCache()
    private let lock = NSLock()
    private var cache: [Int: CGGradient] = [:]

    /// Profile 0 glow, 1 soft disc, 2 ring, 3 sharp disc. Colour is quantised to keep the cache small.
    func gradient(r: Double, g: Double, b: Double, profile: Int) -> CGGradient? {
        let qr = Int(min(max(r, 0), 1) * 63), qg = Int(min(max(g, 0), 1) * 63), qb = Int(min(max(b, 0), 1) * 63)
        let key = (profile << 18) | (qr << 12) | (qg << 6) | qb
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let cr = CGFloat(qr) / 63, cg = CGFloat(qg) / 63, cb = CGFloat(qb) / 63
        let stops: [(CGFloat, CGFloat)]
        switch profile {
        case 0: stops = [(0, 1), (0.25, 0.55), (0.6, 0.12), (1, 0)]
        case 1: stops = [(0, 1), (0.6, 1), (0.85, 0.6), (1, 0)]
        case 2: stops = [(0, 0.3), (0.75, 0.45), (0.9, 1), (1, 0)]
        default: stops = [(0, 1), (0.9, 1), (1, 0)]
        }
        let colors = stops.map { CGColor(red: cr, green: cg, blue: cb, alpha: $0.1) }
        let locations = stops.map { $0.0 }
        guard let gradient = CGGradient(colorsSpace: PixelFormat.colorSpace, colors: colors as CFArray, locations: locations) else { return nil }
        cache[key] = gradient
        return gradient
    }
}

// MARK: - Drawing

private struct RGB {
    var r: Double
    var g: Double
    var b: Double
}

private struct OverlayCanvas {
    let ctx: CGContext
    let w: Double
    let h: Double
    let layer: OverlayLayer
    let phase: Double
    let unit: Double
    let cycles: Int
    let dx: Double
    let dy: Double
    let nx: Double
    let ny: Double
    let intensity: Double
    let size: Double
    let depthBlur: Double
    let seedBase: UInt64

    init(ctx: CGContext, w: Double, h: Double, loop: LoopSpec, phase: Double, layer: OverlayLayer) {
        self.ctx = ctx
        self.w = w
        self.h = h
        self.layer = layer
        self.phase = phase
        unit = max(w, h) / 1280
        let speed = min(max(layer.speed, 0.1), 3) * min(max(loop.speed, 0.25), 4)
        cycles = max(1, Int((OverlayRenderer.baseHz(layer.kind) * speed * loop.clampedDuration).rounded()))
        let a = layer.direction * Double.pi / 180
        dx = cos(a); dy = sin(a)
        nx = -dy; ny = dx
        intensity = min(max(layer.intensity, 0), 1)
        size = min(max(layer.size, 0.25), 3)
        depthBlur = min(max(layer.depthBlur, 0), 1)
        var kindSalt: UInt64 = 5381
        for scalar in layer.kind.rawValue.unicodeScalars { kindSalt = (kindSalt &* 33) &+ UInt64(scalar.value) }
        seedBase = (UInt64(bitPattern: Int64(layer.seed)) &* 0x9E3779B97F4A7C15) ^ (kindSalt &* 0xBF58476D1CE4E5B9)
    }

    // MARK: helpers

    func rng(_ i: Int) -> SplitMix {
        var r = SplitMix(seed: seedBase &+ UInt64(i + 1) &* 0x632BE59BD9B4E019)
        _ = r.next()
        return r
    }

    func count(_ lo: Double, _ hi: Double) -> Int {
        Int((lo + (hi - lo) * intensity).rounded())
    }

    func tinted(_ c: RGB) -> RGB {
        guard let t = layer.tint else { return c }
        return RGB(r: t.r, g: t.g, b: t.b)
    }

    func tintAlpha() -> Double { layer.tint?.a ?? 1 }

    /// Per-particle cycle count: the base cycles with some spread, never below one.
    func particleCycles(_ r: Double) -> Int {
        max(1, Int((Double(cycles) * (0.75 + 0.5 * r)).rounded()))
    }

    func frac(_ v: Double) -> Double { v - v.rounded(.down) }

    /// A point on a straight pass across the frame in the layer direction: `s` along the way (0...1), `b` across (0...1).
    func travel(_ s: Double, _ b: Double, pad: Double) -> CGPoint {
        let along = abs(w * dx) + abs(h * dy) + 2 * pad
        let across = abs(w * nx) + abs(h * ny) + 2 * pad
        let a = (s - 0.5) * along
        let c = (b - 0.5) * across
        return CGPoint(x: w / 2 + dx * a + nx * c, y: h / 2 + dy * a + ny * c)
    }

    func dot(_ c: CGPoint, _ radius: Double, _ col: RGB, _ alpha: Double, profile: Int) {
        if radius <= 0.05 || alpha <= 0.002 { return }
        guard let gradient = GradientCache.shared.gradient(r: col.r, g: col.g, b: col.b, profile: profile) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(min(alpha * tintAlpha(), 1)))
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(radius), options: [])
        ctx.restoreGState()
    }

    func setFill(_ col: RGB, _ alpha: Double) {
        ctx.setFillColor(CGColor(red: CGFloat(col.r), green: CGFloat(col.g), blue: CGFloat(col.b), alpha: CGFloat(min(alpha * tintAlpha(), 1))))
    }

    func setStroke(_ col: RGB, _ alpha: Double) {
        ctx.setStrokeColor(CGColor(red: CGFloat(col.r), green: CGFloat(col.g), blue: CGFloat(col.b), alpha: CGFloat(min(alpha * tintAlpha(), 1))))
    }

    // MARK: kinds

    mutating func draw() {
        switch layer.kind {
        case .rain: rain(heavy: false)
        case .heavyRain: rain(heavy: true)
        case .snow: snow(blizzard: false)
        case .blizzard: snow(blizzard: true)
        case .leaves: leaves(petals: false)
        case .petals: leaves(petals: true)
        case .fireflies: fireflies()
        case .sparkles: sparkles()
        case .bokeh: bokeh()
        case .dust: dust()
        case .embers: embers()
        case .fog: fog()
        case .lensFlare: lensFlare()
        case .lightLeaks: lightLeaks()
        case .stars: stars()
        case .confetti: confetti()
        case .hearts: hearts()
        case .bubbles: bubbles()
        case .shootingStars: shootingStars()
        case .fireworks: fireworks()
        }
    }

    private func rain(heavy: Bool) {
        let n = Int(Double(count(80, 520)) * (heavy ? 1.9 : 1))
        let col = tinted(RGB(r: 0.82, g: 0.88, b: 0.96))
        ctx.setLineCap(.round)
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), z = r.unit(), lenR = r.unit(), ki = r.unit()
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            let pos = travel(s, b, pad: 80 * unit)
            let len = (heavy ? 30 + 40 * lenR : 18 + 28 * lenR) * unit * size
            let alpha = (0.22 + 0.33 * z) * (1 - depthBlur * (1 - z) * 0.5)
            setStroke(col, alpha)
            ctx.setLineWidth(CGFloat((0.8 + 1.0 * z) * unit * (heavy ? 1.3 : 1)))
            ctx.move(to: pos)
            ctx.addLine(to: CGPoint(x: pos.x - dx * len, y: pos.y - dy * len))
            ctx.strokePath()
        }
        if heavy {
            // A faint cool veil.
            setFill(RGB(r: 0.55, g: 0.62, b: 0.72), 0.08 * intensity)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func snow(blizzard: Bool) {
        let n = Int(Double(count(60, 380)) * (blizzard ? 2 : 1))
        let col = tinted(RGB(r: 1, g: 1, b: 1))
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), z = r.unit(), phi = r.unit(), ki = r.unit(), mR = r.unit()
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 40 * unit)
            let m = mR < 0.5 ? 1.0 : 2.0
            let sway = sin(2 * Double.pi * (m * phase + phi)) * 14 * unit * (blizzard ? 0.4 : 1)
            pos.x += nx * sway; pos.y += ny * sway
            let radius = (1.2 + 2.4 * z) * unit * size * (0.6 + 0.6 * z)
            let blur = depthBlur * (1 - z)
            let alpha = (0.5 + 0.45 * z) * (1 - blur * 0.5)
            if blur > 0.45 {
                dot(pos, radius * 2.6, col, alpha * 0.6, profile: 0)
            } else {
                dot(pos, radius * 1.4, col, alpha, profile: 1)
            }
        }
        if blizzard {
            setFill(RGB(r: 0.95, g: 0.97, b: 1), 0.10 * intensity)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func leaves(petals: Bool) {
        let n = petals ? count(10, 50) : count(8, 36)
        let palette: [RGB] = petals
            ? [RGB(r: 1, g: 0.78, b: 0.85), RGB(r: 1, g: 0.9, b: 0.92), RGB(r: 0.98, g: 0.65, b: 0.78), RGB(r: 1, g: 0.84, b: 0.88)]
            : [RGB(r: 0.80, g: 0.35, b: 0.10), RGB(r: 0.85, g: 0.55, b: 0.12), RGB(r: 0.62, g: 0.22, b: 0.08), RGB(r: 0.90, g: 0.72, b: 0.20), RGB(r: 0.45, g: 0.30, b: 0.10)]
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), z = r.unit(), phi = r.unit(), ki = r.unit(), mR = r.unit(), colR = r.unit(), phi2 = r.unit(), phi3 = r.unit()
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 50 * unit)
            let m = 1.0 + Double(Int(mR * 3))
            let sway = sin(2 * Double.pi * (Double(Int(m)) * phase + phi)) * 26 * unit
            pos.x += nx * sway; pos.y += ny * sway
            let base = (petals ? 6.0 : 9.0) * unit * size * (0.7 + 0.6 * z)
            let angle = 2 * Double.pi * (m * phase + phi2)
            let flip = 0.35 + 0.65 * abs(cos(2 * Double.pi * (Double(Int(m)) * phase + phi3)))
            let col = tinted(palette[Int(colR * Double(palette.count)) % palette.count])
            ctx.saveGState()
            ctx.translateBy(x: pos.x, y: pos.y)
            ctx.rotate(by: CGFloat(angle))
            ctx.scaleBy(x: CGFloat(flip), y: 1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -base))
            path.addCurve(to: CGPoint(x: 0, y: base), control1: CGPoint(x: base * 0.95, y: -base * 0.5), control2: CGPoint(x: base * 0.95, y: base * 0.5))
            path.addCurve(to: CGPoint(x: 0, y: -base), control1: CGPoint(x: -base * 0.95, y: base * 0.5), control2: CGPoint(x: -base * 0.95, y: -base * 0.5))
            setFill(col, 0.92)
            ctx.addPath(path)
            ctx.fillPath()
            if !petals {
                setStroke(RGB(r: col.r * 0.6, g: col.g * 0.6, b: col.b * 0.6), 0.8)
                ctx.setLineWidth(CGFloat(max(0.6, unit * 0.8)))
                ctx.move(to: CGPoint(x: 0, y: -base))
                ctx.addLine(to: CGPoint(x: 0, y: base * 1.15))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    private func fireflies() {
        let n = count(8, 44)
        let col = tinted(RGB(r: 0.85, g: 1, b: 0.35))
        let core = tinted(RGB(r: 1, g: 1, b: 0.75))
        for i in 0..<n {
            var r = rng(i)
            let x0 = r.unit(), y0 = r.range(0.25, 0.98), ax = r.range(0.02, 0.07), ay = r.range(0.02, 0.06)
            let p1 = r.unit(), p2 = r.unit(), p3 = r.unit(), m1 = Double(1 + Int(r.unit() * 3)), m2 = Double(1 + Int(r.unit() * 3)), m3 = Double(1 + Int(r.unit() * 3))
            let radius = r.range(5, 13) * unit * size
            let x = (x0 + ax * sin(2 * Double.pi * (m1 * phase + p1))) * w
            let y = (y0 + ay * sin(2 * Double.pi * (m2 * phase + p2))) * h
            let pulse = pow(0.5 + 0.5 * sin(2 * Double.pi * (m3 * phase + p3)), 2)
            dot(CGPoint(x: x, y: y), radius * 2.5, col, 0.5 * pulse, profile: 0)
            dot(CGPoint(x: x, y: y), radius * 0.45, core, 0.95 * pulse, profile: 1)
        }
    }

    private func sparkles() {
        let n = count(14, 80)
        let col = tinted(RGB(r: 1, g: 0.95, b: 0.8))
        ctx.setLineCap(.round)
        for i in 0..<n {
            var r = rng(i)
            let x = r.unit() * w, y = r.unit() * h, phi = r.unit(), m = Double(1 + Int(r.unit() * 3)), sz = r.range(6, 16)
            let tw = pow(max(0, sin(2 * Double.pi * (m * phase + phi))), 3)
            if tw < 0.02 { continue }
            let radius = sz * unit * size * tw
            let c = CGPoint(x: x, y: y)
            dot(c, radius * 0.9, col, 0.6 * tw, profile: 0)
            setStroke(col, 0.9 * tw)
            ctx.setLineWidth(CGFloat(max(0.8, unit * 1.1)))
            ctx.move(to: CGPoint(x: x - radius * 1.6, y: y)); ctx.addLine(to: CGPoint(x: x + radius * 1.6, y: y))
            ctx.move(to: CGPoint(x: x, y: y - radius * 1.6)); ctx.addLine(to: CGPoint(x: x, y: y + radius * 1.6))
            ctx.strokePath()
        }
    }

    private func bokeh() {
        let n = count(6, 26)
        let palette: [RGB] = [RGB(r: 1, g: 0.85, b: 0.55), RGB(r: 1, g: 0.7, b: 0.45), RGB(r: 0.9, g: 0.9, b: 1), RGB(r: 1, g: 0.6, b: 0.7)]
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), z = r.unit(), colR = r.unit(), ki = r.unit(), a = r.range(0.08, 0.22)
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            let pos = travel(s, b, pad: 90 * unit * size)
            let radius = (18 + 52 * z) * unit * size
            let col = tinted(palette[Int(colR * Double(palette.count)) % palette.count])
            let soft = depthBlur * (1 - z)
            dot(pos, radius, col, a * (soft > 0.4 ? 0.8 : 1.2), profile: soft > 0.4 ? 0 : 2)
        }
    }

    private func dust() {
        let n = count(40, 260)
        let col = tinted(RGB(r: 1, g: 0.95, b: 0.85))
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), z = r.unit(), ki = r.unit(), phi = r.unit(), m = Double(1 + Int(r.unit() * 3))
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            let pos = travel(s, b, pad: 20 * unit)
            let radius = (0.8 + 1.4 * z) * unit * size
            let tw = 0.25 + 0.75 * (0.5 + 0.5 * sin(2 * Double.pi * (m * phase + phi)))
            dot(pos, radius * 2, col, 0.7 * tw * (1 - depthBlur * (1 - z) * 0.4), profile: 1)
        }
    }

    private func embers() {
        let n = count(14, 90)
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), ki = r.unit(), phi = r.unit(), m = Double(1 + Int(r.unit() * 3)), fl = r.unit(), rad = r.range(1.2, 3.2)
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 30 * unit)
            let sway = sin(2 * Double.pi * (m * phase + phi)) * 18 * unit
            pos.x += nx * sway; pos.y += ny * sway
            let fade = pow(max(0, sin(Double.pi * s)), 0.7)
            let flicker = 0.6 + 0.4 * sin(2 * Double.pi * (m * phase + fl))
            let col = tinted(RGB(r: 1, g: 0.75 - 0.45 * s, b: 0.25 - 0.15 * s))
            dot(pos, rad * 3.2 * unit * size, col, 0.5 * fade * flicker, profile: 0)
            dot(pos, rad * 0.8 * unit * size, tinted(RGB(r: 1, g: 0.9, b: 0.6)), 0.9 * fade * flicker, profile: 1)
        }
    }

    private func fog() {
        let n = count(5, 9)
        let col = tinted(RGB(r: 0.9, g: 0.92, b: 0.95))
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), y = r.range(0.35, 0.98), rad = r.range(0.25, 0.5), a = r.range(0.07, 0.16), ki = r.unit()
            let radius = rad * w * size
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            let pos = travel(s, y, pad: radius)
            dot(pos, radius, col, min(1, a * (0.4 + 1.6 * intensity)), profile: 0)
        }
    }

    private func lensFlare() {
        let k = Double(cycles)
        let s = frac(k * phase)
        let e = pow(sin(Double.pi * s), 2) * (0.35 + 0.65 * intensity)
        if e < 0.01 { return }
        let a = CGPoint(x: -0.1 * w, y: 0.15 * h), b = CGPoint(x: 1.1 * w, y: 0.55 * h)
        let src = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
        let warm = tinted(RGB(r: 1, g: 0.78, b: 0.45))
        dot(src, 70 * unit * size, warm, 0.8 * e, profile: 0)
        dot(src, 14 * unit * size, tinted(RGB(r: 1, g: 1, b: 0.9)), 0.95 * e, profile: 1)
        // Anamorphic streak: a wide, thin glow.
        ctx.saveGState()
        ctx.translateBy(x: src.x, y: src.y)
        ctx.scaleBy(x: 9, y: 1)
        if let gradient = GradientCache.shared.gradient(r: warm.r, g: warm.g, b: warm.b, profile: 0) {
            ctx.setAlpha(CGFloat(0.5 * e * tintAlpha()))
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: CGFloat(34 * unit * size), options: [])
        }
        ctx.restoreGState()
        let centre = CGPoint(x: w / 2, y: h / 2)
        let ghostColors = [RGB(r: 1, g: 0.7, b: 0.3), RGB(r: 0.4, g: 0.8, b: 1), RGB(r: 1, g: 0.4, b: 0.6), RGB(r: 0.6, g: 1, b: 0.7)]
        let ts: [Double] = [0.35, 0.8, 1.3, 1.7]
        let sizes: [Double] = [26, 16, 38, 20]
        for (gi, t) in ts.enumerated() {
            let c = CGPoint(x: src.x + (centre.x - src.x) * t, y: src.y + (centre.y - src.y) * t)
            dot(c, sizes[gi] * unit * size, tinted(ghostColors[gi]), 0.35 * e, profile: 2)
        }
    }

    private func lightLeaks() {
        let blobs: [(CGPoint, RGB, Double)] = [
            (CGPoint(x: -0.05 * w, y: 0.1 * h), RGB(r: 1, g: 0.45, b: 0.15), 0.7),
            (CGPoint(x: 1.05 * w, y: 0.9 * h), RGB(r: 1, g: 0.2, b: 0.5), 0.65),
            (CGPoint(x: 0.5 * w, y: -0.1 * h), RGB(r: 1, g: 0.75, b: 0.3), 0.55),
        ]
        for (i, blob) in blobs.enumerated() {
            var r = rng(i)
            let phi = r.unit(), m = Double(1 + Int(r.unit() * 2))
            let pulse = 0.5 + 0.5 * sin(2 * Double.pi * (m * phase + phi))
            let drift = 0.03 * w * sin(2 * Double.pi * (phase + phi))
            let c = CGPoint(x: blob.0.x + drift, y: blob.0.y)
            dot(c, blob.2 * w * size, tinted(blob.1), 0.5 * intensity * (0.35 + 0.65 * pulse), profile: 0)
        }
    }

    private func stars() {
        let n = count(50, 260)
        for i in 0..<n {
            var r = rng(i)
            let x = r.unit() * w, y = pow(r.unit(), 1.5) * h * 0.85, phi = r.unit(), m = Double(1 + Int(r.unit() * 3)), sz = r.range(0.7, 1.8), big = r.unit(), blue = r.unit()
            let tw = 0.35 + 0.65 * (0.5 + 0.5 * sin(2 * Double.pi * (m * phase + phi)))
            let col = tinted(blue < 0.3 ? RGB(r: 0.75, g: 0.85, b: 1) : RGB(r: 1, g: 1, b: 0.95))
            let c = CGPoint(x: x, y: y)
            dot(c, sz * 2.2 * unit * size, col, 0.9 * tw, profile: 1)
            if big > 0.94 {
                setStroke(col, 0.6 * tw)
                ctx.setLineWidth(CGFloat(max(0.6, unit * 0.8)))
                let len = sz * 6 * unit * size * tw
                ctx.move(to: CGPoint(x: x - len, y: y)); ctx.addLine(to: CGPoint(x: x + len, y: y))
                ctx.move(to: CGPoint(x: x, y: y - len)); ctx.addLine(to: CGPoint(x: x, y: y + len))
                ctx.strokePath()
            }
        }
    }

    private func confetti() {
        let n = count(30, 170)
        let palette: [RGB] = [RGB(r: 1, g: 0.35, b: 0.4), RGB(r: 1, g: 0.8, b: 0.2), RGB(r: 0.3, g: 0.8, b: 1), RGB(r: 0.5, g: 0.9, b: 0.4), RGB(r: 0.8, g: 0.45, b: 1), RGB(r: 1, g: 0.6, b: 0.2)]
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), ki = r.unit(), phi = r.unit(), phi2 = r.unit(), colR = r.unit(), mR = r.unit(), wid = r.range(6, 12), hei = r.range(3, 6)
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 30 * unit)
            let m = Double(1 + Int(mR * 3))
            let sway = sin(2 * Double.pi * (m * phase + phi)) * 20 * unit
            pos.x += nx * sway; pos.y += ny * sway
            let angle = 2 * Double.pi * (m * phase + phi2)
            let flip = max(0.15, abs(cos(2 * Double.pi * (m * phase + phi))))
            ctx.saveGState()
            ctx.translateBy(x: pos.x, y: pos.y)
            ctx.rotate(by: CGFloat(angle))
            ctx.scaleBy(x: 1, y: CGFloat(flip))
            setFill(tinted(palette[Int(colR * Double(palette.count)) % palette.count]), 0.95)
            ctx.fill(CGRect(x: -wid * unit * size / 2, y: -hei * unit * size / 2, width: wid * unit * size, height: hei * unit * size))
            ctx.restoreGState()
        }
    }

    private func heartPath(_ s: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: s * 0.9))
        path.addCurve(to: CGPoint(x: -s, y: -s * 0.1), control1: CGPoint(x: -s * 0.4, y: s * 0.6), control2: CGPoint(x: -s, y: s * 0.35))
        path.addCurve(to: CGPoint(x: 0, y: -s * 0.35), control1: CGPoint(x: -s, y: -s * 0.65), control2: CGPoint(x: -s * 0.2, y: -s * 0.8))
        path.addCurve(to: CGPoint(x: s, y: -s * 0.1), control1: CGPoint(x: s * 0.2, y: -s * 0.8), control2: CGPoint(x: s, y: -s * 0.65))
        path.addCurve(to: CGPoint(x: 0, y: s * 0.9), control1: CGPoint(x: s, y: s * 0.35), control2: CGPoint(x: s * 0.4, y: s * 0.6))
        path.closeSubpath()
        return path
    }

    private func hearts() {
        let n = count(6, 28)
        let palette: [RGB] = [RGB(r: 1, g: 0.3, b: 0.45), RGB(r: 1, g: 0.5, b: 0.65), RGB(r: 0.95, g: 0.2, b: 0.35), RGB(r: 1, g: 0.7, b: 0.8)]
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), ki = r.unit(), phi = r.unit(), m = Double(1 + Int(r.unit() * 2)), colR = r.unit(), sz = r.range(10, 26)
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 40 * unit)
            let sway = sin(2 * Double.pi * (m * phase + phi)) * 22 * unit
            pos.x += nx * sway; pos.y += ny * sway
            let fade = min(1, 3 * sin(Double.pi * s))
            ctx.saveGState()
            ctx.translateBy(x: pos.x, y: pos.y)
            ctx.rotate(by: CGFloat(0.35 * sin(2 * Double.pi * (m * phase + phi))))
            ctx.addPath(heartPath(sz * unit * size))
            setFill(tinted(palette[Int(colR * Double(palette.count)) % palette.count]), 0.75 * max(0, fade))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func bubbles() {
        let n = count(8, 34)
        let col = tinted(RGB(r: 1, g: 1, b: 1))
        for i in 0..<n {
            var r = rng(i)
            let s0 = r.unit(), b = r.unit(), ki = r.unit(), phi = r.unit(), m = Double(1 + Int(r.unit() * 2)), rad = r.range(6, 28)
            let s = frac(s0 + Double(particleCycles(ki)) * phase)
            var pos = travel(s, b, pad: 40 * unit)
            let sway = sin(2 * Double.pi * (m * phase + phi)) * 16 * unit
            pos.x += nx * sway; pos.y += ny * sway
            let radius = rad * unit * size
            let fade = min(1, 4 * sin(Double.pi * s))
            if fade <= 0 { continue }
            let rect = CGRect(x: pos.x - radius, y: pos.y - radius, width: radius * 2, height: radius * 2)
            setFill(col, 0.07 * fade)
            ctx.fillEllipse(in: rect)
            setStroke(col, 0.55 * fade)
            ctx.setLineWidth(CGFloat(max(0.8, 1.2 * unit)))
            ctx.strokeEllipse(in: rect)
            setFill(col, 0.7 * fade)
            ctx.fillEllipse(in: CGRect(x: pos.x - radius * 0.55, y: pos.y - radius * 0.6, width: radius * 0.35, height: radius * 0.2))
        }
    }

    private func shootingStars() {
        let n = max(1, count(1, 5))
        let col = tinted(RGB(r: 1, g: 1, b: 1))
        ctx.setLineCap(.round)
        let a = layer.direction * Double.pi / 180
        let vx = cos(a), vy = sin(a)
        for i in 0..<n {
            var r = rng(i)
            let sx = r.range(0.05, 0.6) * w, sy = r.range(0.03, 0.45) * h, off = r.unit()
            let s = frac(Double(cycles) * phase + off)
            let active = 0.22
            if s >= active { continue }
            let u = s / active
            let travelLen = 0.45 * w
            let head = CGPoint(x: sx + vx * u * travelLen, y: sy + vy * u * travelLen)
            let env = sin(Double.pi * u)
            let tail = 0.12 * w * size
            let segments = 10
            for k in 0..<segments {
                let t0 = Double(k) / Double(segments), t1 = Double(k + 1) / Double(segments)
                let p0 = CGPoint(x: head.x - vx * tail * t0, y: head.y - vy * tail * t0)
                let p1 = CGPoint(x: head.x - vx * tail * t1, y: head.y - vy * tail * t1)
                setStroke(col, env * (1 - t0) * 0.9)
                ctx.setLineWidth(CGFloat(max(0.6, (2.4 - 1.8 * t0) * unit)))
                ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
            }
            dot(head, 9 * unit * size, col, 0.8 * env, profile: 0)
        }
    }

    private func fireworks() {
        let bursts = max(1, count(1, 4))
        let palette: [RGB] = [RGB(r: 1, g: 0.55, b: 0.25), RGB(r: 0.4, g: 0.8, b: 1), RGB(r: 1, g: 0.4, b: 0.7), RGB(r: 0.6, g: 1, b: 0.5), RGB(r: 1, g: 0.9, b: 0.4)]
        let sparks = 28
        for b in 0..<bursts {
            var r = rng(b)
            let cx = r.range(0.18, 0.82) * w, cy = r.range(0.12, 0.5) * h, off = r.unit(), colR = r.unit(), reach = r.range(0.12, 0.2) * w * size
            let q = frac(Double(cycles) * phase + off)
            if q >= 0.6 { continue }
            let t = q / 0.6
            let col = tinted(palette[Int(colR * Double(palette.count)) % palette.count])
            let radial = 1 - (1 - t) * (1 - t)
            let fade = pow(1 - t, 1.4)
            for j in 0..<sparks {
                let ang = 2 * Double.pi * (Double(j) / Double(sparks)) + 0.1 * sin(Double(j * 7))
                let speedJ = 0.75 + 0.25 * Double((j * 13) % 7) / 6
                let pos = CGPoint(x: cx + cos(ang) * reach * radial * speedJ, y: cy + sin(ang) * reach * radial * speedJ + 0.1 * h * t * t)
                dot(pos, 5 * unit * size, col, 0.9 * fade, profile: 0)
                dot(pos, 1.6 * unit * size, RGB(r: 1, g: 1, b: 1), 0.9 * fade, profile: 1)
            }
        }
    }
}
