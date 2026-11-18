import XCTest
import CoreGraphics
import AVFoundation
import CoreVideo
@testable import Lumotion

/// Shared helpers for the engine tests. Everything is tiny on purpose: the unit tests run in a Debug build (no compiler
/// optimisation), so a 100 pixel frame is the right size to prove the maths without making CI slow.
enum Fixture {
    static let fps = 12
    static let duration = 2.0

    /// A photo with stripes, rings and a little noise, so any warp shows up as changed pixels.
    static func photo(width: Int = 160, height: Int = 120) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                let stripes = 0.5 + 0.5 * sin(fx * 38 + fy * 11)
                let rings = 0.5 + 0.5 * sin(hypot(fx - 0.35, fy - 0.45) * 55)
                let noise = Double(((x &* 73856093) ^ (y &* 19349663)) & 0xFF) / 255.0
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, 30 + 170 * stripes * (0.6 + 0.4 * fy) + 10 * noise))
                bytes[i + 1] = UInt8(min(255, 40 + 150 * rings * (0.5 + 0.5 * fx) + 10 * noise))
                bytes[i + 2] = UInt8(min(255, 60 + 120 * (1 - stripes) * rings + 90 * fy * (1 - fx)))
                bytes[i + 3] = 255
            }
        }
        return image(fromRGBA: bytes, width: width, height: height)
    }

    static func image(fromRGBA bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A still project for the test photo, with the loop short enough for quick tests and no grain or flicker, so a loop
    /// can be checked for a seam.
    static func project(width: Int = 160, height: Int = 120, title: String = "Test loop") -> Project {
        var p = Project.new(title: title, kind: .still, fileName: "source.jpg", pixelWidth: width, pixelHeight: height)
        p.loop.duration = duration
        p.loop.fps = fps
        p.look.animatedGrain = false
        return p
    }

    static func engine(_ project: Project, photo: CGImage? = nil, subject: MaskBuffer? = nil) -> RenderEngine {
        let image = photo ?? self.photo(width: project.source.pixelWidth, height: project.source.pixelHeight)
        return RenderEngine(project: project, assets: SourceAssets(still: image, subjectMask: subject))
    }

    /// RGBA bytes of an image, top row first.
    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Mean absolute difference over the colour channels, on a 0...255 scale.
    static func meanDiff(_ a: [UInt8], _ b: [UInt8], where include: ((Int, Int) -> Bool)? = nil, width: Int = 0) -> Double {
        precondition(a.count == b.count)
        var sum = 0.0, count = 0.0
        let pixels = a.count / 4
        for p in 0..<pixels {
            if let include, width > 0, !include(p % width, p / width) { continue }
            for c in 0..<3 { sum += Double(abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c]))) }
            count += 3
        }
        return count > 0 ? sum / count : 0
    }

    /// Largest absolute channel difference over the pixels that `include` accepts.
    static func maxDiff(_ a: [UInt8], _ b: [UInt8], width: Int, where include: (Int, Int) -> Bool = { _, _ in true }) -> Int {
        precondition(a.count == b.count)
        var worst = 0
        for p in 0..<(a.count / 4) {
            if !include(p % width, p / width) { continue }
            for c in 0..<3 { worst = max(worst, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c]))) }
        }
        return worst
    }

    static func render(_ engine: RenderEngine, time: Double, longEdge: Int = 96) -> CGImage {
        guard let image = engine.renderFrame(time: time, quality: RenderQuality(longEdge: longEdge)) else {
            XCTFail("The engine returned no frame at \(time) s")
            return photo(width: 16, height: 12)
        }
        return image
    }

    static func bytes(_ engine: RenderEngine, time: Double, longEdge: Int = 96) -> [UInt8] {
        rgba(render(engine, time: time, longEdge: longEdge))
    }

    /// A temporary folder that is removed when the test ends.
    static func tempFolder(_ test: XCTestCase) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Generated media

    /// A short mono WAV (a sine wave) for the audio tests.
    static func writeWAV(to url: URL, seconds: Double = 2, sampleRate: Int = 8000) throws {
        let count = Int(seconds * Double(sampleRate))
        var data = Data()
        func put32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!)
        put32(UInt32(36 + count * 2))
        data.append("WAVEfmt ".data(using: .ascii)!)
        put32(16); put16(1); put16(1); put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        data.append("data".data(using: .ascii)!)
        put32(UInt32(count * 2))
        for i in 0..<count {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            put16(UInt16(bitPattern: v))
        }
        try data.write(to: url)
    }

    /// A 128 x 96 clip. A square travels back and forth on the left, a circle on the right, and the background is still.
    static func writeTestVideo(to url: URL, frames: Int = 24, fps: Int = 12) throws {
        let w = 128, h = 96
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let t = Double(i) / Double(frames)
            let squareX = 12 + Int(26 * (0.5 + 0.5 * sin(2 * Double.pi * t)))
            let circleX = 84 + Int(24 * (0.5 + 0.5 * sin(2 * Double.pi * t)))
            for y in 0..<h {
                for x in 0..<w {
                    var b: UInt8 = UInt8(60 + 120 * x / w), g: UInt8 = UInt8(50 + 100 * y / h), r: UInt8 = 90
                    if x >= squareX && x < squareX + 20 && y >= 34 && y < 54 { b = 30; g = 40; r = 240 }
                    let dx = x - circleX, dy = y - 48
                    if dx * dx + dy * dy < 100 { b = 240; g = 230; r = 60 }
                    let o = y * stride + x * 4
                    base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, "The test video could not be written: \(String(describing: writer.error))")
    }
}

extension XCTestCase {
    /// Checks that a loop has no visible seam. The step from the last frame back to the first must be no bigger than the
    /// biggest step between neighbouring frames elsewhere in the loop, and the loop must actually move.
    func assertSeamless(_ project: Project, label: String, photo: CGImage? = nil, subject: MaskBuffer? = nil, longEdge: Int = 96,
                        expectMotion: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let engine = Fixture.engine(project, photo: photo, subject: subject)
        let n = project.loop.frameCount
        let fps = Double(project.loop.fps)
        func frame(_ i: Int) -> [UInt8] { Fixture.bytes(engine, time: Double(i) / fps, longEdge: longEdge) }
        let first = frame(0)

        // Time wraps: a frame one whole loop later is the same frame.
        let wrapped = Fixture.bytes(engine, time: project.loop.clampedDuration, longEdge: longEdge)
        XCTAssertEqual(Fixture.meanDiff(first, wrapped), 0, accuracy: 0.0001, "\(label): the frame at the end of the loop differs from frame 0", file: file, line: line)

        let quarter = frame(max(1, n / 4)), half = frame(max(2, n / 2))
        let last = frame(n - 1), beforeLast = frame(n - 2), second = frame(1)
        let seam = Fixture.meanDiff(last, first)
        let steps = [Fixture.meanDiff(first, second), Fixture.meanDiff(beforeLast, last), Fixture.meanDiff(quarter, frame(max(1, n / 4) + 1)),
                     Fixture.meanDiff(half, frame(max(2, n / 2) + 1))]
        let biggest = steps.max() ?? 0
        XCTAssertLessThanOrEqual(seam, biggest * 2.5 + 1.0, "\(label): seam \(seam) against neighbouring steps \(steps)", file: file, line: line)
        if expectMotion {
            let travelled = max(Fixture.meanDiff(first, quarter), Fixture.meanDiff(first, half))
            XCTAssertGreaterThan(travelled, 0.01, "\(label): the loop does not move", file: file, line: line)
        }
    }
}
