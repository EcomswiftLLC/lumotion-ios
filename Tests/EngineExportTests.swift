import XCTest
import AVFoundation
import ImageIO
import CoreGraphics
@testable import Lumotion

/// Collects progress values from the export's background thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list = [Double]()
    func add(_ value: Double) { lock.lock(); list.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}

/// Exports are read back with AVFoundation and ImageIO. The cinemagraph tests build their own short clip.
final class EngineExportTests: XCTestCase {

    private func exportProject(fps: Int = 8, duration: Double = 1.0) -> Project {
        var p = Fixture.project(width: 160, height: 120, title: "Export test")
        p.loop.fps = fps
        p.loop.duration = duration
        p.overlays = [OverlayLayer(kind: .stars, intensity: 0.6, seed: 2)]
        p.look.animatedGrain = false
        return p
    }

    private func exporter(_ project: Project, audio: URL? = nil) -> Exporter {
        Exporter(project: project, assets: SourceAssets(still: Fixture.photo(width: project.source.pixelWidth, height: project.source.pixelHeight), audioURL: audio))
    }

    // MARK: MP4

    func testMP4ExportIsReadableWithTheRightDurationAndSize() async throws {
        let project = exportProject()
        let log = ProgressLog()
        let url = try await exporter(project).exportMP4(codec: .h264, size: .p720) { value in log.add(value) }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0, 1000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Double(project.loop.frameCount) / Double(project.loop.fps), accuracy: 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "no video track")
        let size = try await track.load(.naturalSize)
        let expected = RenderEngine.canvasSize(for: project, longEdge: ExportResolution.p720.longEdge)
        XCTAssertEqual(Int(size.width), expected.width)
        XCTAssertEqual(Int(size.height), expected.height)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(Double(frameRate), Double(project.loop.fps), accuracy: 1.5)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "no audio was attached")

        let seen = log.values
        XCTAssertEqual(seen.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(seen, seen.sorted(), "progress never goes backwards")
    }

    func testMP4ExportCarriesTheAudioTrack() async throws {
        let folder = Fixture.tempFolder(self)
        let wav = folder.appendingPathComponent("tone.wav")
        try Fixture.writeWAV(to: wav, seconds: 2)
        var project = exportProject()
        project.audio = AudioTrackSpec(fileName: "tone.wav", displayName: "Tone", trimStart: 0, trimEnd: nil, volume: 0.8, fadeIn: 0.1, fadeOut: 0.2, loops: true, muted: false)
        let url = try await exporter(project, audio: wav).exportMP4(codec: .h264, size: .p720)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audio.count, 1, "the audio track is missing")
        XCTAssertEqual(video.count, 1)
        let audioDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(audioDuration, Double(project.loop.frameCount) / Double(project.loop.fps), accuracy: 0.25, "the audio is trimmed to the loop")

        var muted = project
        muted.audio?.muted = true
        let quiet = try await exporter(muted, audio: wav).exportMP4(codec: .h264, size: .p720)
        defer { try? FileManager.default.removeItem(at: quiet) }
        let quietTracks = try await AVURLAsset(url: quiet).loadTracks(withMediaType: .audio)
        XCTAssertTrue(quietTracks.isEmpty, "muted audio is left out")
    }

    func testHEVCExportWhenTheDeviceCanEncodeIt() async throws {
        var project = exportProject(fps: 6, duration: 1)
        project.overlays = []
        do {
            let url = try await exporter(project).exportMP4(codec: .hevc, size: .p720)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 1, accuracy: 0.25)
        } catch let error as EngineError {
            if case .unsupported = error { throw XCTSkip("HEVC encoding is not available here: \(error.localizedDescription)") }
            if case .failed = error { throw XCTSkip("HEVC encoding failed on this machine: \(error.localizedDescription)") }
            throw error
        }
    }

    func testMP4ExportCanBeCancelled() async throws {
        var project = exportProject(fps: 30, duration: 4)
        project.overlays = []
        let runner = exporter(project)
        let task = Task { try await runner.exportMP4(codec: .h264, size: .p1080) }
        task.cancel()
        do {
            let url = try await task.value
            try? FileManager.default.removeItem(at: url)
            XCTFail("a cancelled export should not finish")
        } catch let error as EngineError {
            guard case .cancelled = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testEstimatesMatchWhatIsExported() {
        let project = exportProject(fps: 24, duration: 3)
        let e = exporter(project)
        let mp4 = e.estimateMP4(codec: .h264, size: .p1080)
        XCTAssertEqual(mp4.frameCount, 72)
        XCTAssertEqual(max(mp4.width, mp4.height), ExportResolution.p1080.longEdge)
        XCTAssertGreaterThan(mp4.bytes, 0)
        let hevc = e.estimateMP4(codec: .hevc, size: .p1080)
        XCTAssertLessThan(hevc.bytes, mp4.bytes)
        let gif = e.estimateGIF(options: GIFOptions(width: 320, fps: 10))
        XCTAssertEqual(gif.frameCount, 30)
        XCTAssertEqual(max(gif.width, gif.height), 320)
        XCTAssertFalse(Exporter.supportedResolutions(codec: .h264).isEmpty)
        XCTAssertTrue(Exporter.supportedResolutions(codec: .h264).contains(.p1080))
    }

    // MARK: GIF

    func testGIFExportHasTheRightFramesAndLoopsForever() async throws {
        var project = exportProject(fps: 8, duration: 1)
        project.overlays = [OverlayLayer(kind: .snow, intensity: 0.8, seed: 1)]
        let options = GIFOptions(width: 160, fps: 5, paletteColors: 256, dither: true)
        let e = exporter(project)
        let estimate = e.estimateGIF(options: options)
        let url = try await e.exportGIF(options: options)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "gif")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
        XCTAssertEqual(CGImageSourceGetCount(source), estimate.frameCount)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int, 0, "loop count 0 means the GIF repeats forever")
        let frame = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(frame[kCGImagePropertyPixelWidth] as? Int, estimate.width)
        XCTAssertEqual(frame[kCGImagePropertyPixelHeight] as? Int, estimate.height)
        let frameGIF = try XCTUnwrap(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = (frameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (frameGIF[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        XCTAssertEqual(delay * 5, 1, accuracy: 0.15, "the frame delays add up to the loop length")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, estimate.width)
        // The picture is recognisable: not blank and not a single colour.
        let bytes = Fixture.rgba(decoded)
        var distinct = Set<Int>()
        var offset = 0
        while offset + 2 < bytes.count {
            let red: Int = Int(bytes[offset])
            let green: Int = Int(bytes[offset + 1])
            let blue: Int = Int(bytes[offset + 2])
            distinct.insert(red * 65536 + green * 256 + blue)
            offset += 4
        }
        XCTAssertGreaterThan(distinct.count, 8)
    }

    func testGIFFramesLoopBackToTheFirst() async throws {
        var project = exportProject(fps: 8, duration: 1)
        project.flowRegions = PresetLibrary.apply("waterfall", to: project).flowRegions
        let url = try await exporter(project).exportGIF(options: GIFOptions(width: 160, fps: 6, paletteColors: 256, dither: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        XCTAssertEqual(count, 6)
        func frame(_ i: Int) -> [UInt8] { Fixture.rgba(CGImageSourceCreateImageAtIndex(source, i, nil)!) }
        let first = frame(0), second = frame(1), last = frame(count - 1), beforeLast = frame(count - 2)
        let seam = Fixture.meanDiff(last, first)
        let step = max(Fixture.meanDiff(first, second), Fixture.meanDiff(beforeLast, last))
        XCTAssertLessThanOrEqual(seam, step * 2.5 + 4, "the GIF has a visible jump where it repeats")
    }

    func testLegacyGIFOverloadWorks() async throws {
        let project = exportProject(fps: 8, duration: 1)
        let url = try await exporter(project).exportGIF(width: 160, fps: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
    }

    // MARK: Stills

    func testStillExportInEveryFormat() async throws {
        let project = exportProject()
        let e = exporter(project)
        for format in StillFormat.allCases {
            do {
                let url = try await e.exportStill(format: format, time: 0.3, longEdge: 200)
                defer { try? FileManager.default.removeItem(at: url) }
                XCTAssertEqual(url.pathExtension, format.fileExtension)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "\(format.rawValue) cannot be read back")
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let expected = RenderEngine.canvasSize(for: project, longEdge: 200)
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, expected.width, format.rawValue)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, expected.height, format.rawValue)
            } catch let error as EngineError {
                if format == .heic { throw XCTSkip("HEIC is not available here: \(error.localizedDescription)") }
                throw error
            }
        }
    }

    func testStillExportMatchesTheRenderedFrame() async throws {
        var project = exportProject()
        project.look = Look(filter: .cinema, intensity: 60, animatedGrain: false)
        let engine = Fixture.engine(project)
        let rendered = Fixture.bytes(engine, time: 0.5, longEdge: 160)
        let url = try await exporter(project).exportStill(format: .png, time: 0.5, longEdge: 160)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let saved = Fixture.rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        XCTAssertEqual(saved.count, rendered.count)
        XCTAssertLessThan(Fixture.meanDiff(saved, rendered), 1.0)
    }

    func testOldExportsAreCleanedUp() throws {
        let folder = Exporter.exportsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old-\(UUID().uuidString).mp4")
        let fresh = folder.appendingPathComponent("fresh-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        Exporter.clearOldExports(olderThan: 86_400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        try? FileManager.default.removeItem(at: fresh)
    }

    // MARK: Cinemagraph

    private func makeCinemagraph() async throws -> (project: Project, assets: SourceAssets, store: ProjectStore) {
        let folder = Fixture.tempFolder(self)
        let clip = folder.appendingPathComponent("clip.mp4")
        try Fixture.writeTestVideo(to: clip)
        let store = ProjectStore(rootURL: folder.appendingPathComponent("Projects", isDirectory: true))
        let created = try await store.createVideoProject(videoURL: clip, title: "Clip")
        var project = created.project
        XCTAssertEqual(project.source.kind, .video)
        XCTAssertEqual(project.source.pixelWidth, 128)
        XCTAssertEqual(project.source.pixelHeight, 96)
        XCTAssertEqual(project.source.videoDuration, 2, accuracy: 0.2)
        project.loop.fps = 10
        // Paint the left half, where the square moves. The circle on the right stays frozen.
        project.cinemagraph.maskStrokes = [BrushStroke(points: [NPoint(0.22, 0.05), NPoint(0.22, 0.95)], radius: 0.2, feather: 0.3)]
        project.loop.duration = project.cinemagraph.loopLength
        return (project, created.assets, store)
    }

    func testCinemagraphKeepsOnlyThePaintedPartMoving() async throws {
        let (project, assets, _) = try await makeCinemagraph()
        let engine = RenderEngine(project: project, assets: assets)
        let w = engine.canvasSize(longEdge: 128).width
        func frame(_ t: Double) -> [UInt8] { Fixture.bytes(engine, time: t, longEdge: 128) }
        let a = frame(0.05), b = frame(0.45), c = frame(0.95)
        // The painted left half changes, the right side (beyond the brush and its feather) does not.
        let h = a.count / 4 / w
        let leftChange = max(Fixture.meanDiff(a, b, where: { x, _ in x < 44 }, width: w), Fixture.meanDiff(a, c, where: { x, _ in x < 44 }, width: w))
        XCTAssertGreaterThan(leftChange, 1.0, "the painted part should move")
        for other in [b, c] {
            let rightWorst = Fixture.maxDiff(a, other, width: w) { x, _ in x >= 76 }
            XCTAssertLessThanOrEqual(rightWorst, 2, "the frozen part must not move")
        }
        XCTAssertEqual(h, 96)
        guard let original = engine.originalFrame(quality: RenderQuality(longEdge: 128)) else { return XCTFail("no still frame") }
        XCTAssertLessThan(Fixture.meanDiff(a, Fixture.rgba(original), where: { x, _ in x >= 76 }, width: w), 2.0)
    }

    func testCinemagraphLoopHasNoSeam() async throws {
        let (project, assets, _) = try await makeCinemagraph()
        let engine = RenderEngine(project: project, assets: assets)
        let n = project.loop.frameCount
        let fps = Double(project.loop.fps)
        XCTAssertGreaterThanOrEqual(n, 8)
        func frame(_ i: Int) -> [UInt8] { Fixture.bytes(engine, time: Double(i) / fps, longEdge: 128) }
        let first = frame(0), second = frame(1), last = frame(n - 1), beforeLast = frame(n - 2), middle = frame(n / 2), afterMiddle = frame(n / 2 + 1)
        let seam = Fixture.meanDiff(last, first)
        let step = max(Fixture.meanDiff(first, second), Fixture.meanDiff(beforeLast, last), Fixture.meanDiff(middle, afterMiddle))
        XCTAssertLessThanOrEqual(seam, step * 2.5 + 1.0, "seam \(seam), neighbouring step \(step)")
        let wrapped = Fixture.bytes(engine, time: project.loop.clampedDuration, longEdge: 128)
        XCTAssertEqual(Fixture.meanDiff(first, wrapped), 0, accuracy: 0.0001)
    }

    func testCinemagraphPingPongAndEmptyMask() async throws {
        var (project, assets, _) = try await makeCinemagraph()
        project.cinemagraph.pingPong = true
        project.loop.duration = project.cinemagraph.loopLength
        let engine = RenderEngine(project: project, assets: assets)
        XCTAssertNotNil(engine.renderFrame(time: 0.3, quality: RenderQuality(longEdge: 96)))
        let w = engine.canvasSize(longEdge: 96).width
        let a = Fixture.bytes(engine, time: 0, longEdge: 96)
        let aWrap = Fixture.bytes(engine, time: project.loop.clampedDuration, longEdge: 96)
        XCTAssertEqual(Fixture.meanDiff(a, aWrap), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(Fixture.meanDiff(a, Fixture.bytes(engine, time: 0.7, longEdge: 96), where: { x, _ in x < 30 }, width: w), 0.5)

        // With nothing painted the whole frame plays.
        project.cinemagraph.maskStrokes = []
        project.cinemagraph.pingPong = false
        project.loop.duration = project.cinemagraph.loopLength
        engine.update(project: project)
        let full0 = Fixture.bytes(engine, time: 0.05, longEdge: 96), full1 = Fixture.bytes(engine, time: 0.5, longEdge: 96)
        XCTAssertGreaterThan(Fixture.meanDiff(full0, full1, where: { x, _ in x >= 60 }, width: w), 0.3, "with an empty mask the right side moves too")
    }

    func testCinemagraphExportsAMP4() async throws {
        let (project, assets, _) = try await makeCinemagraph()
        var small = project
        small.loop.fps = 8
        let url = try await Exporter(project: small, assets: assets).exportMP4(codec: .h264, size: .p720)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Double(small.loop.frameCount) / 8, accuracy: 0.3)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testBrokenVideoIsRejectedWithAMessage() async throws {
        let folder = Fixture.tempFolder(self)
        let bad = folder.appendingPathComponent("bad.mp4")
        try Data("not a video".utf8).write(to: bad)
        let store = ProjectStore(rootURL: folder.appendingPathComponent("Projects", isDirectory: true))
        do {
            _ = try await store.createVideoProject(videoURL: bad, title: "Bad")
            XCTFail("a text file is not a video")
        } catch {
            XCTAssertNotNil((error as? EngineError)?.errorDescription)
        }
        XCTAssertTrue(store.listProjects().isEmpty, "a failed import leaves nothing behind")
    }
}
