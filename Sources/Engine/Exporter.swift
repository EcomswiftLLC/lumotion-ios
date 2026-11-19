import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreVideo

/// Writes finished files. Each call renders every frame at full size, one at a time, so memory stays flat. Calls are
/// async, report progress, and stop quickly on `cancel()` or when the calling task is cancelled. Files are created in a
/// temporary folder; move or share them from there. If the project has an audio track it is mixed into MP4 files.
/// The exporter renders with its own `RenderEngine`, so it never competes with the live preview for cached pictures.
final class Exporter {
    private let project: Project
    private let assets: SourceAssets
    private let lock = NSLock()
    private var currentToken = RenderToken()

    init(project: Project, assets: SourceAssets) {
        self.project = project
        self.assets = assets
    }

    /// Stops a running export.
    func cancel() {
        lock.lock(); let t = currentToken; lock.unlock()
        t.cancel()
    }

    private func beginToken() -> RenderToken {
        lock.lock(); defer { lock.unlock() }
        currentToken = RenderToken()
        return currentToken
    }

    private func runBlocking<T>(_ work: @escaping (RenderToken) throws -> T) async throws -> T {
        let token = beginToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try work(token)) } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    // MARK: Folder

    /// Folder that holds finished exports.
    static var exportsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumotionExports", isDirectory: true)
    }

    /// Deletes finished exports (and the leftovers of failed ones) from the exports folder. Files in `keeping` are never
    /// touched, and neither is anything newer than `age` seconds (default one day), so a file that was just shared stays
    /// available. Call it at launch, and after each new export with that export's file in `keeping`.
    /// Pass `olderThan: 0` to clear everything except `keeping`.
    static func clearOldExports(keeping: [URL] = [], olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: exportsFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let kept = Set(keeping.map { $0.standardizedFileURL.path })
        for file in files {
            if kept.contains(file.standardizedFileURL.path) { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) >= age { try? fm.removeItem(at: file) }
        }
    }

    private func outputURL(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: Exporter.exportsFolder, withIntermediateDirectories: true)
        let cleaned = project.title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        var base = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        if base.isEmpty { base = "Lumotion" }
        return Exporter.exportsFolder.appendingPathComponent("\(base.prefix(40))-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    // MARK: Estimates

    private static func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodec) -> Int {
        let factor = codec == .hevc ? 0.06 : 0.09
        return max(1_000_000, Int(Double(width * height * fps) * factor))
    }

    /// Size estimate for an MP4 before it is rendered.
    func estimateMP4(codec: VideoCodec, size: ExportResolution) -> ExportEstimate {
        let canvas = RenderEngine.canvasSize(for: project, longEdge: size.longEdge)
        let frames = project.loop.frameCount
        let seconds = Double(frames) / Double(project.loop.fps)
        let video = Double(Exporter.bitrate(width: canvas.width, height: canvas.height, fps: project.loop.fps, codec: codec)) / 8 * seconds
        let audio = (project.audio != nil && assets.audioURL != nil && project.audio?.muted == false) ? 128_000.0 / 8 * seconds : 0
        return ExportEstimate(bytes: Int64(video + audio), frameCount: frames, width: canvas.width, height: canvas.height, note: nil)
    }

    /// Most bytes of indexed GIF pixels held at once (ImageIO keeps every frame until the file is finished).
    private static let gifPixelBudget = 48 * 1024 * 1024

    private struct GIFPlan {
        var width: Int
        var height: Int
        /// One entry per frame: how long it is shown, in centiseconds (the only unit the GIF format knows).
        var delays: [Int]
        var note: String?
        var capped: Bool
        var frames: Int { delays.count }
    }

    /// Frame delays for a loop of `duration` seconds at about `fps` frames per second. A GIF stores delays in whole
    /// centiseconds, so most frame rates cannot be exact (30 fps is 3.33). Instead of rounding every frame and drifting,
    /// the delays here add up to exactly the loop length in centiseconds: when a whole number of centiseconds per frame
    /// gives a frame count within 12 percent of what was asked for (for example 3 centiseconds and 140 frames for 4.2
    /// seconds at 30 fps) that is used, otherwise the delays differ by at most one centisecond (3, 3, 4, 3, 3, 4 ...).
    /// No delay is below 2 centiseconds, the shortest browsers honour. `frameCap` limits the frame count; `capped`
    /// tells whether a limit lowered the frame rate.
    static func gifTiming(duration: Double, fps: Int, frameCap: Int) -> (delays: [Int], capped: Bool) {
        let total = max(2, Int((duration * 100).rounded()))
        let desired = max(1, Int((duration * Double(max(1, fps))).rounded()))
        let limit = max(1, min(frameCap, total / 2))
        var frames = desired
        var capped = false
        if desired > limit {
            frames = limit
            capped = true
        } else {
            let base = 100 / max(1, fps)
            var best: Int?
            for cs in [base, base + 1] where cs >= 2 && total % cs == 0 {
                let n = total / cs
                guard n <= limit, abs(Double(n) / Double(desired) - 1) <= 0.12 else { continue }
                if let current = best, abs(current - desired) <= abs(n - desired) { continue }
                best = n
            }
            if let n = best { frames = n }
        }
        var delays = [Int]()
        delays.reserveCapacity(frames)
        var used = 0
        for i in 0..<frames {
            let next = (i + 1) * total / frames
            delays.append(next - used)
            used = next
        }
        return (delays, capped)
    }

    private func gifPlan(_ options: GIFOptions) -> GIFPlan {
        let o = options.clamped
        let ratio = project.canvas.aspect.ratio(sourceAspect: project.source.aspect)
        let longEdge = ratio >= 1 ? o.width : Int((Double(o.width) / ratio).rounded())
        let size = RenderEngine.canvasSize(for: project, longEdge: longEdge)
        let cap = max(1, Exporter.gifPixelBudget / max(1, size.width * size.height))
        let timing = Exporter.gifTiming(duration: project.loop.clampedDuration, fps: o.fps, frameCap: cap)
        let note = timing.capped ? "To stay within memory, the GIF uses fewer frames per second at this size." : nil
        return GIFPlan(width: size.width, height: size.height, delays: timing.delays, note: note, capped: timing.capped)
    }

    /// Size estimate for a GIF before it is rendered. `isCapped` and `note` say when the frame rate had to be lowered.
    func estimateGIF(options: GIFOptions) -> ExportEstimate {
        let plan = gifPlan(options)
        let perPixel = 0.45 + 0.2 * Double(options.clamped.paletteColors) / 256
        let bytes = Double(plan.width * plan.height * plan.frames) * perPixel
        return ExportEstimate(bytes: Int64(bytes), frameCount: plan.frames, width: plan.width, height: plan.height, note: plan.note, isCapped: plan.capped)
    }

    /// The longest canvas edge an export can fill with real detail (4096 for photos, less for some cinemagraphs).
    var maxUsefulExportLongEdge: Int {
        RenderEngine.maxUsefulExportLongEdge(project: project, assets: assets)
    }

    /// Resolutions the device can encode with the codec. Larger sizes need more memory because every frame is rendered at that size.
    static func supportedResolutions(codec: VideoCodec) -> [ExportResolution] {
        let memory = ProcessInfo.processInfo.physicalMemory
        var list: [ExportResolution] = [.p720, .p1080]
        if memory >= 3_500_000_000 { list.append(.k2) }
        if memory >= 5_500_000_000 { list.append(.k4) }
        if codec == .hevc && !AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) {
            return []
        }
        return list
    }

    /// The sizes to offer for this project: `supportedResolutions` without the ones above what the project's pictures
    /// can fill (a cinemagraph's moving part is decoded at a fixed size, so 4K would only be a bigger, softer picture).
    /// 720p is always included when the codec works at all.
    func availableResolutions(codec: VideoCodec) -> [ExportResolution] {
        let useful = maxUsefulExportLongEdge
        let all = Exporter.supportedResolutions(codec: codec)
        let fitting = all.filter { $0.longEdge <= useful }
        return fitting.isEmpty ? Array(all.prefix(1)) : fitting
    }

    // MARK: MP4

    /// Seamless-loop MP4 (H.264 or HEVC). Frame count is `loop.frameCount`; the frame after the last equals the first, so it loops.
    func exportMP4(codec: VideoCodec, size: ExportResolution, progress: ExportProgress? = nil) async throws -> URL {
        let project = self.project, assets = self.assets
        let url = try outputURL(ext: "mp4")
        return try await runBlocking { token in
            do {
                try Exporter.writeMP4(project: project, assets: assets, codec: codec, longEdge: size.longEdge, to: url, token: token, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }
    }

    private static func writeMP4(project: Project, assets: SourceAssets, codec: VideoCodec, longEdge: Int, to url: URL, token: RenderToken, progress: ExportProgress?) throws {
        let engine = RenderEngine(project: project, assets: assets)
        let quality = RenderQuality(longEdge: longEdge)
        let canvas = RenderEngine.canvasSize(for: project, longEdge: quality.longEdge)
        let w = canvas.width, h = canvas.height
        let fps = project.loop.fps
        let frames = project.loop.frameCount
        let seconds = Double(frames) / Double(fps)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate(width: w, height: h, fps: fps, codec: codec),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw EngineError.unsupported("This device cannot encode \(codec.title) video at \(w) x \(h). Try a smaller size or H.264.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw EngineError.failed("The video file could not be created.") }
        writer.add(input)

        var audio: AudioFeeder?
        if let spec = project.audio, !spec.muted, let audioURL = assets.audioURL {
            audio = try AudioFeeder(spec: spec, url: audioURL, duration: seconds)
            if let feeder = audio {
                guard writer.canAdd(feeder.input) else { throw EngineError.failed("The audio could not be added to the video.") }
                writer.add(feeder.input)
            }
        }

        guard writer.startWriting() else {
            throw EngineError.failed("The video file could not be created: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: .zero)
        do {
        if let feeder = audio, !feeder.start() {
            throw EngineError.failed("The audio file could not be read. Mute the audio or choose another file.")
        }

        for i in 0..<frames {
            if token.isCancelled { throw EngineError.cancelled }
            let time = Double(i) / Double(fps)
            guard let frame = engine.renderBuffer(time: time, quality: quality, token: token) else {
                if token.isCancelled { throw EngineError.cancelled }
                throw EngineError.failed("A frame could not be rendered. Check that the photo or video is still available.")
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw EngineError.failed("The video could not be written: \(writer.error?.localizedDescription ?? "unknown error").") }
                if token.isCancelled { throw EngineError.cancelled }
                audio?.pump(untilSeconds: time + 1)
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw EngineError.failed("The video encoder is not ready.") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pb = pixelBuffer else { throw EngineError.failed("Not enough memory to export at this size. Try a smaller size.") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let stride = CVPixelBufferGetBytesPerRow(pb)
                let target = base.assumingMemoryBound(to: UInt8.self)
                if stride == w * 4 {
                    memcpy(target, frame.data, w * h * 4)
                } else {
                    for y in 0..<h { memcpy(target + y * stride, frame.data + y * w * 4, w * 4) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = CMTime(value: Int64(i), timescale: Int32(fps))
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw EngineError.failed("The video could not be written: \(writer.error?.localizedDescription ?? "unknown error").")
            }
            audio?.pump(untilSeconds: time + 1)
            progress?(Double(i + 1) / Double(frames) * 0.97)
        }
        input.markAsFinished()
        if let feeder = audio {
            while !feeder.finished {
                if token.isCancelled { throw EngineError.cancelled }
                if writer.status == .failed { break }
                feeder.pump(untilSeconds: .infinity)
                if !feeder.finished { Thread.sleep(forTimeInterval: 0.002) }
            }
        }
        } catch {
            // Whatever went wrong (cancelled, a frame that would not render, a full disk), the writer is stopped before it
            // is released: an AVAssetWriter that is deallocated while it is still writing crashes the app. cancelWriting
            // also removes the partly written file.
            audio?.cancel()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw EngineError.failed("The video could not be finished: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        progress?(1)
    }

    // MARK: GIF

    /// Looping GIF (loop count 0 means forever). The palette is one fixed colour cube for every frame, so colours do not flicker.
    func exportGIF(options: GIFOptions, progress: ExportProgress? = nil) async throws -> URL {
        let project = self.project, assets = self.assets
        let plan = gifPlan(options)
        let opts = options.clamped
        let url = try outputURL(ext: "gif")
        return try await runBlocking { token in
            do {
                try Exporter.writeGIF(project: project, assets: assets, width: plan.width, height: plan.height, delays: plan.delays,
                                      options: opts, to: url, token: token, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }
    }

    /// Convenience for width and frame rate only.
    func exportGIF(width: Int, fps: Int, progress: ExportProgress? = nil) async throws -> URL {
        try await exportGIF(options: GIFOptions(width: width, fps: fps), progress: progress)
    }

    private static func writeGIF(project: Project, assets: SourceAssets, width: Int, height: Int, delays: [Int],
                                 options: GIFOptions, to url: URL, token: RenderToken, progress: ExportProgress?) throws {
        let frames = delays.count
        let totalCentiseconds = max(1, delays.reduce(0, +))
        let engine = RenderEngine(project: project, assets: assets)
        let ratio = project.canvas.aspect.ratio(sourceAspect: project.source.aspect)
        let quality = RenderQuality(longEdge: ratio >= 1 ? width : height)
        let palette = GIFPalette(colors: options.paletteColors)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil) else {
            throw EngineError.failed("The GIF file could not be created.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let duration = project.loop.clampedDuration
        var elapsed = 0
        for i in 0..<frames {
            if token.isCancelled { throw EngineError.cancelled }
            // Frames are sampled where the viewer will see them: at the running total of the delays before them.
            let time = duration * Double(elapsed) / Double(totalCentiseconds)
            let delay = Double(delays[i]) / 100
            elapsed += delays[i]
            guard let frame = engine.renderBuffer(time: time, quality: quality, token: token) else {
                if token.isCancelled { throw EngineError.cancelled }
                throw EngineError.failed("A frame could not be rendered. Check that the photo or video is still available.")
            }
            let candidate = palette.indexedImage(frame, dither: options.dither) ?? frame.makeCGImage()
            guard let image = candidate else { throw EngineError.failed("A frame could not be converted for the GIF.") }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
            progress?(Double(i + 1) / Double(frames) * 0.95)
        }
        if token.isCancelled { throw EngineError.cancelled }
        guard CGImageDestinationFinalize(destination) else { throw EngineError.failed("The GIF file could not be written. Check that there is free storage.") }
        progress?(1)
    }

    // MARK: Still

    /// One frame as an image file. `longEdge` nil uses the larger side of the source (at most 4096).
    func exportStill(format: StillFormat, time: Double = 0, longEdge: Int? = nil) async throws -> URL {
        let project = self.project, assets = self.assets
        let url = try outputURL(ext: format.fileExtension)
        return try await runBlocking { token in
            let engine = RenderEngine(project: project, assets: assets)
            let edge = longEdge ?? max(project.source.pixelWidth, project.source.pixelHeight)
            guard let image = engine.renderFrame(time: time, quality: RenderQuality(longEdge: edge), token: token) else {
                if token.isCancelled { throw EngineError.cancelled }
                throw EngineError.failed("The picture could not be rendered. Check that the photo or video is still available.")
            }
            let type: String
            switch format {
            case .jpg: type = "public.jpeg"
            case .png: type = "public.png"
            case .heic: type = "public.heic"
            }
            guard let data = ProjectStore.encode(image, type: type, quality: 0.95) else {
                throw EngineError.unsupported(format == .heic ? "This device cannot save HEIC pictures. Choose JPG or PNG." : "The picture could not be saved.")
            }
            try data.write(to: url, options: .atomic)
            return url
        }
    }
}

// MARK: - GIF palette

/// A fixed colour cube used for every GIF frame.
struct GIFPalette {
    let rl: Int
    let gl: Int
    let bl: Int
    /// RGB triplets, `count * 3` bytes.
    let table: [UInt8]

    var count: Int { rl * gl * bl }

    init(colors: Int) {
        var r = 2, g = 2, b = 2
        let limit = min(max(colors, 8), 256)
        var changed = true
        while changed {
            changed = false
            if r * (g + 1) * b <= limit { g += 1; changed = true }
            if (r + 1) * g * b <= limit { r += 1; changed = true }
            if r * g * (b + 1) <= limit { b += 1; changed = true }
        }
        rl = r; gl = g; bl = b
        var t = [UInt8]()
        t.reserveCapacity(r * g * b * 3)
        for ri in 0..<r {
            for gi in 0..<g {
                for bi in 0..<b {
                    t.append(UInt8(ri * 255 / (r - 1)))
                    t.append(UInt8(gi * 255 / (g - 1)))
                    t.append(UInt8(bi * 255 / (b - 1)))
                }
            }
        }
        table = t
    }

    private static let bayer: [Float] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ]

    /// An 8-bit indexed CGImage of the frame, or nil when the indexed colour space cannot be created.
    func indexedImage(_ buffer: PixelBuffer, dither: Bool) -> CGImage? {
        let w = buffer.width, h = buffer.height
        var indices = [UInt8](repeating: 0, count: w * h)
        let src = buffer.data
        let rs = Float(rl - 1) / 255, gs = Float(gl - 1) / 255, bs = Float(bl - 1) / 255
        let rmax = rl - 1, gmax = gl - 1, bmax = bl - 1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var t: Float = 0
                if dither { t = (GIFPalette.bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16 - 0.5 }
                let ri = min(rmax, max(0, Int((Float(src[i + 2]) * rs + 0.5 + t).rounded(.down))))
                let gi = min(gmax, max(0, Int((Float(src[i + 1]) * gs + 0.5 + t).rounded(.down))))
                let bi = min(bmax, max(0, Int((Float(src[i]) * bs + 0.5 + t).rounded(.down))))
                indices[y * w + x] = UInt8(ri * gl * bl + gi * bl + bi)
            }
        }
        guard let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
        let space: CGColorSpace? = table.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: count - 1, colorTable: base)
        }
        guard let indexedSpace = space else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: indexedSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Audio

/// Reads the person's audio (trimmed, repeated to fill the video, with volume and fades) and feeds it to the writer.
final class AudioFeeder {
    let input: AVAssetWriterInput
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private(set) var finished = false

    init(spec: AudioTrackSpec, url: URL, duration: Double) throws {
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
            throw EngineError.failed("The audio file has no sound that can be used.")
        }
        let total = CMTimeGetSeconds(asset.duration)
        let available = total.isFinite && total > 0 ? total : duration
        let start = min(max(spec.trimStart, 0), max(0, available - 0.05))
        let end = min(max(spec.trimEnd ?? available, start + 0.05), available)
        let segment = max(0.05, end - start)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EngineError.failed("The audio could not be prepared.")
        }
        var cursor = 0.0
        while cursor < duration - 0.001 {
            let take = min(segment, duration - cursor)
            try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: take, preferredTimescale: 600)),
                                      of: sourceTrack, at: CMTime(seconds: cursor, preferredTimescale: 600))
            cursor += take
            if !spec.loops { break }
        }
        let volume = Float(min(max(spec.volume, 0), 1))
        let params = AVMutableAudioMixInputParameters(track: track)
        let fadeIn = min(max(spec.fadeIn, 0), duration / 2)
        let fadeOut = min(max(spec.fadeOut, 0), duration / 2)
        if fadeIn > 0 {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                 timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        } else {
            params.setVolume(volume, at: .zero)
        }
        if fadeOut > 0 {
            let playing = min(cursor, duration)
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: CMTime(seconds: max(0, playing - fadeOut), preferredTimescale: 600),
                                                        duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]

        reader = try AVAssetReader(asset: composition)
        output = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw EngineError.failed("The audio could not be prepared.") }
        reader.add(output)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
    }

    /// Starts reading. False when the audio cannot be decoded.
    func start() -> Bool { reader.startReading() }

    /// Stops reading (an export that failed or was cancelled).
    func cancel() { if reader.status == .reading { reader.cancelReading() } }

    /// Appends audio samples until the audio reaches `untilSeconds` or the writer is not ready for more.
    func pump(untilSeconds: Double) {
        while !finished && input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                finished = true
                return
            }
            input.append(sample)
            if CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) >= untilSeconds { return }
        }
    }
}
