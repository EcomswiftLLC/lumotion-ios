import Foundation
import CoreGraphics
import CoreImage

// MARK: - Errors

/// Errors the engine can throw. `errorDescription` is written for people and can be shown as is.
enum EngineError: LocalizedError {
    case cancelled
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The export was cancelled."
        case .unsupported(let what): return what
        case .failed(let what): return what
        }
    }

    /// True for `.cancelled`. Callers use it to stay quiet when the person pressed Cancel instead of showing an error.
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// True when `error` means "the person stopped it": `EngineError.cancelled` or a Swift `CancellationError`.
    static func isCancellation(_ error: Error) -> Bool {
        if let engine = error as? EngineError { return engine.isCancelled }
        return error is CancellationError
    }
}

// MARK: - Housekeeping (what the app should call, and when)
//
// - Launch: `Exporter.clearOldExports()` deletes exports older than a day; `ProjectStore.shared.cleanUpOrphans()` removes
//   project folders that never got a project.json.
// - After each finished export: `Exporter.clearOldExports(keeping: [url])` frees the older files and keeps the new one.
// - Memory warning: `engine.handleMemoryWarning()` on the live engine (drops render caches, text bitmaps and decoded
//   cinemagraph frames).
// - Export sizes: `exporter.availableResolutions(codec:)` lists the sizes worth offering (a cinemagraph cannot fill 4K);
//   `exporter.maxUsefulExportLongEdge` is the raw limit. `estimateGIF(options:)` sets `isCapped` and `warning` when the
//   GIF frame rate had to be lowered to stay within memory.
// - Errors: `EngineError.isCancelled` / `EngineError.isCancellation(_:)` tell "the person pressed Cancel" from a failure.

// MARK: - Cancellation

/// A flag that can be set from any thread to stop a render or an export that is in progress.
final class RenderToken {
    private let lock = NSLock()
    private var flag = false

    init() {}

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

// MARK: - Quality

/// How big a frame should be rendered. The long edge is the larger side of the canvas in pixels.
struct RenderQuality: Hashable {
    var longEdge: Int

    init(longEdge: Int) { self.longEdge = max(16, min(longEdge, 4096)) }

    /// Scrubbing while a finger is down.
    static let draft = RenderQuality(longEdge: 360)
    /// Normal on-screen preview (the spec caps previews at 720 px).
    static let preview = RenderQuality(longEdge: 720)
    /// Large preview on iPad or for the compare view.
    static let high = RenderQuality(longEdge: 1440)
    static func export(longEdge: Int) -> RenderQuality { RenderQuality(longEdge: longEdge) }
}

// MARK: - Masks

/// A single-channel picture, one byte per pixel: 0 is nothing, 255 is full. Used for subject masks, depth maps and
/// brush masks. Immutable, so it can be shared freely between threads.
final class MaskBuffer {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(width: Int, height: Int, data: [UInt8]) {
        self.width = max(1, width)
        self.height = max(1, height)
        let count = self.width * self.height
        if data.count == count {
            self.data = data
        } else {
            var fixed = data
            if fixed.count > count { fixed.removeLast(fixed.count - count) } else { fixed.append(contentsOf: [UInt8](repeating: 0, count: count - fixed.count)) }
            self.data = fixed
        }
    }

    convenience init(width: Int, height: Int, value: UInt8) {
        self.init(width: width, height: height, data: [UInt8](repeating: value, count: max(1, width) * max(1, height)))
    }

    /// Bilinear sample, `u` and `v` in 0...1 across the whole buffer. Outside the buffer the nearest edge pixel is used.
    func sample(u: Double, v: Double) -> Double {
        guard u.isFinite, v.isFinite else { return 0 }
        let x = min(max(u * Double(width) - 0.5, 0), Double(width - 1))
        let y = min(max(v * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = Double(data[y0 * width + x0]), b = Double(data[y0 * width + x1])
        let c = Double(data[y1 * width + x0]), d = Double(data[y1 * width + x1])
        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return (top + (bottom - top) * fy) / 255
    }

    /// Mean value 0...1.
    var average: Double {
        guard !data.isEmpty else { return 0 }
        var sum = 0
        for v in data { sum += Int(v) }
        return Double(sum) / Double(data.count) / 255
    }

    /// A grey CGImage of the mask, for saving as PNG.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Reads any picture as a mask using its brightness. Optionally resamples to `width` x `height`.
    static func from(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> MaskBuffer? {
        let w = max(1, width ?? image.width)
        let h = max(1, height ?? image.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? MaskBuffer(width: w, height: h, data: bytes) : nil
    }

    /// A bilinear resample.
    func resized(width newWidth: Int, height newHeight: Int) -> MaskBuffer {
        let w = max(1, newWidth), h = max(1, newHeight)
        if w == width && h == height { return self }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                out[y * w + x] = UInt8(min(255, max(0, (sample(u: u, v: v) * 255).rounded())))
            }
        }
        return MaskBuffer(width: w, height: h, data: out)
    }
}

// MARK: - Source assets

/// The decoded inputs an engine needs next to the `Project` value. Built by `ProjectStore.loadAssets` or by hand
/// when a photo has just been picked.
struct SourceAssets {
    /// The photo, upright. Nil for a video project.
    var still: CGImage?
    /// The video file for a cinemagraph project.
    var videoURL: URL?
    /// White is the foreground subject, in photo coordinates. Optional, see `MaskProvider.subjectMask`.
    var subjectMask: MaskBuffer?
    /// Depth stored in the photo (near is white), in photo coordinates. Optional.
    var embeddedDepth: MaskBuffer?
    /// The person's audio file, when the project has one.
    var audioURL: URL?

    init(still: CGImage? = nil, videoURL: URL? = nil, subjectMask: MaskBuffer? = nil, embeddedDepth: MaskBuffer? = nil, audioURL: URL? = nil) {
        self.still = still
        self.videoURL = videoURL
        self.subjectMask = subjectMask
        self.embeddedDepth = embeddedDepth
        self.audioURL = audioURL
    }
}

// MARK: - Export options

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
}

/// Size of an exported video: the long edge of the canvas.
enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case p720, p1080, k2, k4
    var id: String { rawValue }
    var longEdge: Int {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        case .k2: return 2560
        case .k4: return 3840
        }
    }
    var title: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .k2: return "2K"
        case .k4: return "4K"
        }
    }
}

enum StillFormat: String, Codable, CaseIterable, Identifiable {
    case jpg, png, heic
    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

/// GIF settings. The palette is a fixed colour cube so every frame uses the same colours (no flicker).
struct GIFOptions: Hashable {
    /// Pixel width, 320...1080.
    var width: Int = 480
    /// Frames per second, 5...30.
    var fps: Int = 15
    /// 16...256 colours.
    var paletteColors: Int = 256
    /// Ordered dithering hides banding with a stable pattern.
    var dither: Bool = true

    init(width: Int = 480, fps: Int = 15, paletteColors: Int = 256, dither: Bool = true) {
        self.width = width; self.fps = fps; self.paletteColors = paletteColors; self.dither = dither
    }

    var clamped: GIFOptions {
        GIFOptions(width: min(max(width, 160), 1080), fps: min(max(fps, 5), 30), paletteColors: min(max(paletteColors, 16), 256), dither: dither)
    }
}

/// What an export will roughly produce.
struct ExportEstimate: Hashable {
    /// Estimated file size in bytes. A guide, not a promise.
    var bytes: Int64
    var frameCount: Int
    var width: Int
    var height: Int
    /// Set when the engine had to lower a setting to stay within memory, for example fewer GIF frames.
    var note: String?
    /// True when `note` explains a lowered setting (the GIF has fewer frames per second than asked for).
    var isCapped: Bool = false

    /// The text to show next to the estimate when a setting was lowered; nil otherwise.
    var warning: String? { isCapped ? note : nil }
}

/// Progress callback, called with 0...1 from a background thread.
typealias ExportProgress = @Sendable (Double) -> Void

// MARK: - Presets

enum PresetCategory: String, CaseIterable, Identifiable {
    case flow, weather, light, camera
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flow: return "Flow"
        case .weather: return "Weather"
        case .light: return "Light"
        case .camera: return "Camera"
        }
    }
}

/// A one-tap starting point. Applying it (see `PresetLibrary.apply`) fills in effects, overlays, camera, look and loop
/// length, and adds a default flow region the person can edit.
struct PresetInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// One honest sentence on what the preset does.
    let summary: String
    let category: PresetCategory
    /// SF Symbol name for the preset tile when no preview is available.
    let symbol: String
}
