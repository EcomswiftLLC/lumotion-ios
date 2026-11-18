import Foundation
import CoreGraphics

/// Per-frame finishing: animated film grain and light flicker.
enum PostFX {
    /// Eight different 256 x 256 noise tiles, built once. Values are -127...127.
    private static let grainTiles: [[Int8]] = {
        (0..<8).map { tile in
            (0..<(256 * 256)).map { i in
                let a = hashUnit(i, tile, 77)
                let b = hashUnit(i, tile, 78)
                // Sum of two uniforms: a soft bell shape.
                return Int8(max(-127, min(127, ((a + b) - 1) * 127)))
            }
        }
    }()

    /// Whole number of grain patterns per loop (about 12 per second).
    static func grainSteps(duration: Double) -> Int { max(1, Int((duration * 12).rounded())) }

    /// Applies grain and flicker in place. Does nothing when both are off.
    static func apply(look: Look, buffer: PixelBuffer, phase p: Double, loop: LoopSpec) {
        let grain = Float(min(max(look.adjust.grain, 0), 1))
        let flicker = Float(min(max(look.flicker.amount, 0), 1))
        if grain <= 0 && flicker <= 0 { return }
        let w = buffer.width, h = buffer.height
        var gain: Float = 1
        if flicker > 0 {
            let speed = min(max(look.flicker.speed, 0.1), 3) * min(max(loop.speed, 0.25), 4)
            let k = max(1, Int((speed * 0.8 * loop.clampedDuration).rounded()))
            let t = 2 * Float.pi * Float(p)
            gain = 1 + flicker * 0.12 * (0.65 * sin(t * Float(k)) + 0.35 * sin(t * Float(2 * k + 1) + 1.3))
        }
        var tile = 0, ox = 0, oy = 0
        if grain > 0 {
            let steps = grainSteps(duration: loop.clampedDuration)
            let index = look.animatedGrain ? Int((p * Double(steps)).rounded(.down)) % steps : 0
            tile = index % 8
            ox = Int(hash3(index, 1, 9) & 255)
            oy = Int(hash3(index, 2, 9) & 255)
        }
        let scale = max(1, Int((Double(max(w, h)) / 720).rounded()))
        let amount = grain * 38
        let ptr = buffer.data
        let tiles = grainTiles
        parallelRows(0, h) { ra, rb in
            tiles[tile].withUnsafeBufferPointer { noise in
                for y in ra..<rb {
                    let ty = ((y / scale) + oy) & 255
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        var b = Float(ptr[i]), g = Float(ptr[i + 1]), r = Float(ptr[i + 2])
                        if gain != 1 { b *= gain; g *= gain; r *= gain }
                        if grain > 0 {
                            let tx = ((x / scale) + ox) & 255
                            let n = Float(noise[ty * 256 + tx]) / 127
                            let lum = (r * 0.3 + g * 0.59 + b * 0.11) / 255
                            let weight = 1 - abs(2 * lum - 1) * 0.5
                            let d = n * amount * weight
                            r += d; g += d; b += d
                        }
                        ptr[i] = clamp255(b)
                        ptr[i + 1] = clamp255(g)
                        ptr[i + 2] = clamp255(r)
                    }
                }
            }
        }
    }
}

/// Layer compositing helpers.
enum PixelOps {
    /// Draws `layer` (premultiplied) over `dst`. `holdout` (0...1, same size) keeps the layer away where it is 1: used to
    /// put an overlay behind the subject.
    static func over(_ dst: PixelBuffer, layer: PixelBuffer, holdout: FloatField?) {
        guard dst.width == layer.width, dst.height == layer.height else { return }
        let w = dst.width, h = dst.height
        let d = dst.data, l = layer.data
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let la = Int(l[i + 3])
                    if la == 0 && l[i] == 0 && l[i + 1] == 0 && l[i + 2] == 0 { continue }
                    var k: Float = 1
                    if let holdout { k = 1 - holdout.data[y * w + x] }
                    if k <= 0 { continue }
                    let inv = 1 - Float(la) / 255 * k
                    d[i] = clamp255(Float(d[i]) * inv + Float(l[i]) * k)
                    d[i + 1] = clamp255(Float(d[i + 1]) * inv + Float(l[i + 1]) * k)
                    d[i + 2] = clamp255(Float(d[i + 2]) * inv + Float(l[i + 2]) * k)
                }
            }
        }
    }

    /// Adds `layer` to `dst` (light on top of the picture). Honours `holdout` like `over`.
    static func add(_ dst: PixelBuffer, layer: PixelBuffer, holdout: FloatField?) {
        guard dst.width == layer.width, dst.height == layer.height else { return }
        let w = dst.width, h = dst.height
        let d = dst.data, l = layer.data
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if l[i] == 0 && l[i + 1] == 0 && l[i + 2] == 0 { continue }
                    var k: Float = 1
                    if let holdout { k = 1 - holdout.data[y * w + x] }
                    if k <= 0 { continue }
                    d[i] = clamp255(Float(d[i]) + Float(l[i]) * k)
                    d[i + 1] = clamp255(Float(d[i + 1]) + Float(l[i + 1]) * k)
                    d[i + 2] = clamp255(Float(d[i + 2]) + Float(l[i + 2]) * k)
                }
            }
        }
    }

    /// `dst = dst * (1 - m) + other * m` for every pixel with a mask value above zero.
    static func blend(_ dst: PixelBuffer, with other: PixelBuffer, mask: FloatField) {
        guard dst.width == other.width, dst.height == other.height else { return }
        let w = dst.width, h = dst.height
        let d = dst.data, o = other.data
        let invW = 1 / Float(w), invH = 1 / Float(h)
        parallelRows(0, h) { ra, rb in
            for y in ra..<rb {
                let v = (Float(y) + 0.5) * invH
                for x in 0..<w {
                    let m = mask.sample(u: (Float(x) + 0.5) * invW, v: v)
                    if m <= 0.003 { continue }
                    let i = (y * w + x) * 4
                    let inv = 1 - m
                    d[i] = clamp255(Float(d[i]) * inv + Float(o[i]) * m)
                    d[i + 1] = clamp255(Float(d[i + 1]) * inv + Float(o[i + 1]) * m)
                    d[i + 2] = clamp255(Float(d[i + 2]) * inv + Float(o[i + 2]) * m)
                    d[i + 3] = clamp255(Float(d[i + 3]) * inv + Float(o[i + 3]) * m)
                }
            }
        }
    }
}
