import XCTest
import AVFoundation
import ImageIO
import CoreGraphics
import UIKit
@testable import Lumotion

/// Forward-compatible project files, memory budgets, the shared cinemagraph frame store, export housekeeping, GIF timing,
/// stabilisation and the defensive checks added after the engine audit.
final class EngineAuditTests: XCTestCase {

    // MARK: - Lenient project decoding

    private func richProject() -> Project {
        var p = Project(title: "Rich", source: SourceSpec(kind: .still, fileName: "source.jpg", pixelWidth: 800, pixelHeight: 600),
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        p.flowRegions = [FlowRegion(name: "Water", strokes: [BrushStroke(points: [NPoint(0.1, 0.2), NPoint(0.7, 0.8)])],
                                    arrows: [FlowArrow(from: NPoint(0.2, 0.2), to: NPoint(0.6, 0.7))], speed: 1.3, strength: 0.65, softness: 0.4)]
        p.livingEffects = [LivingEffect(kind: .ripple, strength: 0.8, speed: 2), LivingEffect(kind: .swirl, strength: 0.3)]
        p.overlays = [OverlayLayer(kind: .snow, intensity: 0.9, direction: 70), OverlayLayer(kind: .rain, intensity: 0.4)]
        p.look = Look(filter: .gilt, intensity: 66, adjust: LookAdjust(exposure: 0.2, contrast: 0.1), animatedGrain: false, flicker: Flicker(amount: 0.3, speed: 1.5))
        var text = TextLayer(text: "Hello")
        text.entrance = LayerAnimation(kind: .typewriter, duration: 1.2)
        p.texts = [text]
        p.stickers = [StickerLayer(emoji: "A")]
        p.audio = AudioTrackSpec(fileName: "audio.m4a", displayName: "Song", trimStart: 1, trimEnd: 4, volume: 0.6, fadeIn: 0.2, fadeOut: 0.8, loops: false, muted: false)
        p.cinemagraph.stabilize = true
        p.camera = CameraMotion(kind: .zoomIn, amount: 0.7)
        p.parallax = ParallaxSettings(enabled: true, depthSource: .gradient, style: .swing, strength: 0.7, edgeFill: .mirror, invertDepth: true)
        return p
    }

    private func jsonObject(_ project: Project) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> Project {
        try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testNestedTypesWithMissingKeysTakeTheirDefaults() throws {
        var object = try jsonObject(richProject())
        // Remove most keys inside the nested objects, as a file from an older build would lack them.
        func strip(_ path: [String], keep: Set<String>) {
            func walk(_ value: Any, _ path: ArraySlice<String>) -> Any {
                if var dict = value as? [String: Any] {
                    if let head = path.first {
                        if let inner = dict[head] { dict[head] = walk(inner, path.dropFirst()) }
                    } else {
                        for key in Array(dict.keys) where !keep.contains(key) { dict.removeValue(forKey: key) }
                    }
                    return dict
                }
                if let array = value as? [Any] { return array.map { walk($0, path) } }
                return value
            }
            if let top = path.first, let inner = object[top] { object[top] = walk(inner, path.dropFirst()) }
        }
        strip(["look"], keep: ["filter"])
        strip(["look", "adjust"], keep: [])
        strip(["flowRegions"], keep: ["strokes", "arrows"])
        strip(["livingEffects"], keep: ["kind"])
        strip(["overlays"], keep: ["kind"])
        strip(["texts"], keep: ["text"])
        strip(["stickers"], keep: ["emoji"])
        strip(["audio"], keep: ["fileName"])
        strip(["camera"], keep: ["kind"])
        strip(["parallax"], keep: ["enabled"])
        strip(["cinemagraph"], keep: [])
        strip(["canvas"], keep: [])
        strip(["loop"], keep: [])

        let decoded = try decode(object)
        XCTAssertEqual(decoded.look.filter, .gilt)
        XCTAssertEqual(decoded.look.intensity, 100)
        XCTAssertEqual(decoded.look.adjust, LookAdjust())
        XCTAssertEqual(decoded.flowRegions.count, 1)
        XCTAssertEqual(decoded.flowRegions[0].strokes.count, 1)
        XCTAssertEqual(decoded.flowRegions[0].speed, 1)
        XCTAssertEqual(decoded.livingEffects.map(\.kind), [.ripple, .swirl])
        XCTAssertEqual(decoded.livingEffects[0].strength, 0.5)
        XCTAssertEqual(decoded.overlays.count, 2)
        XCTAssertEqual(decoded.overlays[0].direction, OverlayLayer.naturalDirection(.snow), "a missing direction falls back to the natural one")
        XCTAssertEqual(decoded.texts.first?.text, "Hello")
        XCTAssertEqual(decoded.texts.first?.entrance, LayerAnimation(kind: .fade, duration: 0.6))
        XCTAssertEqual(decoded.stickers.first?.emoji, "A")
        XCTAssertEqual(decoded.audio?.fileName, "audio.m4a")
        XCTAssertEqual(decoded.audio?.displayName, "audio.m4a")
        XCTAssertEqual(decoded.audio?.volume, 1)
        XCTAssertEqual(decoded.camera.kind, .zoomIn)
        XCTAssertEqual(decoded.camera.amount, 0.5)
        XCTAssertTrue(decoded.parallax.enabled)
        XCTAssertEqual(decoded.parallax.edgeFill, .blur)
        XCTAssertEqual(decoded.cinemagraph, CinemagraphSettings())
        XCTAssertEqual(decoded.canvas, CanvasSpec())
        XCTAssertEqual(decoded.loop, LoopSpec())
    }

    func testUnknownValuesAndExtraKeysFromANewerBuildAreIgnored() throws {
        var object = try jsonObject(richProject())
        object["somethingNew"] = ["a": 1]
        var effects = try XCTUnwrap(object["livingEffects"] as? [[String: Any]])
        effects.append(["kind": "hologramFromTheFuture", "strength": 0.9])
        effects[0]["extraKey"] = true
        object["livingEffects"] = effects
        var overlays = try XCTUnwrap(object["overlays"] as? [[String: Any]])
        overlays[0]["kind"] = "meteorShowerDeluxe"
        object["overlays"] = overlays
        var look = try XCTUnwrap(object["look"] as? [String: Any])
        look["filter"] = "futureFilter"
        object["look"] = look
        var camera = try XCTUnwrap(object["camera"] as? [String: Any])
        camera["easing"] = 42
        object["camera"] = camera

        let decoded = try decode(object)
        XCTAssertEqual(decoded.livingEffects.map(\.kind), [.ripple, .swirl], "the unknown effect is dropped, the others stay")
        XCTAssertEqual(decoded.overlays.map(\.kind), [.rain], "the unknown overlay is dropped")
        XCTAssertEqual(decoded.look.filter, .original, "an unknown filter falls back to the default")
        XCTAssertEqual(decoded.look.intensity, 66, "the rest of the look is kept")
        XCTAssertEqual(decoded.camera.easing, .easeInOut)
        XCTAssertEqual(decoded.camera.kind, .zoomIn)
        XCTAssertEqual(decoded.title, "Rich")
    }

    func testLoopSpecIsValidatedWhenDecoded() throws {
        func decodeLoop(_ json: String) throws -> LoopSpec {
            try JSONDecoder().decode(LoopSpec.self, from: Data(json.utf8))
        }
        let odd = try decodeLoop(#"{"duration": 100, "fps": 25, "speed": -3}"#)
        XCTAssertEqual(odd.fps, 30)
        XCTAssertEqual(odd.duration, 15)
        XCTAssertEqual(odd.speed, 1)
        let short = try decodeLoop(#"{"duration": 0.1, "fps": 60, "speed": 40}"#)
        XCTAssertEqual(short.duration, 1)
        XCTAssertEqual(short.fps, 60)
        XCTAssertEqual(short.speed, 4)
        let empty = try decodeLoop("{}")
        XCTAssertEqual(empty, LoopSpec())
        for fps in LoopSpec.allowedFPS { XCTAssertEqual(try decodeLoop(#"{"fps": \#(fps)}"#).fps, fps) }
        // And through a whole project.
        var object = try jsonObject(richProject())
        object["loop"] = ["duration": 999, "fps": 7, "speed": 0, "mode": "pingPong"]
        let project = try decode(object)
        XCTAssertEqual(project.loop.duration, 15)
        XCTAssertEqual(project.loop.fps, 30)
        XCTAssertEqual(project.loop.speed, 1)
        XCTAssertEqual(project.loop.mode, .pingPong)
    }

    func testRichProjectStillRoundTrips() throws {
        let original = richProject()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(original)), original)
    }

    // MARK: - Defensive numbers

    func testStrokeRasterSurvivesBrokenNumbers() {
        let nan = Double.nan, inf = Double.infinity
        let strokes = [
            BrushStroke(points: [NPoint(nan, 0.5), NPoint(0.5, nan)], radius: 0.05),
            BrushStroke(points: [NPoint(1e300, -1e300), NPoint(0.5, 0.5)], radius: inf, feather: nan),
            BrushStroke(points: [NPoint(0.3, 0.3), NPoint(0.4, 0.4)], radius: nan, feather: inf),
            BrushStroke(points: [NPoint(0.5, 0.5)], radius: 0.1),
        ]
        let mask = StrokeRaster.paintMask(strokes, width: 64, height: 48)
        XCTAssertNotNil(mask, "the readable strokes still paint")
        XCTAssertEqual(mask?.width, 64)
        let depth = StrokeRaster.paintDepth(strokes, base: MaskBuffer(width: 32, height: 32, value: 10))
        XCTAssertEqual(depth.data.count, 32 * 32)
    }

    func testMaskSampleIgnoresNonFiniteCoordinates() {
        let mask = MaskBuffer(width: 8, height: 8, value: 200)
        XCTAssertEqual(mask.sample(u: .nan, v: 0.5), 0)
        XCTAssertEqual(mask.sample(u: 0.5, v: .infinity), 0)
        XCTAssertEqual(mask.sample(u: 1e300, v: -1e300), 200.0 / 255, accuracy: 0.01)
    }

    // MARK: - ProjectStore

    private func makeStore() -> ProjectStore {
        ProjectStore(rootURL: Fixture.tempFolder(self).appendingPathComponent("Projects", isDirectory: true))
    }

    func testListingReadsOnlyTheSmallMetaFile() throws {
        let store = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Meta")
        let id = created.project.id
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL("meta.json", in: id).path))
        // Damage both project files: the listing still works, because it never opens them.
        try Data("not json".utf8).write(to: store.fileURL("project.json", in: id))
        try? FileManager.default.removeItem(at: store.fileURL("project.json.bak", in: id))
        let rows = store.listProjects()
        XCTAssertEqual(rows.map(\.id), [id])
        XCTAssertEqual(rows.first?.title, "Meta")
        XCTAssertEqual(rows.first?.kind, .still)
    }

    func testProjectsWithoutAMetaFileAreStillListedAndGetOne() throws {
        let store = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Old")
        let id = created.project.id
        try FileManager.default.removeItem(at: store.fileURL("meta.json", in: id))
        XCTAssertEqual(store.listProjects().first?.title, "Old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL("meta.json", in: id).path))
    }

    func testRenameIsVisibleInTheListing() throws {
        let store = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Before")
        try store.rename(id: created.project.id, title: "After")
        XCTAssertEqual(store.listProjects().first?.title, "After")
    }

    func testOrphanFoldersAreCleanedUp() throws {
        let store = makeStore()
        let keep = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Keep")
        let orphan = store.folderURL(for: UUID())
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appendingPathComponent("source.jpg"))
        let notAProject = store.rootURL.appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: notAProject, withIntermediateDirectories: true)
        // A fresh folder may belong to a project that is being created right now, so it stays.
        XCTAssertEqual(store.cleanUpOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(store.cleanUpOrphans(olderThan: 0), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folderURL(for: keep.project.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notAProject.path), "folders that are not project ids are not ours to touch")
    }

    func testSavingADeletedProjectDoesNotBringItBack() throws {
        let store = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Gone")
        var project = created.project
        try store.delete(id: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(for: project.id).path))
        project.title = "Late autosave"
        XCTAssertThrowsError(try store.save(project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(for: project.id).path), "the folder must not be created again")
        XCTAssertTrue(store.listProjects().isEmpty)
        let audio = Fixture.tempFolder(self).appendingPathComponent("a.wav")
        try Fixture.writeWAV(to: audio, seconds: 0.5)
        XCTAssertThrowsError(try store.attachAudio(from: audio, to: project.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(for: project.id).path))
    }

    // MARK: - Export housekeeping and failures

    func testClearOldExportsKeepsTheFilesItIsToldTo() throws {
        let folder = Exporter.exportsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a-\(UUID().uuidString).mp4")
        let b = folder.appendingPathComponent("b-\(UUID().uuidString).mp4")
        let old = folder.appendingPathComponent("old-\(UUID().uuidString).mp4")
        for url in [a, b, old] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        // Nothing younger than a day goes, unless asked.
        Exporter.clearOldExports(keeping: [a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        Exporter.clearOldExports(keeping: [a], olderThan: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "the new export stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path), "the older one goes")
        try? FileManager.default.removeItem(at: a)
    }

    func testAFailedMP4ExportLeavesNothingBehind() async throws {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: Exporter.exportsFolder.path)) ?? [])
        var project = Fixture.project(width: 160, height: 120)
        project.loop.fps = 24
        project.loop.duration = 1
        // No picture at all: the first frame cannot be rendered, after the writer has started.
        let exporter = Exporter(project: project, assets: SourceAssets())
        do {
            let url = try await exporter.exportMP4(codec: .h264, size: .p720)
            try? FileManager.default.removeItem(at: url)
            XCTFail("an export without a picture cannot succeed")
        } catch {
            XCTAssertFalse(EngineError.isCancellation(error), "this is a failure, not a cancel")
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: Exporter.exportsFolder.path)) ?? [])
        XCTAssertEqual(after.subtracting(before), [], "no partial file may be left in the exports folder")
    }

    func testCancellationCanBeToldApart() {
        XCTAssertTrue(EngineError.cancelled.isCancelled)
        XCTAssertTrue(EngineError.isCancellation(EngineError.cancelled))
        XCTAssertTrue(EngineError.isCancellation(CancellationError()))
        XCTAssertFalse(EngineError.failed("x").isCancelled)
        XCTAssertFalse(EngineError.isCancellation(EngineError.unsupported("x")))
    }

    // MARK: - GIF timing

    func testGIFDelaysAddUpToExactlyTheLoopLength() {
        for duration in [1.0, 2.0, 3.5, 4.0, 4.2, 7.3, 15.0] {
            for fps in [5, 8, 10, 12, 15, 20, 24, 25, 30] {
                let timing = Exporter.gifTiming(duration: duration, fps: fps, frameCap: 10_000)
                let total = Int((duration * 100).rounded())
                XCTAssertEqual(timing.delays.reduce(0, +), total, "duration \(duration) fps \(fps)")
                XCTAssertGreaterThanOrEqual(timing.delays.min() ?? 0, 2, "no delay below 2 centiseconds: \(duration) \(fps)")
                let desired = (duration * Double(fps)).rounded()
                XCTAssertEqual(Double(timing.delays.count), desired, accuracy: desired * 0.12 + 0.01, "the frame count follows the frame rate: \(duration) \(fps)")
                XCTAssertFalse(timing.capped)
                XCTAssertLessThanOrEqual((timing.delays.max() ?? 0) - (timing.delays.min() ?? 0), 1, "delays differ by at most one centisecond")
            }
        }
        // 30 fps over 4.2 s: exactly 3 centiseconds per frame, 140 frames (33 fps).
        let exact = Exporter.gifTiming(duration: 4.2, fps: 30, frameCap: 10_000)
        XCTAssertEqual(Set(exact.delays), [3])
        XCTAssertEqual(exact.delays.count, 140)
    }

    func testGIFTimingReportsWhenFramesAreCapped() {
        let timing = Exporter.gifTiming(duration: 10, fps: 30, frameCap: 50)
        XCTAssertTrue(timing.capped)
        XCTAssertEqual(timing.delays.count, 50)
        XCTAssertEqual(timing.delays.reduce(0, +), 1000, "a capped GIF still lasts as long as the loop")
    }

    func testGIFEstimateWarnsWhenTheFrameRateIsLowered() {
        var project = Fixture.project(width: 1920, height: 1080)
        project.loop.duration = 15
        let exporter = Exporter(project: project, assets: SourceAssets(still: Fixture.photo(width: 64, height: 48)))
        let big = exporter.estimateGIF(options: GIFOptions(width: 1080, fps: 30))
        XCTAssertTrue(big.isCapped)
        XCTAssertNotNil(big.warning)
        XCTAssertEqual(big.warning, big.note)
        let pixels = big.width * big.height * big.frameCount
        XCTAssertLessThanOrEqual(pixels, 52 * 1024 * 1024, "indexed pixels held at once stay bounded")
        let small = exporter.estimateGIF(options: GIFOptions(width: 320, fps: 10))
        XCTAssertFalse(small.isCapped)
        XCTAssertNil(small.warning)
    }

    func testExportedGIFDelaysMatchTheLoopLength() async throws {
        var project = Fixture.project(width: 160, height: 120)
        project.loop.fps = 24
        project.loop.duration = 1
        let exporter = Exporter(project: project, assets: SourceAssets(still: Fixture.photo(width: 160, height: 120)))
        let url = try await exporter.exportGIF(options: GIFOptions(width: 160, fps: 30, paletteColors: 64, dither: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        XCTAssertEqual(count, 30)
        var total = 0.0
        for i in 0..<count {
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            total += (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        XCTAssertEqual(total, 1.0, accuracy: 0.011, "the frames add up to the loop length, so the GIF does not drift")
    }

    // MARK: - Memory

    func testRenderCacheBudgetScalesWithTheDevice() {
        let budget = RenderEngine.memoBudgetBytes
        XCTAssertGreaterThanOrEqual(budget, 128 * 1024 * 1024)
        XCTAssertLessThanOrEqual(budget, 700 * 1024 * 1024)
        let ram = Int(ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(budget, max(128 * 1024 * 1024, ram / 100 * 12))
        let frames = VideoFrameStore.defaultBudgetBytes
        XCTAssertGreaterThanOrEqual(frames, 96 * 1024 * 1024)
        XCTAssertLessThanOrEqual(frames, 256 * 1024 * 1024)
        XCTAssertLessThanOrEqual(LayerRenderer.cacheByteBudget, 48 * 1024 * 1024)
    }

    private func typewriterProject() -> Project {
        var p = Fixture.project(width: 160, height: 120)
        var text = TextLayer(text: "The quick brown fox jumps over the lazy dog")
        text.entrance = LayerAnimation(kind: .typewriter, duration: 1.5)
        p.texts = [text]
        return p
    }

    func testTypewriterDoesNotFillTheTextCache() {
        let engine = Fixture.engine(typewriterProject())
        LayerRenderer.clearCache()
        _ = Fixture.render(engine, time: 1.9)
        let finished = LayerRenderer.cachedBytes
        XCTAssertGreaterThan(finished, 0)
        LayerRenderer.clearCache()
        // Walk through the whole typing animation: one cached bitmap per text layer, not one per typed letter.
        for i in 0...20 { _ = Fixture.render(engine, time: 0.1 + Double(i) * 0.09) }
        XCTAssertEqual(LayerRenderer.cachedBytes, finished, "half-typed lines are not cached")
        XCTAssertLessThanOrEqual(LayerRenderer.cachedBytes, LayerRenderer.cacheByteBudget)
    }

    func testMemoryWarningDropsEveryCacheAndRenderingContinues() {
        let engine = Fixture.engine(typewriterProject())
        let before = Fixture.bytes(engine, time: 1.9)
        XCTAssertGreaterThan(LayerRenderer.cachedBytes, 0)
        engine.handleMemoryWarning()
        XCTAssertEqual(LayerRenderer.cachedBytes, 0)
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, 0)
        let after = Fixture.bytes(engine, time: 1.9)
        XCTAssertEqual(Fixture.meanDiff(before, after), 0, accuracy: 0.0001, "the same pixels come back after the caches were dropped")
    }

    // MARK: - Cinemagraph frame store

    func testFramePlanKeepsFarMoreDetailThanTheOldBudget() {
        let video = CGSize(width: 1920, height: 1080)
        let budget = 256 * 1024 * 1024
        let long = VideoFrameStore.plan(videoSize: video, videoFPS: 30, videoDuration: 20, start: 0, length: 6, budgetBytes: budget)
        XCTAssertEqual(long.fps, 12)
        XCTAssertEqual(long.count, 73)
        let oldPixels = 150 * 1024 * 1024 / 145 / 4
        XCTAssertGreaterThan(long.width * long.height, 3 * oldPixels, "at least three times the detail of the old 0.26 MP frames")
        XCTAssertLessThanOrEqual(long.byteCost, budget)
        let short = VideoFrameStore.plan(videoSize: video, videoFPS: 30, videoDuration: 20, start: 0, length: 2, budgetBytes: budget)
        XCTAssertEqual(short.fps, 15)
        XCTAssertEqual(short.width, 1920, "a short segment fits at the full size of the video")
        XCTAssertEqual(short.height, 1080)
        XCTAssertEqual(short.width % 2, 0)
        // A phone clip shot at a low frame rate is never sampled faster than it was shot.
        let slow = VideoFrameStore.plan(videoSize: video, videoFPS: 10, videoDuration: 20, start: 0, length: 6, budgetBytes: budget)
        XCTAssertEqual(slow.fps, 10)
        // Portrait video keeps its shape.
        let portrait = VideoFrameStore.plan(videoSize: CGSize(width: 1080, height: 1920), videoFPS: 30, videoDuration: 20, start: 1, length: 4, budgetBytes: budget)
        XCTAssertEqual(Double(portrait.width) / Double(portrait.height), 1080.0 / 1920.0, accuracy: 0.02)
        XCTAssertEqual(portrait.segmentStart, 1)
        // A segment that runs past the end of the clip is cut to fit.
        let tail = VideoFrameStore.plan(videoSize: video, videoFPS: 30, videoDuration: 5, start: 4, length: 6, budgetBytes: budget)
        XCTAssertEqual(tail.segmentLength, 1, accuracy: 0.001)
    }

    func testStoreCacheDecodesOncePerKeyEvenWhenAskedFromManyThreads() {
        let cache = VideoStoreCache()
        let counter = CounterBox()
        func make() -> VideoFrameStore? {
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return VideoFrameStore(width: 4, height: 4, fps: 10, length: 1, frames: [PixelBuffer(width: 4, height: 4), PixelBuffer(width: 4, height: 4)])
        }
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            _ = cache.store(for: "clip-a", make: make)
        }
        XCTAssertEqual(counter.value, 1, "callers asking for the same segment share one decode")
        XCTAssertEqual(cache.heldBytes, 2 * 4 * 4 * 4)
        _ = cache.store(for: "clip-a", make: make)
        XCTAssertEqual(counter.value, 1)
        _ = cache.store(for: "clip-b", make: make)
        XCTAssertEqual(counter.value, 2, "another segment is decoded again")
        cache.clear()
        XCTAssertEqual(cache.heldBytes, 0)
        XCTAssertNil(cache.store(for: "failing") { nil }, "a failed or cancelled decode gives nil and is not remembered")
        XCTAssertEqual(cache.heldBytes, 0)
    }

    private func videoProject(size: CGSize, duration: Double) -> Project {
        Project.new(title: "Clip", kind: .video, fileName: "clip.mp4", pixelWidth: Int(size.width), pixelHeight: Int(size.height), videoDuration: duration)
    }

    func testExportSizesAreHonestForCinemagraphs() async throws {
        let folder = Fixture.tempFolder(self)
        let clip = folder.appendingPathComponent("clip.mp4")
        try Fixture.writeTestVideo(to: clip)
        let project = videoProject(size: CGSize(width: 128, height: 96), duration: 2)
        let assets = SourceAssets(videoURL: clip)
        // The clip is 128 x 96 pixels: nothing above 720p can show more detail than that.
        XCTAssertEqual(RenderEngine.maxUsefulExportLongEdge(project: project, assets: assets), 1280)
        let exporter = Exporter(project: project, assets: assets)
        XCTAssertEqual(exporter.maxUsefulExportLongEdge, 1280)
        XCTAssertEqual(exporter.availableResolutions(codec: .h264), [.p720])
        XCTAssertEqual(Fixture.engine(Fixture.project()).maxUsefulExportLongEdge, 4096, "photos can go as large as the picture allows")
        let photoExporter = Exporter(project: Fixture.project(), assets: SourceAssets(still: Fixture.photo()))
        XCTAssertEqual(photoExporter.availableResolutions(codec: .h264), Exporter.supportedResolutions(codec: .h264))
    }

    func testLargeVideosAllowLargerExports() {
        // 4K source and a short segment: the frames keep the full 3840 pixels.
        let size = CGSize(width: 3840, height: 2160)
        let plan = VideoFrameStore.plan(videoSize: size, videoFPS: 30, videoDuration: 10, start: 0, length: 1.5, budgetBytes: 256 * 1024 * 1024)
        XCTAssertGreaterThan(plan.width, 2000, "plenty of detail for 2K exports")
        XCTAssertLessThanOrEqual(plan.byteCost, 256 * 1024 * 1024)
    }

    func testCinemagraphPreviewQualitiesShareOneStore() async throws {
        let folder = Fixture.tempFolder(self)
        let clip = folder.appendingPathComponent("clip.mp4")
        try Fixture.writeTestVideo(to: clip)
        var project = videoProject(size: CGSize(width: 128, height: 96), duration: 2)
        project.loop.duration = project.cinemagraph.loopLength
        let engine = RenderEngine(project: project, assets: SourceAssets(videoURL: clip))
        VideoStoreCache.shared.clear()
        for edge in [96, 128, 64, 160] {
            XCTAssertNotNil(engine.renderFrame(time: 0.3, quality: RenderQuality(longEdge: edge)), "edge \(edge)")
        }
        let held = VideoStoreCache.shared.heldBytes
        XCTAssertGreaterThan(held, 0)
        XCTAssertLessThanOrEqual(held, VideoFrameStore.defaultBudgetBytes)
        // A second engine (the exporter's) reuses the same frames instead of decoding the clip again.
        let second = RenderEngine(project: project, assets: SourceAssets(videoURL: clip))
        XCTAssertNotNil(second.renderFrame(time: 0.6, quality: RenderQuality(longEdge: 96)))
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, held)
        engine.handleMemoryWarning()
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, 0)
        XCTAssertNotNil(engine.renderFrame(time: 0.3, quality: RenderQuality(longEdge: 96)), "frames are read again after a memory warning")
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, held)
    }

    // MARK: - Stabilisation

    private func buffer(_ image: CGImage) -> PixelBuffer {
        PixelBuffer.scaled(image, width: image.width, height: image.height)!
    }

    private func rgba(_ b: PixelBuffer) -> [UInt8] { Fixture.rgba(b.makeCGImage()!) }

    func testStabilizerFindsAKnownShift() {
        let base = buffer(Fixture.photo(width: 160, height: 120))
        // moved(x, y) = base(x - 6, y + 4), so base(x, y) = moved(x + 6, y - 4).
        let moved = Stabilizer.shifted(base, dx: -6, dy: 4)
        let s = Stabilizer.shift(of: moved, relativeTo: base)
        XCTAssertEqual(s.dx, 6, accuracy: 0.8)
        XCTAssertEqual(s.dy, -4, accuracy: 0.8)
        let none = Stabilizer.shift(of: base, relativeTo: base)
        XCTAssertEqual(none.dx, 0, accuracy: 0.01)
        XCTAssertEqual(none.dy, 0, accuracy: 0.01)
        let fractional = Stabilizer.shift(of: Stabilizer.shifted(base, dx: -2.5, dy: 1.5), relativeTo: base)
        XCTAssertEqual(fractional.dx, 2.5, accuracy: 1.3)
        XCTAssertEqual(fractional.dy, -1.5, accuracy: 1.3)
    }

    func testStabilizerLinesUpAShakySequence() {
        let reference = buffer(Fixture.photo(width: 160, height: 120))
        let offsets: [(Double, Double)] = [(0, 0), (4, -2), (-6, 4), (8, 6), (-4, -6), (2, 2)]
        let shaky = offsets.map { Stabilizer.shifted(reference, dx: $0.0, dy: $0.1) }
        let aligned = Stabilizer.align(shaky, to: reference)
        XCTAssertEqual(aligned.count, shaky.count)
        let ref = rgba(reference)
        // Compare away from the edges, where shifting has to invent pixels.
        let inside: (Int, Int) -> Bool = { x, y in x >= 14 && x < 146 && y >= 14 && y < 106 }
        var worstBefore = 0.0, worstAfter = 0.0
        for i in 0..<shaky.count {
            let before = Fixture.meanDiff(rgba(shaky[i]), ref, where: inside, width: 160)
            let after = Fixture.meanDiff(rgba(aligned[i]), ref, where: inside, width: 160)
            worstBefore = max(worstBefore, before)
            worstAfter = max(worstAfter, after)
            if i > 0 { XCTAssertLessThan(after, before * 0.35, "frame \(i): shake \(before) left \(after)") }
        }
        XCTAssertGreaterThan(worstBefore, 5, "the test sequence really is shaky")
        XCTAssertLessThan(worstAfter, 6, "after aligning, every frame is close to the reference")
    }

    func testStabilizerLeavesAlignedFramesAlone() {
        let reference = buffer(Fixture.photo(width: 160, height: 120))
        let frames = [reference.clone(), reference.clone()]
        let out = Stabilizer.align(frames, to: reference)
        XCTAssertTrue(out[0] === frames[0] && out[1] === frames[1], "frames that already line up are returned as they are")
        // A cancelled run hands back what it was given.
        let token = RenderToken()
        token.cancel()
        let shaky = [Stabilizer.shifted(reference, dx: 5, dy: 5)]
        XCTAssertTrue(Stabilizer.align(shaky, to: reference, token: token)[0] === shaky[0])
    }

    func testStabilizeFlagIsReadByTheEngine() async throws {
        let folder = Fixture.tempFolder(self)
        let clip = folder.appendingPathComponent("clip.mp4")
        try Fixture.writeTestVideo(to: clip)
        var project = videoProject(size: CGSize(width: 128, height: 96), duration: 2)
        project.loop.duration = project.cinemagraph.loopLength
        project.cinemagraph.stabilize = true
        let engine = RenderEngine(project: project, assets: SourceAssets(videoURL: clip))
        VideoStoreCache.shared.clear()
        XCTAssertNotNil(engine.renderFrame(time: 0.2, quality: RenderQuality(longEdge: 96)))
        XCTAssertGreaterThan(VideoStoreCache.shared.heldBytes, 0)
        // Turning it off builds a different store (the cache key includes the flag).
        project.cinemagraph.stabilize = false
        engine.update(project: project)
        XCTAssertNotNil(engine.renderFrame(time: 0.2, quality: RenderQuality(longEdge: 96)))
    }
}

// MARK: - Second audit: audio trim, memory warnings in exports, project file safety

extension EngineAuditTests {

    func testAnInvertedOrTinyAudioTrimMeansPlayToTheEnd() {
        // End before start, end a hair after start, start past the end of the file: all play to the end, never a short loop.
        var w = AudioFeeder.trimWindow(trimStart: 3, trimEnd: 2, available: 10)
        XCTAssertEqual(w.start, 3); XCTAssertEqual(w.end, 10, accuracy: 1e-9)
        w = AudioFeeder.trimWindow(trimStart: 3, trimEnd: 3.02, available: 10)
        XCTAssertEqual(w.start, 3); XCTAssertEqual(w.end, 10, accuracy: 1e-9)
        w = AudioFeeder.trimWindow(trimStart: 3, trimEnd: 3, available: 10)
        XCTAssertEqual(w.end, 10, accuracy: 1e-9)
        w = AudioFeeder.trimWindow(trimStart: 12, trimEnd: nil, available: 10)
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 10, accuracy: 1e-9)
        w = AudioFeeder.trimWindow(trimStart: 9.98, trimEnd: nil, available: 10)
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 10, accuracy: 1e-9)
    }

    func testAValidAudioTrimIsKeptAndNeverReachesPastTheFile() {
        var w = AudioFeeder.trimWindow(trimStart: 1, trimEnd: 4, available: 10)
        XCTAssertEqual(w.start, 1); XCTAssertEqual(w.end, 4, accuracy: 1e-9)
        w = AudioFeeder.trimWindow(trimStart: 0, trimEnd: 25, available: 10)
        XCTAssertEqual(w.end, 10, accuracy: 1e-9, "an end past the file is cut to the file")
        w = AudioFeeder.trimWindow(trimStart: -3, trimEnd: nil, available: 10)
        XCTAssertEqual(w.start, 0)
        w = AudioFeeder.trimWindow(trimStart: .nan, trimEnd: .infinity, available: 10)
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 10, accuracy: 1e-9)
    }

    func testAudioShorterThanFiftyMillisecondsStaysInsideTheFile() {
        for available in [0.02, 0.049, 0.05, 0.06] {
            for (start, end) in [(0.0, nil), (0.01, 0.03), (0.5, 0.2)] as [(Double, Double?)] {
                let w = AudioFeeder.trimWindow(trimStart: start, trimEnd: end, available: available)
                XCTAssertGreaterThanOrEqual(w.start, 0)
                XCTAssertLessThanOrEqual(w.end, available + 1e-9, "available \(available), start \(start)")
                XCTAssertGreaterThan(w.end, w.start)
            }
        }
    }

    func testExportEnginesKeepTheirVideoFramesThroughAMemoryWarning() async throws {
        let folder = Fixture.tempFolder(self)
        let clip = folder.appendingPathComponent("clip.mp4")
        try Fixture.writeTestVideo(to: clip)
        var project = videoProject(size: CGSize(width: 128, height: 96), duration: 2)
        project.loop.duration = project.cinemagraph.loopLength
        let engine = RenderEngine(project: project, assets: SourceAssets(videoURL: clip))
        engine.observeMemoryWarnings(keepingVideoFrames: true)
        VideoStoreCache.shared.clear()
        XCTAssertNotNil(engine.renderFrame(time: 0.3, quality: RenderQuality(longEdge: 96)))
        let held = VideoStoreCache.shared.heldBytes
        XCTAssertGreaterThan(held, 0)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, held, "the store the export is reading from stays")
        XCTAssertNotNil(engine.renderFrame(time: 0.6, quality: RenderQuality(longEdge: 96)))

        // An engine that is not holding frames in use lets them go.
        let preview = RenderEngine(project: project, assets: SourceAssets(videoURL: clip))
        preview.observeMemoryWarnings(keepingVideoFrames: false)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(VideoStoreCache.shared.heldBytes, 0)
    }

    func testExportEnginesDropTheirRenderMemoAtAMemoryWarning() {
        let engine = Fixture.engine(typewriterProject())
        engine.observeMemoryWarnings(keepingVideoFrames: true)
        _ = Fixture.render(engine, time: 1.9)
        XCTAssertGreaterThan(LayerRenderer.cachedBytes, 0)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(LayerRenderer.cachedBytes, 0)
        XCTAssertNotNil(engine.renderFrame(time: 1.9, quality: RenderQuality(longEdge: 96)), "rendering carries on")
    }

    func testEnginesStopListeningWhenTheyGoAway() {
        weak var weakEngine: RenderEngine?
        autoreleasepool {
            let engine = Fixture.engine(typewriterProject())
            engine.observeMemoryWarnings(keepingVideoFrames: true)
            weakEngine = engine
        }
        XCTAssertNil(weakEngine, "the observer must not keep the engine alive")
    }

    // MARK: Project files

    private func makeSecondStore() -> ProjectStore {
        ProjectStore(rootURL: Fixture.tempFolder(self).appendingPathComponent("Projects", isDirectory: true))
    }

    private func rewriteProjectFile(_ store: ProjectStore, _ id: UUID, _ change: (inout [String: Any]) -> Void) throws {
        let url = store.fileURL("project.json", in: id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func origExists(_ store: ProjectStore, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: store.fileURL("project.json.orig", in: id).path)
    }

    func testANaNInAProjectDoesNotMakeEverySaveFail() throws {
        let store = makeSecondStore()
        var project = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Nan").project
        project.canvas.zoom = .nan
        project.canvas.centerX = .infinity
        XCTAssertThrowsError(try JSONEncoder().encode(project), "a plain encoder refuses these numbers")
        XCTAssertNoThrow(try store.save(project))
        project.title = "Still saving"
        XCTAssertNoThrow(try store.save(project))
        let loaded = try store.load(id: project.id)
        XCTAssertEqual(loaded.title, "Still saving")
        XCTAssertEqual(loaded.source.pixelWidth, 80)
    }

    func testANormalProjectGetsNoOriginalCopy() throws {
        let store = makeSecondStore()
        var project = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Plain").project
        let fresh = ProjectStore(rootURL: store.rootURL)
        project.title = "Edited"
        try fresh.save(project)
        try fresh.save(project)
        XCTAssertFalse(origExists(store, project.id))
        // A file that only lacks keys (an older build) loses nothing either.
        try rewriteProjectFile(store, project.id) { $0.removeValue(forKey: "look"); $0.removeValue(forKey: "cinemagraph") }
        XCTAssertNil(ProjectStore.whatLoadingWouldLose(try Data(contentsOf: store.fileURL("project.json", in: project.id))))
        let older = ProjectStore(rootURL: store.rootURL)
        try older.save(try older.load(id: project.id))
        XCTAssertFalse(origExists(store, project.id))
    }

    func testAFileFromANewerBuildIsKeptOnceAndNeverOverwritten() throws {
        let store = makeSecondStore()
        let project = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Future").project
        try rewriteProjectFile(store, project.id) { $0["schemaVersion"] = Project.currentSchemaVersion + 4; $0["holo"] = ["a": 1] }
        let original = try Data(contentsOf: store.fileURL("project.json", in: project.id))

        let run = ProjectStore(rootURL: store.rootURL)
        var opened = try run.load(id: project.id)
        XCTAssertEqual(opened.title, "Future")
        opened.title = "Edited by an older build"
        try run.save(opened)
        let orig = store.fileURL("project.json.orig", in: project.id)
        XCTAssertEqual(try Data(contentsOf: orig), original, "the untouched file is kept")
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL("project.json", in: project.id)), original)

        // More saves, in this run and in the next one: the copy stays exactly as it was.
        opened.title = "Edited again"
        try run.save(opened)
        let nextRun = ProjectStore(rootURL: store.rootURL)
        try nextRun.save(try nextRun.load(id: project.id))
        XCTAssertEqual(try Data(contentsOf: orig), original)
    }

    func testDroppedOrReplacedValuesKeepAnOriginalCopy() throws {
        let store = makeSecondStore()
        var project = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Dropped").project
        project.livingEffects = [LivingEffect(kind: .ripple, strength: 0.8, speed: 1)]
        try store.save(project)
        try rewriteProjectFile(store, project.id) { object in
            var effects = (object["livingEffects"] as? [[String: Any]]) ?? []
            effects.append(["kind": "hologramFromTheFuture", "strength": 0.9])
            object["livingEffects"] = effects
        }
        let original = try Data(contentsOf: store.fileURL("project.json", in: project.id))
        let run = ProjectStore(rootURL: store.rootURL)
        let opened = try run.load(id: project.id)
        XCTAssertEqual(opened.livingEffects.count, 1, "the unknown effect is dropped on load")
        try run.save(opened)
        XCTAssertEqual(try Data(contentsOf: store.fileURL("project.json.orig", in: project.id)), original)
        XCTAssertTrue(ProjectStore.loadingWouldLoseData(original))
    }

    func testLoadingWouldLoseDataOnlyWhenSomethingIsReallyLost() throws {
        let project = richProject()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let clean = try encoder.encode(project)
        XCTAssertFalse(ProjectStore.loadingWouldLoseData(clean))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        object.removeValue(forKey: "texts")
        XCTAssertNil(ProjectStore.whatLoadingWouldLose(try JSONSerialization.data(withJSONObject: object)), "missing keys take defaults, nothing is lost")
        object["unknownKeyFromTheFuture"] = 1
        XCTAssertTrue(ProjectStore.loadingWouldLoseData(try JSONSerialization.data(withJSONObject: object)))
        XCTAssertFalse(ProjectStore.loadingWouldLoseData(Data("not json".utf8)), "an unreadable file is not a newer file")
    }

    func testDuplicatingAProjectStartsItsOwnOriginalCopy() throws {
        let store = makeSecondStore()
        let project = try store.createPhotoProject(image: Fixture.photo(width: 80, height: 60), originalData: nil, title: "Src").project
        try rewriteProjectFile(store, project.id) { $0["schemaVersion"] = Project.currentSchemaVersion + 1 }
        let run = ProjectStore(rootURL: store.rootURL)
        try run.save(try run.load(id: project.id))
        XCTAssertTrue(origExists(store, project.id))
        let sourceOrig = try Data(contentsOf: store.fileURL("project.json.orig", in: project.id))
        let sourceNow = try Data(contentsOf: store.fileURL("project.json", in: project.id))
        let copy = try run.duplicate(id: project.id)
        let copied = try Data(contentsOf: store.fileURL("project.json.orig", in: copy.id))
        XCTAssertEqual(copied, sourceNow, "the copy keeps the file it was copied from")
        XCTAssertNotEqual(copied, sourceOrig)
    }
}

/// A counter that can be bumped from several threads.
final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
