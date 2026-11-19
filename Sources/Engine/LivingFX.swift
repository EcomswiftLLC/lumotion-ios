import Foundation
import CoreGraphics

/// What one living effect does to one pixel: where to read the picture from (an offset in pixels), how much light to add
/// and a brightness gain.
struct LivingSample {
    var ox: Float = 0
    var oy: Float = 0
    var add: Float = 0
    var gain: Float = 1
    /// The added light is weighted by the picture's own brightness (glints sit on bright water, not on dark rock).
    var lumaAdd = false
}

/// The maths of the whole-photo living effects, kept apart from the pixel loops so it can be measured in tests.
///
/// Design rules, checked by tests: displacements are smooth and low frequency, their size is a fixed share of the long
/// edge (so a preview and an export look the same) and a few pixels at the default strength, and they are limited by the
/// wavelength so the picture is never folded over itself (the cause of blotchy, tiling shapes).
struct LivingKernel {
    let kind: LivingEffectKind
    let strength: Float
    let s: Float
    let twoPi: Float
    let theta: Float
    let ca: Float
    let sa: Float
    let scale: Float
    let cxp: Float
    let cyp: Float
    let minT: Float
    let spanT: Float
    let sweepPos: Float
    let jx: Float
    let jy: Float
    let jr: Float
    /// True when no gradient or brush limits the effect, so it may shape itself over the frame.
    let unlimited: Bool

    init(_ e: LivingEffect, width w: Int, height h: Int, phase p: Double, cycles: Int, unlimited: Bool) {
        self.kind = e.kind
        strength = Float(min(max(e.strength, 0), 1))
        s = Float(max(w, h))
        twoPi = 2 * Float.pi
        theta = 2 * Float.pi * Float(cycles) * Float(p)
        let ang = Float(e.angle) * Float.pi / 180
        ca = cos(ang)
        sa = sin(ang)
        scale = Float(min(max(e.scale, 0.25), 4))
        cxp = Float(e.center.x) * Float(w)
        cyp = Float(e.center.y) * Float(h)
        // Projection range of the frame along the effect direction, for light sweeps.
        let fw = Float(w) / s, fh = Float(h) / s
        let corners: [Float] = [0, fw * ca, fh * sa, fw * ca + fh * sa]
        minT = corners.min() ?? 0
        spanT = max(0.001, (corners.max() ?? 1) - (corners.min() ?? 0))
        let turns = Float(cycles) * Float(p)
        sweepPos = turns - turns.rounded(.down)
        // Stop-motion step for wiggle.
        let steps = max(1, 8 * cycles)
        let stepIndex = Int((p * Double(steps)).rounded(.down)) % steps
        jx = (hashUnit(stepIndex, 1, 5) - 0.5) * 2
        jy = (hashUnit(stepIndex, 2, 5) - 0.5) * 2
        jr = (hashUnit(stepIndex, 3, 5) - 0.5) * 2
        self.unlimited = unlimited
    }

    /// Largest displacement that still keeps the picture from folding for waves of `wavelength` pixels.
    @inline(__always)
    private func safe(_ amplitude: Float, wavelength: Float) -> Float { min(amplitude, wavelength * 0.08) }

    /// The effect at pixel (x, y) of a frame; `yv` is y as a share of the frame height.
    func eval(_ x: Float, _ y: Float, yv: Float) -> LivingSample {
        var o = LivingSample()
        let X = (x + 0.5) / s, Y = (y + 0.5) / s
        switch kind {
        case .ripple:
            // Rings spreading from the centre: wavelength a tenth of the long edge, about 3 px at the default strength.
            let rx = X - cxp / s, ry = Y - cyp / s
            let r = (rx * rx + ry * ry).squareRoot()
            if r > 1e-5 {
                let wavelength = s * scale / 10
                let amp = safe(0.008 * strength * s, wavelength: wavelength)
                let wave = sin(twoPi * (10 / scale) * r - theta)
                let env = 1 / (1 + 2.5 * r)
                let d = amp * wave * env * smoothstep(0, 0.03, r)
                o.ox = d * rx / r
                o.oy = d * ry / r
            }
        case .waves:
            // Long swells with a gentle second harmonic.
            let u = X * ca + Y * sa
            let wavelength = s * scale / 7
            let amp = safe(0.007 * strength * s, wavelength: wavelength * 0.5)
            let k1 = twoPi * (7 / scale) * u - theta
            let wave = sin(k1) + 0.35 * sin(twoPi * (16 / scale) * u - 2 * theta + 1.3)
            let roll = cos(k1)
            o.ox = amp * (wave * -sa + 0.3 * roll * ca)
            o.oy = amp * (wave * ca + 0.3 * roll * sa)
        case .windSway:
            // Very smooth: the noise cell is half the frame, the sway about 3 px at the default strength.
            let n = valueNoise(X * 2 / scale, Y * 2 / scale, 7)
            let sway = sin(theta + twoPi * n)
            var weight: Float = 1
            if unlimited { weight = pow(max(0, 1 - yv), 1.4) }
            let d = min(0.008 * strength * s, 0.025 * (s * scale / 2)) * weight * sway
            o.ox = d * ca - 0.3 * d * sa
            o.oy = d * sa + 0.3 * d * ca
        case .heatHaze:
            let n = valueNoise(X * 3 / scale, Y * 3 / scale, 11)
            let wavelength = s * scale / 12
            let amp = safe(0.005 * strength * s, wavelength: wavelength)
            o.ox = amp * sin(twoPi * (12 / scale) * Y - theta + twoPi * n)
            o.oy = 0.5 * amp * sin(twoPi * (10 / scale) * X - 2 * theta + twoPi * n)
        case .shimmer:
            // Small, sparse glints: a fine noise cell (about 7 px at 720) raised to a high power so only the peaks show.
            let n = valueNoise(X * 100 / scale, Y * 100 / scale, 3)
            let sp = max(0, sin(theta + twoPi * n))
            let sp2 = sp * sp
            let sp4 = sp2 * sp2
            let sp16 = sp4 * sp4 * sp4 * sp4
            o.add = 55 * strength * sp16
            o.lumaAdd = true
        case .pulse:
            let z = 1 + 0.03 * strength * sin(theta)
            o.ox = (x - cxp) * (1 / z - 1)
            o.oy = (y - cyp) * (1 / z - 1)
            o.gain = 1 + 0.06 * strength * sin(theta)
        case .lightSweep:
            let t = X * ca + Y * sa
            let t01 = (t - minT) / spanT
            let half = 0.12 * scale
            let c = -half + (1 + 2 * half) * sweepPos
            let q = (t01 - c) / half
            var bump = max(0, 1 - q * q)
            bump = bump * bump
            o.add = 130 * strength * bump
        case .wobble:
            let rot = 0.035 * strength * sin(theta)
            let rx = x - cxp, ry = y - cyp
            let c = cos(rot), sn = sin(rot)
            o.ox = (c - 1) * rx - sn * ry
            o.oy = sn * rx + (c - 1) * ry
        case .wiggle:
            let rot = jr * 0.012 * strength
            let rx = x - cxp, ry = y - cyp
            let c = cos(rot), sn = sin(rot)
            o.ox = jx * 0.006 * strength * s + (c - 1) * rx - sn * ry
            o.oy = jy * 0.006 * strength * s + sn * rx + (c - 1) * ry
        case .swirl:
            let rx = x - cxp, ry = y - cyp
            let r = (rx * rx + ry * ry).squareRoot() / s
            let sigma = 0.22 * scale
            let a = 0.18 * strength * sin(theta) * exp(-(r * r) / (sigma * sigma))
            let c = cos(a), sn = sin(a)
            o.ox = (c - 1) * rx - sn * ry
            o.oy = sn * rx + (c - 1) * ry
        case .glitch:
            break
        }
        return o
    }
}

/// Whole-photo living effects. Each one is a pure function of position and loop phase; the phase enters only through
/// `sin`/`cos` of a whole number of turns (or a step index taken modulo a whole number of steps), so frame N equals frame 0.
enum LivingFX {
    /// Applies one effect. `dst` must already hold a copy of `src` (the picture so far); only affected pixels are rewritten.
    /// - Parameters:
    ///   - brush: optional painted limit in canvas space.
    ///   - cycles: whole number of animation cycles per loop (at least 1).
    static func apply(_ e: LivingEffect, brush: FloatField?, src: PixelBuffer, dst: PixelBuffer, phase p: Double, cycles: Int) {
        if e.kind == .glitch {
            applyGlitch(e, brush: brush, src: src, dst: dst, phase: p, cycles: cycles)
            return
        }
        let w = dst.width, h = dst.height
        if e.strength <= 0 { return }
        let gradient = e.gradient
        let kernel = LivingKernel(e, width: w, height: h, phase: p, cycles: cycles, unlimited: gradient == nil && brush == nil)
        let kind = e.kind
        let aspect = Float(w) / Float(h)
        let invW = 1 / Float(w), invH = 1 / Float(h)
        let srcPtr = UnsafePointer<UInt8>(src.data)
        let dstPtr = dst.data
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                let yv = (Float(y) + 0.5) * invH
                for x in 0..<w {
                    let xu = (Float(x) + 0.5) * invW
                    var m: Float = 1
                    if let g = gradient { m = g.value(u: xu, v: yv, aspect: aspect) }
                    if let b = brush { m *= b.sample(u: xu, v: yv) }
                    if m < 0.003 { continue }
                    var o = kernel.eval(Float(x), Float(y), yv: yv)
                    o.ox *= m; o.oy *= m; o.add *= m
                    let gain = 1 + (o.gain - 1) * m
                    if o.ox == 0 && o.oy == 0 && o.add == 0 && gain == 1 { continue }
                    let px = bilinear(srcPtr, w, h, Float(x) + o.ox, Float(y) + o.oy)
                    var b = px.b * gain, g = px.g * gain, r = px.r * gain
                    if o.add != 0 {
                        if kind == .lightSweep {
                            r += o.add; g += o.add * 0.93; b += o.add * 0.8
                        } else {
                            let l: Float = o.lumaAdd ? (0.15 + 0.85 * (px.r * 0.3 + px.g * 0.59 + px.b * 0.11) / 255) : 1
                            r += o.add * l; g += o.add * l; b += o.add * l * 0.95
                        }
                    }
                    let i = (y * w + x) * 4
                    dstPtr[i] = clamp255(b)
                    dstPtr[i + 1] = clamp255(g)
                    dstPtr[i + 2] = clamp255(r)
                    dstPtr[i + 3] = clamp255(px.a)
                }
            }
        }
    }

    /// How hard an effect pulls the picture around, measured without drawing anything. Used by the tests to keep every
    /// effect subtle and free of folds.
    struct Stats {
        /// Mean displacement in pixels.
        var meanDisplacement: Float
        /// Largest displacement in pixels.
        var maxDisplacement: Float
        /// Share of the frame where the mapping folds over itself (its Jacobian drops below 0.15).
        var foldShare: Float
        /// Mean light added (0...255) and the share of pixels that get more than 40 added.
        var meanAdd: Float
        var brightShare: Float
        var maxAdd: Float
    }

    static func stats(_ e: LivingEffect, width w: Int, height h: Int, phase p: Double, cycles: Int, step: Int = 1) -> Stats {
        let kernel = LivingKernel(e, width: w, height: h, phase: p, cycles: cycles, unlimited: true)
        var sumD: Double = 0, maxD: Float = 0, sumAdd: Double = 0, maxAdd: Float = 0
        var folds = 0, bright = 0, count = 0
        var y = 1
        while y < h - 1 {
            var x = 1
            while x < w - 1 {
                let yv = (Float(y) + 0.5) / Float(h)
                let c = kernel.eval(Float(x), Float(y), yv: yv)
                let right = kernel.eval(Float(x + 1), Float(y), yv: yv)
                let below = kernel.eval(Float(x), Float(y + 1), yv: (Float(y) + 1.5) / Float(h))
                let d = (c.ox * c.ox + c.oy * c.oy).squareRoot()
                sumD += Double(d)
                maxD = max(maxD, d)
                sumAdd += Double(c.add)
                maxAdd = max(maxAdd, c.add)
                if c.add > 40 { bright += 1 }
                let a = 1 + right.ox - c.ox, b = right.oy - c.oy
                let cc = below.ox - c.ox, dd = 1 + below.oy - c.oy
                if a * dd - b * cc < 0.15 { folds += 1 }
                count += 1
                x += step
            }
            y += step
        }
        let n = Float(max(1, count))
        return Stats(meanDisplacement: Float(sumD) / n, maxDisplacement: maxD, foldShare: Float(folds) / n,
                     meanAdd: Float(sumAdd) / n, brightShare: Float(bright) / n, maxAdd: maxAdd)
    }

    /// VHS style glitch: bands of rows slip sideways and the red and blue channels split, in discrete steps.
    private static func applyGlitch(_ e: LivingEffect, brush: FloatField?, src: PixelBuffer, dst: PixelBuffer, phase p: Double, cycles: Int) {
        let w = dst.width, h = dst.height
        let strength = Float(min(max(e.strength, 0), 1))
        if strength <= 0 { return }
        let steps = max(1, 12 * cycles)
        let n = Int((p * Double(steps)).rounded(.down)) % steps
        let bandHeight = max(2, h / 14)
        let bands = h / bandHeight + 1
        let activeChance = 0.15 + 0.35 * strength
        var shifts = [Float](repeating: 0, count: bands)
        for bi in 0..<bands where hashUnit(n, bi, 21) < activeChance {
            shifts[bi] = (hashUnit(n, bi, 22) - 0.5) * 2 * 0.12 * strength * Float(w)
        }
        let split = (hashUnit(n, 0, 23) > 0.55 ? 1 : 0.25) * 0.012 * strength * Float(w)
        let gradient = e.gradient
        let aspect = Float(w) / Float(h)
        let invW = 1 / Float(w), invH = 1 / Float(h)
        let srcPtr = UnsafePointer<UInt8>(src.data)
        let dstPtr = dst.data
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                let yv = (Float(y) + 0.5) * invH
                let shift = shifts[min(bands - 1, y / bandHeight)]
                let scan: Float = (y & 1) == 0 ? 1 - 0.10 * strength : 1
                for x in 0..<w {
                    let xu = (Float(x) + 0.5) * invW
                    var m: Float = 1
                    if let g = gradient { m = g.value(u: xu, v: yv, aspect: aspect) }
                    if let b = brush { m *= b.sample(u: xu, v: yv) }
                    if m < 0.003 { continue }
                    let xs = Float(x) + shift
                    let red = bilinear(srcPtr, w, h, xs + split, Float(y))
                    let green = bilinear(srcPtr, w, h, xs, Float(y))
                    let blue = bilinear(srcPtr, w, h, xs - split, Float(y))
                    let i = (y * w + x) * 4
                    let inv = 1 - m
                    dstPtr[i] = clamp255(Float(dstPtr[i]) * inv + blue.b * scan * m)
                    dstPtr[i + 1] = clamp255(Float(dstPtr[i + 1]) * inv + green.g * scan * m)
                    dstPtr[i + 2] = clamp255(Float(dstPtr[i + 2]) * inv + red.r * scan * m)
                }
            }
        }
    }
}
