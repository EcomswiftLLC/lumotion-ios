import Foundation
import CoreGraphics

/// Colour layout shared by every bitmap the engine touches: 8-bit BGRA, premultiplied alpha, sRGB, top row first.
enum PixelFormat {
    static let bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// A bitmap owned by the engine. Rows are tightly packed (`width * 4` bytes); pixels are B, G, R, A with premultiplied alpha.
final class PixelBuffer {
    let width: Int
    let height: Int
    let data: UnsafeMutablePointer<UInt8>

    var rowBytes: Int { width * 4 }
    var byteCount: Int { width * height * 4 }

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        let count = self.width * self.height * 4
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        data.initialize(repeating: 0, count: count)
    }

    deinit { data.deallocate() }

    func clone() -> PixelBuffer {
        let copy = PixelBuffer(width: width, height: height)
        memcpy(copy.data, data, byteCount)
        return copy
    }

    /// Copies the pixels of `other`, which must be the same size.
    func copy(from other: PixelBuffer) {
        guard other.width == width, other.height == height else { return }
        memcpy(data, other.data, byteCount)
    }

    func clear() {
        memset(data, 0, byteCount)
    }

    /// Fills with one opaque colour.
    func fill(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        var i = 0
        let n = width * height
        while i < n {
            let o = i * 4
            data[o] = b; data[o + 1] = g; data[o + 2] = r; data[o + 3] = a
            i += 1
        }
    }

    /// Runs drawing code in a CoreGraphics context that writes straight into this buffer. The context uses the usual
    /// CoreGraphics orientation (origin bottom left); call `topLeftOrigin` on it to draw with y growing downwards.
    @discardableResult
    func withContext<T>(_ body: (CGContext) -> T) -> T? {
        guard let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: PixelFormat.colorSpace, bitmapInfo: PixelFormat.bitmapInfo) else { return nil }
        return body(ctx)
    }

    /// An independent CGImage copy of the pixels.
    func makeCGImage() -> CGImage? {
        let bytes = Data(bytes: data, count: byteCount)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: PixelFormat.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: PixelFormat.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws a picture scaled to cover `width` x `height` exactly (stretching if the shapes differ).
    static func scaled(_ image: CGImage, width: Int, height: Int) -> PixelBuffer? {
        let buffer = PixelBuffer(width: width, height: height)
        let ok: Bool? = buffer.withContext { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
            return true
        }
        return ok == true ? buffer : nil
    }
}

extension CGContext {
    /// Makes y grow downwards from the top left, like the pixel buffer's rows. Images and text drawn afterwards appear
    /// upside down unless drawn with `drawImageTopLeft`.
    func topLeftOrigin(height: Int) {
        translateBy(x: 0, y: CGFloat(height))
        scaleBy(x: 1, y: -1)
    }

    /// Draws an image upright into `rect` of a context set up with `topLeftOrigin`.
    func drawImageTopLeft(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}

// MARK: - Parallel loops

/// Splits rows `y0..<y1` into chunks and runs `body(rowStart, rowEnd)` on several cores.
@inline(__always)
func parallelRows(_ y0: Int, _ y1: Int, _ body: (Int, Int) -> Void) {
    let rows = y1 - y0
    if rows <= 0 { return }
    let chunk = max(4, (rows + 31) / 32)
    let count = (rows + chunk - 1) / chunk
    if count <= 1 {
        body(y0, y1)
        return
    }
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let a = y0 + i * chunk
        let b = min(y1, a + chunk)
        body(a, b)
    }
}

// MARK: - Sampling

/// One pixel as floats, premultiplied BGRA, 0...255.
struct Pix4 {
    var b: Float
    var g: Float
    var r: Float
    var a: Float
}

/// Bilinear sample at pixel coordinates (an integer coordinate is the centre of that pixel). Coordinates outside the
/// picture use the nearest edge pixel.
@inline(__always)
func bilinear(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Pix4 {
    let cx = min(max(x, 0), Float(w - 1))
    let cy = min(max(y, 0), Float(h - 1))
    let x0 = Int(cx)
    let y0 = Int(cy)
    let x1 = min(x0 + 1, w - 1)
    let y1 = min(y0 + 1, h - 1)
    let fx = cx - Float(x0)
    let fy = cy - Float(y0)
    let i00 = (y0 * w + x0) * 4
    let i10 = (y0 * w + x1) * 4
    let i01 = (y1 * w + x0) * 4
    let i11 = (y1 * w + x1) * 4
    let w00 = (1 - fx) * (1 - fy)
    let w10 = fx * (1 - fy)
    let w01 = (1 - fx) * fy
    let w11 = fx * fy
    return Pix4(
        b: Float(src[i00]) * w00 + Float(src[i10]) * w10 + Float(src[i01]) * w01 + Float(src[i11]) * w11,
        g: Float(src[i00 + 1]) * w00 + Float(src[i10 + 1]) * w10 + Float(src[i01 + 1]) * w01 + Float(src[i11 + 1]) * w11,
        r: Float(src[i00 + 2]) * w00 + Float(src[i10 + 2]) * w10 + Float(src[i01 + 2]) * w01 + Float(src[i11 + 2]) * w11,
        a: Float(src[i00 + 3]) * w00 + Float(src[i10 + 3]) * w10 + Float(src[i01 + 3]) * w01 + Float(src[i11 + 3]) * w11)
}

/// Bilinear sample of a one-channel float field stored row by row.
@inline(__always)
func bilinearField(_ f: UnsafePointer<Float>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
    let cx = min(max(x, 0), Float(w - 1))
    let cy = min(max(y, 0), Float(h - 1))
    let x0 = Int(cx)
    let y0 = Int(cy)
    let x1 = min(x0 + 1, w - 1)
    let y1 = min(y0 + 1, h - 1)
    let fx = cx - Float(x0)
    let fy = cy - Float(y0)
    let top = f[y0 * w + x0] + (f[y0 * w + x1] - f[y0 * w + x0]) * fx
    let bottom = f[y1 * w + x0] + (f[y1 * w + x1] - f[y1 * w + x0]) * fx
    return top + (bottom - top) * fy
}

@inline(__always)
func clamp255(_ v: Float) -> UInt8 {
    if v <= 0 { return 0 }
    if v >= 255 { return 255 }
    return UInt8(v + 0.5)
}

@inline(__always)
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Determinism helpers

@inline(__always)
func hash32(_ value: UInt32) -> UInt32 {
    var h = value
    h ^= h >> 16
    h = h &* 0x7feb352d
    h ^= h >> 15
    h = h &* 0x846ca68b
    h ^= h >> 16
    return h
}

@inline(__always)
func hash3(_ a: Int, _ b: Int, _ c: Int) -> UInt32 {
    let ha = hash32(UInt32(truncatingIfNeeded: a) &+ 0x9E3779B1)
    let hb = hash32(ha ^ (UInt32(truncatingIfNeeded: b) &* 0x85EBCA6B))
    return hash32(hb ^ (UInt32(truncatingIfNeeded: c) &* 0xC2B2AE35))
}

/// 0...1 from three integers.
@inline(__always)
func hashUnit(_ a: Int, _ b: Int, _ c: Int) -> Float {
    Float(hash3(a, b, c) & 0xFFFFFF) / Float(0x1000000)
}

/// Smooth value noise, 0...1. The same input always gives the same output.
@inline(__always)
func valueNoise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
    let xf = x.rounded(.down)
    let yf = y.rounded(.down)
    let ix = Int(xf)
    let iy = Int(yf)
    let fx = x - xf
    let fy = y - yf
    let sx = fx * fx * (3 - 2 * fx)
    let sy = fy * fy * (3 - 2 * fy)
    let a = hashUnit(ix, iy, seed)
    let b = hashUnit(ix + 1, iy, seed)
    let c = hashUnit(ix, iy + 1, seed)
    let d = hashUnit(ix + 1, iy + 1, seed)
    let top = a + (b - a) * sx
    let bottom = c + (d - c) * sx
    return top + (bottom - top) * sy
}

/// A small seeded random generator (SplitMix64). Same seed, same sequence, on every device.
struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double {
        Double(next() >> 11) / 9007199254740992.0
    }

    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * unit()
    }
}

/// Stable digest of any hashable value within one process, used to key caches.
func digest<T: Hashable>(_ value: T) -> Int {
    var hasher = Hasher()
    hasher.combine(value)
    return hasher.finalize()
}
