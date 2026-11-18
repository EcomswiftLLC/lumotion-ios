import Foundation
import CoreGraphics

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
        let s = Float(max(w, h))
        let strength = Float(min(max(e.strength, 0), 1))
        if strength <= 0 { return }
        let twoPi = 2 * Float.pi
        let theta = twoPi * Float(cycles) * Float(p)
        let ang = Float(e.angle) * Float.pi / 180
        let ca = cos(ang), sa = sin(ang)
        let scale = Float(min(max(e.scale, 0.25), 4))
        let cxp = Float(e.center.x) * Float(w)
        let cyp = Float(e.center.y) * Float(h)
        let aspect = Float(w) / Float(h)
        let gradient = e.gradient
        let kind = e.kind
        let invW = 1 / Float(w), invH = 1 / Float(h)

        // Projection range of the frame along the effect direction, for light sweeps.
        let fw = Float(w) / s, fh = Float(h) / s
        let corners: [Float] = [0, fw * ca, fh * sa, fw * ca + fh * sa]
        let minT = corners.min() ?? 0
        let maxT = corners.max() ?? 1
        let spanT = max(0.001, maxT - minT)
        let sweepPos: Float = Float(cycles) * Float(p) - (Float(cycles) * Float(p)).rounded(.down)

        // Stop-motion step for wiggle.
        let steps = max(1, 8 * cycles)
        let stepIndex = Int((p * Double(steps)).rounded(.down)) % steps
        let jx = (hashUnit(stepIndex, 1, 5) - 0.5) * 2
        let jy = (hashUnit(stepIndex, 2, 5) - 0.5) * 2
        let jr = (hashUnit(stepIndex, 3, 5) - 0.5) * 2

        let srcPtr = UnsafePointer<UInt8>(src.data)
        let dstPtr = dst.data
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                let yv = (Float(y) + 0.5) * invH
                let Y = (Float(y) + 0.5) / s
                for x in 0..<w {
                    let xu = (Float(x) + 0.5) * invW
                    var m: Float = 1
                    if let g = gradient { m = g.value(u: xu, v: yv, aspect: aspect) }
                    if let b = brush { m *= b.sample(u: xu, v: yv) }
                    if m < 0.003 { continue }
                    let X = (Float(x) + 0.5) / s
                    var ox: Float = 0, oy: Float = 0, add: Float = 0, gain: Float = 1
                    var lumaAdd = false
                    switch kind {
                    case .ripple:
                        let rx = X - cxp / s, ry = Y - cyp / s
                        let r = (rx * rx + ry * ry).squareRoot()
                        if r > 1e-5 {
                            let wave = sin(twoPi * (18 / scale) * r - theta)
                            let env = 1 / (1 + 2.5 * r)
                            let d = 0.02 * strength * wave * env * s
                            ox = d * rx / r
                            oy = d * ry / r
                        }
                    case .waves:
                        let u = X * ca + Y * sa
                        let k1 = twoPi * (9 / scale) * u - theta
                        let wave = sin(k1) + 0.5 * sin(twoPi * (21 / scale) * u - 2 * theta + 1.3)
                        let roll = cos(k1)
                        let d = 0.012 * strength * s
                        ox = d * (wave * -sa + 0.4 * roll * ca)
                        oy = d * (wave * ca + 0.4 * roll * sa)
                    case .windSway:
                        let n = valueNoise(X * 3 / scale, Y * 3 / scale, 7)
                        let sway = sin(theta + twoPi * n)
                        var weight: Float = 1
                        if gradient == nil && brush == nil { weight = pow(max(0, 1 - yv), 1.4) }
                        let d = 0.03 * strength * weight * sway * s
                        ox = d * ca - 0.3 * d * sa
                        oy = d * sa + 0.3 * d * ca
                    case .heatHaze:
                        let n = valueNoise(X * 5 / scale, Y * 5 / scale, 11)
                        ox = 0.006 * strength * s * sin(twoPi * (16 / scale) * Y - theta + twoPi * n)
                        oy = 0.003 * strength * s * sin(twoPi * (13 / scale) * X - 2 * theta + twoPi * n)
                    case .shimmer:
                        let n = valueNoise(X * 45 / scale, Y * 45 / scale, 3)
                        var sp = max(0, sin(theta + twoPi * n))
                        sp = sp * sp * sp * sp * sp * sp
                        add = 150 * strength * sp
                        lumaAdd = true
                        ox = 0.0015 * strength * s * (n - 0.5)
                    case .pulse:
                        let z = 1 + 0.03 * strength * sin(theta)
                        ox = (Float(x) - cxp) * (1 / z - 1)
                        oy = (Float(y) - cyp) * (1 / z - 1)
                        gain = 1 + 0.06 * strength * sin(theta)
                    case .lightSweep:
                        let t = X * ca + Y * sa
                        let t01 = (t - minT) / spanT
                        let half = 0.12 * scale
                        let c = -half + (1 + 2 * half) * sweepPos
                        let q = (t01 - c) / half
                        var bump = max(0, 1 - q * q)
                        bump = bump * bump
                        add = 130 * strength * bump
                    case .wobble:
                        let rot = 0.035 * strength * sin(theta)
                        let rx = Float(x) - cxp, ry = Float(y) - cyp
                        let c = cos(rot), sn = sin(rot)
                        ox = (c - 1) * rx - sn * ry
                        oy = sn * rx + (c - 1) * ry
                    case .wiggle:
                        let rot = jr * 0.012 * strength
                        let rx = Float(x) - cxp, ry = Float(y) - cyp
                        let c = cos(rot), sn = sin(rot)
                        ox = jx * 0.006 * strength * s + (c - 1) * rx - sn * ry
                        oy = jy * 0.006 * strength * s + sn * rx + (c - 1) * ry
                    case .swirl:
                        let rx = Float(x) - cxp, ry = Float(y) - cyp
                        let r = (rx * rx + ry * ry).squareRoot() / s
                        let sigma = 0.22 * scale
                        let a = 1.6 * strength * sin(theta) * exp(-(r * r) / (sigma * sigma))
                        let c = cos(a), sn = sin(a)
                        ox = (c - 1) * rx - sn * ry
                        oy = sn * rx + (c - 1) * ry
                    case .glitch:
                        break
                    }
                    ox *= m; oy *= m; add *= m
                    gain = 1 + (gain - 1) * m
                    if ox == 0 && oy == 0 && add == 0 && gain == 1 { continue }
                    let px = bilinear(srcPtr, w, h, Float(x) + ox, Float(y) + oy)
                    var b = px.b * gain, g = px.g * gain, r = px.r * gain
                    if add != 0 {
                        if kind == .lightSweep {
                            r += add; g += add * 0.93; b += add * 0.8
                        } else {
                            let l = lumaAdd ? (0.25 + (px.r * 0.3 + px.g * 0.59 + px.b * 0.11) / 255) : 1
                            r += add * l; g += add * l; b += add * l * 0.95
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
