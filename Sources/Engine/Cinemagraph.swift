import Foundation
import CoreGraphics
import AVFoundation

// MARK: - Canvas composition

/// Puts the source picture onto the canvas: crop and zoom for `fill`, whole picture with a background for `fit`.
enum CanvasCompose {
    /// Canvas rectangle (in pixels, y down) that the whole photo covers. Larger than the canvas when cropping.
    static func photoRect(mapping: CanvasMapping, width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        return CGRect(x: -mapping.bx / mapping.ax * w, y: -mapping.by / mapping.ay * h, width: w / mapping.ax, height: h / mapping.ay)
    }

    /// Renders a photo onto a canvas of `width` x `height` pixels.
    static func compose(image: CGImage, canvas: CanvasSpec, sourceAspect: Double, width: Int, height: Int) -> PixelBuffer? {
        let mapping = CanvasMapping(canvas: canvas, sourceAspect: sourceAspect)
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
        let fillMapping = CanvasMapping(canvas: fill, sourceAspect: sourceAspect)
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
    static func resample(_ raw: PixelBuffer, mapping: CanvasMapping, width: Int, height: Int) -> PixelBuffer {
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

/// The frames of one cinemagraph segment, held in memory at reduced size (a fixed byte budget decides the size) so they
/// can be read in any order while scrubbing and exporting. Reading the video happens once, with AVAssetImageGenerator.
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
        let t = min(max(seconds, 0), length) * fps
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

    /// Reads the segment `start ... start + length` (seconds). Returns nil when the file cannot be read or `token` is cancelled.
    static func extract(url: URL, start: Double, length: Double, maxLongEdge: Int, budgetBytes: Int, token: RenderToken?) -> VideoFrameStore? {
        guard let info = videoInfo(url) else { return nil }
        let asset = AVURLAsset(url: url)
        let total = max(0.1, info.duration.isFinite ? info.duration : start + length)
        let segStart = min(max(start, 0), max(0, total - 0.1))
        let segLength = max(0.1, min(length, total - segStart))
        let storeFPS = min(max(info.fps, 8), 24)
        let count = max(2, Int((segLength * storeFPS).rounded(.up)) + 1)

        // Size: as large as the byte budget allows, never above `maxLongEdge` or the video itself.
        let aspect = Double(info.size.width / info.size.height)
        let pixelsPerFrame = Double(budgetBytes) / Double(count) / 4
        var h = (pixelsPerFrame / aspect).squareRoot()
        var w = h * aspect
        let longest = max(w, h)
        let cap = Double(min(maxLongEdge, Int(max(info.size.width, info.size.height))))
        if longest > cap { let k = cap / longest; w *= k; h *= k }
        let fw = max(16, Int((w / 2).rounded()) * 2), fh = max(16, Int((h / 2).rounded()) * 2)

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
        var slots = [PixelBuffer?](repeating: nil, count: count)
        let lock = NSLock()
        let group = DispatchGroup()
        for _ in 0..<count { group.enter() }
        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
            defer { group.leave() }
            if token?.isCancelled == true { generator.cancelAllCGImageGeneration(); return }
            guard result == .succeeded, let image else { return }
            let index = min(count - 1, max(0, Int(((CMTimeGetSeconds(requested) - segStart) * storeFPS).rounded())))
            guard let buffer = PixelBuffer.scaled(image, width: fw, height: fh) else { return }
            lock.lock(); slots[index] = buffer; lock.unlock()
        }
        group.wait()
        if token?.isCancelled == true { return nil }
        // Fill any frame the decoder could not give us from its neighbour.
        guard let firstGood = slots.first(where: { $0 != nil }) ?? nil else { return nil }
        var frames = [PixelBuffer]()
        var last = firstGood
        for slot in slots {
            if let s = slot { last = s }
            frames.append(slot ?? last)
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
