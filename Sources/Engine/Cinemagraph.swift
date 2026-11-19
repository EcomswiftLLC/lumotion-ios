import Foundation
import CoreGraphics
import AVFoundation

// MARK: - Canvas composition

/// Puts the source picture onto the canvas: crop and zoom for `fill`, whole picture with a background for `fit`.
enum CanvasCompose {
    /// Canvas rectangle (in pixels, y down) that the whole photo covers. Larger than the canvas when cropping.
    static func photoRect(mapping: FrameMapping, width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        return CGRect(x: -mapping.bx / mapping.ax * w, y: -mapping.by / mapping.ay * h, width: w / mapping.ax, height: h / mapping.ay)
    }

    /// Renders a photo onto a canvas of `width` x `height` pixels.
    static func compose(image: CGImage, canvas: CanvasSpec, sourceAspect: Double, width: Int, height: Int) -> PixelBuffer? {
        let mapping = FrameMapping(canvas: canvas, sourceAspect: sourceAspect)
        let buffer = PixelBuffer(width: width, height: height)
        let rect = photoRect(mapping: mapping, width: width, height: height)
        let ok: Bool? = buffer.withContext { ctx in
            ctx.topLeftOrigin(height: height)
            ctx.interpolationQuality = .high
            if canvas.fit == .fit {
                switch canvas.background {
                case .color:
                    let c = canvas.backgroundColor
                    ctx.setFillColor(CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                case .blur:
                    drawBlurredBackground(image: image, ctx: ctx, sourceAspect: sourceAspect, canvas: canvas, width: width, height: height)
                }
            }
            ctx.drawImageTopLeft(image, in: rect)
            return true
        }
        return ok == true ? buffer : nil
    }

    private static func drawBlurredBackground(image: CGImage, ctx: CGContext, sourceAspect: Double, canvas: CanvasSpec, width: Int, height: Int) {
        var fill = CanvasSpec()
        fill.aspect = canvas.aspect
        fill.fit = .fill
        let fillMapping = FrameMapping(canvas: fill, sourceAspect: sourceAspect)
        let sw = max(4, width / 8), sh = max(4, height / 8)
        let small = PixelBuffer(width: sw, height: sh)
        small.withContext { c in
            c.topLeftOrigin(height: sh)
            c.interpolationQuality = .medium
            c.drawImageTopLeft(image, in: photoRect(mapping: fillMapping, width: sw, height: sh))
        }
        boxBlur3(small, passes: 3)
        if let blurred = small.makeCGImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.drawImageTopLeft(blurred, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.restoreGState()
        }
    }

    /// 3 x 3 box blur applied `passes` times, in place. For small pictures only.
    static func boxBlur3(_ buffer: PixelBuffer, passes: Int) {
        let w = buffer.width, h = buffer.height
        for _ in 0..<passes {
            let tmp = buffer.clone()
            for y in 0..<h {
                for x in 0..<w {
                    var b = 0, g = 0, r = 0, a = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                            let i = (yy * w + xx) * 4
                            b += Int(tmp.data[i]); g += Int(tmp.data[i + 1]); r += Int(tmp.data[i + 2]); a += Int(tmp.data[i + 3])
                        }
                    }
                    let o = (y * w + x) * 4
                    buffer.data[o] = UInt8(b / 9); buffer.data[o + 1] = UInt8(g / 9); buffer.data[o + 2] = UInt8(r / 9); buffer.data[o + 3] = UInt8(a / 9)
                }
            }
        }
    }

    /// Resamples a picture that has the shape of the source into canvas space. Canvas pixels outside the photo stay transparent.
    static func resample(_ raw: PixelBuffer, mapping: FrameMapping, width: Int, height: Int) -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        let rw = Float(raw.width), rh = Float(raw.height)
        let ax = Float(mapping.ax), bx = Float(mapping.bx), ay = Float(mapping.ay), by = Float(mapping.by)
        let rawPtr = UnsafePointer<UInt8>(raw.data)
        let outPtr = out.data
        let rwI = raw.width, rhI = raw.height
        parallelRows(0, height) { ra, rb in
            for y in ra..<rb {
                let sv = ay * (Float(y) + 0.5) / Float(height) + by
                if sv < 0 || sv > 1 { continue }
                for x in 0..<width {
                    let su = ax * (Float(x) + 0.5) / Float(width) + bx
                    if su < 0 || su > 1 { continue }
                    let px = bilinear(rawPtr, rwI, rhI, su * rw - 0.5, sv * rh - 0.5)
                    let i = (y * width + x) * 4
                    outPtr[i] = clamp255(px.b); outPtr[i + 1] = clamp255(px.g); outPtr[i + 2] = clamp255(px.r); outPtr[i + 3] = clamp255(px.a)
                }
            }
        }
        return out
    }
}

// MARK: - Video frames

/// Frame slots filled from the decoder's background threads.
private final class FrameSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [PixelBuffer?]
    init(count: Int) { slots = [PixelBuffer?](repeating: nil, count: count) }
    func set(_ index: Int, _ buffer: PixelBuffer) { lock.lock(); slots[index] = buffer; lock.unlock() }
    func snapshot() -> [PixelBuffer?] { lock.lock(); defer { lock.unlock() }; return slots }
}

/// How one cinemagraph segment is sampled: how many frames, at what rate and size. A pure function of the video, the
/// segment and a byte budget, so the preview, the exporter and `RenderEngine.maxUsefulExportLongEdge` always agree.
struct VideoFramePlan: Equatable {
    var segmentStart: Double
    var segmentLength: Double
    var fps: Double
    var count: Int
    var width: Int
    var height: Int

    var byteCost: Int { count * width * height * 4 }
}

/// The frames of one cinemagraph segment, held in memory at one fixed size so they can be read in any order while
/// scrubbing and exporting. The video is read once, with AVAssetImageGenerator. A few frames per second at a larger size
/// beat many frames at a small size: neighbouring frames are mixed, so the motion stays smooth.
final class VideoFrameStore {
    let width: Int
    let height: Int
    /// Frames per second the segment was sampled at.
    let fps: Double
    /// Length of the segment in seconds.
    let length: Double
    private let frames: [PixelBuffer]

    init(width: Int, height: Int, fps: Double, length: Double, frames: [PixelBuffer]) {
        self.width = width; self.height = height; self.fps = fps; self.length = length; self.frames = frames
    }

    var byteCost: Int { frames.count * width * height * 4 }
    var frameCount: Int { frames.count }

    /// The picture `seconds` into the segment (0...length). Neighbouring frames are mixed, so slow sampling stays smooth.
    func frame(at seconds: Double) -> PixelBuffer {
        let clamped = seconds.isFinite ? seconds : 0
        let t = min(max(clamped, 0), length) * fps
        let i0 = min(frames.count - 1, Int(t.rounded(.down)))
        let i1 = min(frames.count - 1, i0 + 1)
        let f = Float(t - Double(i0))
        if i0 == i1 || f < 0.02 { return frames[i0] }
        if f > 0.98 { return frames[i1] }
        return VideoFrameStore.mix(frames[i0], frames[i1], f)
    }

    /// `a * (1 - t) + b * t`
    static func mix(_ a: PixelBuffer, _ b: PixelBuffer, _ t: Float) -> PixelBuffer {
        guard a.width == b.width, a.height == b.height else { return a }
        let out = PixelBuffer(width: a.width, height: a.height)
        let n = a.byteCount
        let inv = 1 - t
        let pa = a.data, pb = b.data, po = out.data
        parallelRows(0, a.height) { ra, rb in
            let start = ra * a.width * 4, end = min(n, rb * a.width * 4)
            var i = start
            while i < end {
                po[i] = clamp255(Float(pa[i]) * inv + Float(pb[i]) * t)
                i += 1
            }
        }
        return out
    }

    // MARK: Video facts

    private static let infoLock = NSLock()
    private static var infoCache: [String: (size: CGSize, fps: Double, duration: Double)] = [:]

    /// Display size of the first video track (rotation applied) and its nominal frame rate. Nil when the file has no video.
    static func videoInfo(_ url: URL) -> (size: CGSize, fps: Double, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let t = track.naturalSize.applying(track.preferredTransform)
        let size = CGSize(width: abs(t.width), height: abs(t.height))
        if size.width < 1 || size.height < 1 { return nil }
        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30
        return (size, fps, CMTimeGetSeconds(asset.duration))
    }

    /// `videoInfo`, remembered per file so the editor can ask often (for example for the export sizes) without reopening the file.
    static func cachedVideoInfo(_ url: URL) -> (size: CGSize, fps: Double, duration: Double)? {
        let key = url.path
        infoLock.lock()
        if let hit = infoCache[key] { infoLock.unlock(); return hit }
        infoLock.unlock()
        guard let info = videoInfo(url) else { return nil }
        infoLock.lock()
        infoCache[key] = info
        infoLock.unlock()
        return info
    }

    /// Bytes the decoded frames of one segment may use: 6 percent of the device memory, between 96 and 256 MB.
    static var defaultBudgetBytes: Int {
        let ram = Int(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max / 4)))
        return min(256 * 1024 * 1024, max(96 * 1024 * 1024, ram / 100 * 6))
    }

    /// Frame rate, count and size for a segment. Segments up to 4 seconds are sampled at 15 frames per second, longer
    /// ones at 12 (never above the video's own rate); the size is the largest the byte budget allows, never above the
    /// video itself.
    static func plan(videoSize: CGSize, videoFPS: Double, videoDuration: Double, start: Double, length: Double, budgetBytes: Int) -> VideoFramePlan {
        let total = max(0.1, videoDuration.isFinite ? videoDuration : start + length)
        let segStart = min(max(start.isFinite ? start : 0, 0), max(0, total - 0.1))
        let segLength = max(0.1, min(length.isFinite ? length : 1, total - segStart))
        let preferred = segLength <= 4 ? 15.0 : 12.0
        let fps = min(preferred, max(8, videoFPS))
        let count = max(2, Int((segLength * fps).rounded(.up)) + 1)
        let aspect = Double(videoSize.width / max(1, videoSize.height))
        let pixelsPerFrame = Double(max(1, budgetBytes)) / Double(count) / 4
        var h = (pixelsPerFrame / aspect).squareRoot()
        var w = h * aspect
        if w > Double(videoSize.width) || h > Double(videoSize.height) {
            let k = min(Double(videoSize.width) / w, Double(videoSize.height) / h)
            w *= k; h *= k
        }
        var fw = max(16, Int((w / 2).rounded()) * 2), fh = max(16, Int((h / 2).rounded()) * 2)
        // Rounding to even sizes can overshoot the budget by a few kilobytes; step down until the frames fit.
        while fw > 16 && count * fw * fh * 4 > budgetBytes {
            fw -= 2
            fh = max(16, Int((Double(fw) / aspect / 2).rounded()) * 2)
        }
        return VideoFramePlan(segmentStart: segStart, segmentLength: segLength, fps: fps, count: count, width: fw, height: fh)
    }

    /// Reads the segment `start ... start + length` (seconds) once, at the size `plan` gives. Returns nil when the file
    /// cannot be read or `token` is cancelled. With `stabilize` every frame is shifted to line up with the picture at
    /// `stillTime` (see `Stabilizer`).
    static func extract(url: URL, start: Double, length: Double, budgetBytes: Int, stabilize: Bool = false, stillTime: Double = 0, token: RenderToken?) -> VideoFrameStore? {
        guard let info = videoInfo(url) else { return nil }
        let asset = AVURLAsset(url: url)
        let plan = VideoFrameStore.plan(videoSize: info.size, videoFPS: info.fps, videoDuration: info.duration, start: start, length: length, budgetBytes: budgetBytes)
        let total = max(0.1, info.duration.isFinite ? info.duration : start + length)
        let segStart = plan.segmentStart, segLength = plan.segmentLength
        let storeFPS = plan.fps, count = plan.count, fw = plan.width, fh = plan.height

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: fw, height: fh)
        let tolerance = CMTime(seconds: 0.5 / storeFPS, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var times = [NSValue]()
        for i in 0..<count {
            let t = min(segStart + Double(i) / storeFPS, max(segStart, total - 0.05))
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
        }
        let slotBox = FrameSlots(count: count)
        let group = DispatchGroup()
        for _ in 0..<count { group.enter() }
        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
            defer { group.leave() }
            if token?.isCancelled == true { generator.cancelAllCGImageGeneration(); return }
            guard result == .succeeded, let image else { return }
            let index = min(count - 1, max(0, Int(((CMTimeGetSeconds(requested) - segStart) * storeFPS).rounded())))
            guard let buffer = PixelBuffer.scaled(image, width: fw, height: fh) else { return }
            slotBox.set(index, buffer)
        }
        group.wait()
        if token?.isCancelled == true { return nil }
        // Fill any frame the decoder could not give us from its neighbour.
        let slots = slotBox.snapshot()
        guard let firstGood = slots.first(where: { $0 != nil }) ?? nil else { return nil }
        var frames = [PixelBuffer]()
        var last = firstGood
        for slot in slots {
            if let s = slot { last = s }
            frames.append(slot ?? last)
        }
        if stabilize, frames.count > 1 {
            if let still = VideoFrameStore.still(url: url, at: stillTime, maxPixel: max(fw, fh)),
               let reference = PixelBuffer.scaled(still, width: fw, height: fh) {
                frames = Stabilizer.align(frames, to: reference, token: token)
            }
            if token?.isCancelled == true { return nil }
        }
        return VideoFrameStore(width: fw, height: fh, fps: storeFPS, length: segLength, frames: frames)
    }

    /// One picture from the video at full resolution (capped), for the frozen part of a cinemagraph.
    static func still(url: URL, at seconds: Double, maxPixel: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let duration = CMTimeGetSeconds(asset.duration)
        let t = min(max(seconds, 0), duration.isFinite ? max(0, duration - 0.05) : seconds)
        return try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
    }
}

// MARK: - Shared frame store

/// Keeps the decoded frames of the segment that is being edited, shared by the live preview and the exporter so the
/// video is read once per project, not once per preview quality. Holds one store at a time. Decoding happens outside
/// every other lock, and callers that ask for the same segment at the same time wait for one decode.
final class VideoStoreCache {
    static let shared = VideoStoreCache()

    private let state = NSLock()
    private let decode = NSLock()
    private var key: String?
    private var store: VideoFrameStore?

    /// The store for `key`, built with `make` when it is not held yet. Nil when `make` fails or is cancelled.
    func store(for key: String, make: () -> VideoFrameStore?) -> VideoFrameStore? {
        if let hit = lookup(key) { return hit }
        decode.lock(); defer { decode.unlock() }
        if let hit = lookup(key) { return hit }
        guard let made = make() else { return nil }
        state.lock()
        self.key = key
        self.store = made
        state.unlock()
        return made
    }

    private func lookup(_ key: String) -> VideoFrameStore? {
        state.lock(); defer { state.unlock() }
        return self.key == key ? store : nil
    }

    /// Bytes of decoded frames held right now.
    var heldBytes: Int {
        state.lock(); defer { state.unlock() }
        return store?.byteCost ?? 0
    }

    /// Lets go of the held frames (memory warnings, closing a project).
    func clear() {
        state.lock()
        key = nil
        store = nil
        state.unlock()
    }
}
