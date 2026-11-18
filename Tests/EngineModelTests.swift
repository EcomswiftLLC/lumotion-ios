import XCTest
import CoreGraphics
@testable import Lumotion

/// Project JSON, the on-disk project store, masks and the stroke rasteriser.
final class EngineModelTests: XCTestCase {

    // MARK: Project JSON

    private func fullProject() -> Project {
        var p = Project(title: "Everything", source: SourceSpec(kind: .still, fileName: "source.jpg", pixelWidth: 4000, pixelHeight: 3000),
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        p.canvas = CanvasSpec(aspect: .story916, fit: .fit, centerX: 0.4, centerY: 0.6, zoom: 1.7, background: .color, backgroundColor: RGBAColor(0.1, 0.2, 0.3))
        p.loop = LoopSpec(duration: 5.5, fps: 60, mode: .pingPong, reverse: true, speed: 1.5)
        p.flowRegions = [FlowRegion(name: "Water", strokes: [BrushStroke(points: [NPoint(0.1, 0.2), NPoint(0.7, 0.8)], radius: 0.07, feather: 0.3, erase: false, value: 0.5)],
                                    arrows: [FlowArrow(from: NPoint(0.2, 0.2), to: NPoint(0.6, 0.7))], speed: 1.3, strength: 0.65, softness: 0.4)]
        p.anchors = [BrushStroke(points: [NPoint(0.5, 0.5)], radius: 0.1, feather: 0.2, erase: true)]
        p.camera = CameraMotion(kind: .custom, amount: 0.3, easing: .easeOut, loops: false)
        p.parallax = ParallaxSettings(enabled: true, depthSource: .manualBrush, style: .swing, strength: 0.7, edgeFill: .mirror, invertDepth: true)
        p.parallax.depthStrokes = [BrushStroke(points: [NPoint(0.3, 0.3)], radius: 0.2, feather: 0.8, erase: false, value: 0.2)]
        p.livingEffects = PresetLibrary.apply("glitch-vhs", to: p).livingEffects
        p.livingEffects.append(LivingEffect(kind: .swirl, strength: 0.4, speed: 2, scale: 1.5, angle: 33, center: NPoint(0.3, 0.7),
                                            gradient: GradientMask(start: NPoint(0, 0), end: NPoint(1, 1), softness: 0.2, invert: true),
                                            brush: [BrushStroke(points: [NPoint(0.5, 0.5), NPoint(0.6, 0.6)])]))
        p.overlays = [OverlayLayer(kind: .confetti, intensity: 0.9, speed: 1.4, size: 1.2, tint: RGBAColor(1, 0.5, 0.2, 0.9), direction: 75, depthBlur: 0.2, placement: .under, seed: 77)]
        p.look = Look(filter: .gilt, intensity: 66, adjust: LookAdjust(exposure: 0.1, contrast: -0.2, saturation: 0.3, warmth: 0.4, tint: -0.1, highlights: 0.2, shadows: -0.3, sharpen: 0.5, vignette: 0.4, grain: 0.2, glow: 0.6),
                      animatedGrain: false, flicker: Flicker(amount: 0.3, speed: 1.7))
        var text = TextLayer(text: "Hello, world")
        text.design = .monospaced; text.weight = .heavy; text.outline = RGBAColor(0, 0, 0); text.endTime = 3.5
        p.texts = [text]
        var sticker = StickerLayer(emoji: "A")
        sticker.idle = .sway
        p.stickers = [sticker]
        p.audio = AudioTrackSpec(fileName: "audio.m4a", displayName: "Song", trimStart: 1, trimEnd: 4, volume: 0.6, fadeIn: 0.2, fadeOut: 0.8, loops: false, muted: false)
        p.cinemagraph.maskStrokes = [BrushStroke(points: [NPoint(0.2, 0.2)])]
        p.cinemagraph.pingPong = true
        p.presetID = "dream-sparkle"
        return p
    }

    func testProjectJSONRoundTrip() throws {
        let original = fullProject()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded, original)
        // Twice over: the encoding itself is stable.
        XCTAssertEqual(try JSONEncoder().encode(decoded).count, data.count)
    }

    func testProjectJSONRoundTripWithTheStoreFormat() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = fullProject()
        let data = try encoder.encode(original)
        XCTAssertEqual(try decoder.decode(Project.self, from: data), original)
        XCTAssertEqual(try encoder.encode(original), data, "sorted keys give identical bytes")
    }

    func testEveryPresetSurvivesJSON() throws {
        for info in PresetLibrary.all {
            let p = PresetLibrary.apply(info.id, to: fullProject())
            let decoded = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
            XCTAssertEqual(decoded, p, "preset \(info.id)")
        }
    }

    func testPointsEncodeAsPairs() throws {
        let data = try JSONEncoder().encode(NPoint(0.25, 0.75))
        XCTAssertEqual(String(data: data, encoding: .utf8), "[0.25,0.75]")
        XCTAssertEqual(try JSONDecoder().decode(NPoint.self, from: data), NPoint(0.25, 0.75))
    }

    func testOlderFilesWithMissingFieldsStillOpen() throws {
        let data = try JSONEncoder().encode(fullProject())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["overlays", "livingEffects", "look", "presetID", "cinemagraph", "texts", "stickers", "audio", "parallax", "camera", "anchors", "flowRegions"] {
            object.removeValue(forKey: key)
        }
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Project.self, from: trimmed)
        XCTAssertEqual(decoded.title, "Everything")
        XCTAssertTrue(decoded.overlays.isEmpty)
        XCTAssertTrue(decoded.flowRegions.isEmpty)
        XCTAssertNil(decoded.audio)
        XCTAssertNil(decoded.presetID)
        XCTAssertEqual(decoded.loop.fps, 60)
    }

    func testLoopSpecPhase() {
        var loop = LoopSpec()
        loop.duration = 4
        XCTAssertEqual(loop.phase(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: 4), 0, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: 5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: -1), 0.75, accuracy: 1e-9)
        loop.mode = .pingPong
        XCTAssertEqual(loop.phase(at: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(loop.phase(at: 3), 0.5, accuracy: 1e-9)
        loop.mode = .loop
        loop.reverse = true
        XCTAssertEqual(loop.phase(at: 1), 0.75, accuracy: 1e-9)
        loop.fps = 30
        XCTAssertEqual(loop.frameCount, 120)
        loop.duration = 100
        XCTAssertEqual(loop.clampedDuration, 60)
    }

    // MARK: ProjectStore

    private func makeStore() -> (ProjectStore, URL) {
        let folder = Fixture.tempFolder(self)
        return (ProjectStore(rootURL: folder.appendingPathComponent("Projects", isDirectory: true)), folder)
    }

    func testStoreCreateSaveLoadListRenameDuplicateDelete() throws {
        let (store, _) = makeStore()
        XCTAssertTrue(store.listProjects().isEmpty)

        let photo = Fixture.photo(width: 120, height: 90)
        let created = try store.createPhotoProject(image: photo, originalData: nil, title: "First")
        XCTAssertEqual(created.project.title, "First")
        XCTAssertEqual(created.project.source.pixelWidth, 120)
        XCTAssertEqual(created.project.source.kind, .still)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL("source.jpg", in: created.project.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumbnailURL(for: created.project.id).path))

        var listing = store.listProjects()
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing.first?.id, created.project.id)
        XCTAssertEqual(listing.first?.title, "First")
        XCTAssertNotNil(listing.first?.thumbnailURL)

        // Save edits and read them back.
        var edited = created.project
        edited.overlays = [OverlayLayer(kind: .snow, intensity: 0.7, seed: 4)]
        edited.camera = CameraMotion(kind: .zoomIn, amount: 0.4)
        edited.flowRegions = PresetLibrary.apply("waterfall", to: edited).flowRegions
        try store.save(edited)
        var loaded = try store.load(id: edited.id)
        XCTAssertEqual(loaded.overlays, edited.overlays)
        XCTAssertEqual(loaded.camera, edited.camera)
        XCTAssertEqual(loaded.flowRegions, edited.flowRegions)
        XCTAssertGreaterThanOrEqual(loaded.modifiedAt.timeIntervalSince1970, edited.modifiedAt.timeIntervalSince1970 - 1)

        // The photo can be loaded again from disk and renders.
        let assets = try store.loadAssets(for: loaded)
        let still = try XCTUnwrap(assets.still)
        XCTAssertEqual(still.width, 120)
        XCTAssertEqual(still.height, 90)
        XCTAssertNotNil(RenderEngine(project: loaded, assets: assets).renderFrame(time: 0.3, quality: RenderQuality(longEdge: 64)))

        // Rename.
        try store.rename(id: loaded.id, title: "Renamed")
        loaded = try store.load(id: loaded.id)
        XCTAssertEqual(loaded.title, "Renamed")
        XCTAssertEqual(loaded.overlays, edited.overlays, "renaming must not lose edits")

        // Duplicate.
        let copy = try store.duplicate(id: loaded.id)
        XCTAssertNotEqual(copy.id, loaded.id)
        XCTAssertTrue(copy.title.hasPrefix("Renamed"))
        XCTAssertEqual(copy.overlays, loaded.overlays)
        listing = store.listProjects()
        XCTAssertEqual(listing.count, 2)
        XCTAssertNotNil(try? store.loadAssets(for: copy).still, "the duplicate has its own copy of the photo")

        // Delete only removes the one project.
        try store.delete(id: loaded.id)
        listing = store.listProjects()
        XCTAssertEqual(listing.map(\.id), [copy.id])
        XCTAssertThrowsError(try store.load(id: loaded.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL(for: loaded.id).path))
        XCTAssertNoThrow(try store.delete(id: loaded.id), "deleting twice is harmless")
        try store.delete(id: copy.id)
        XCTAssertTrue(store.listProjects().isEmpty)
    }

    func testStoreFallsBackToTheBackupWhenTheMainFileIsDamaged() throws {
        let (store, _) = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "Safe")
        var p = created.project
        p.title = "Second save"
        try store.save(p)
        try store.save(p)
        let main = store.folderURL(for: p.id).appendingPathComponent("project.json")
        try Data("{ not json".utf8).write(to: main)
        let recovered = try store.load(id: p.id)
        XCTAssertTrue(recovered.title == "Second save" || recovered.title == "Safe")
        XCTAssertEqual(store.listProjects().count, 1, "a damaged file does not hide the project")
    }

    func testStoreListsNewestFirstAndSkipsFoldersThatAreNotProjects() throws {
        let (store, folder) = makeStore()
        let a = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "Old")
        Thread.sleep(forTimeInterval: 1.1)
        let b = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "New")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Projects/not-a-project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Projects/\(UUID().uuidString)"), withIntermediateDirectories: true)
        let listing = store.listProjects()
        XCTAssertEqual(listing.map(\.id), [b.project.id, a.project.id])
    }

    func testStoreMasksRoundTrip() throws {
        let (store, _) = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "Masks")
        var bytes = [UInt8](repeating: 0, count: 32 * 24)
        for y in 6..<18 { for x in 8..<24 { bytes[y * 32 + x] = 255 } }
        let subject = MaskBuffer(width: 32, height: 24, data: bytes)
        let depth = MaskBuffer(width: 16, height: 12, value: 200)
        store.saveMasks(subject: subject, depth: depth, for: created.project.id)
        let assets = try store.loadAssets(for: created.project)
        let s = try XCTUnwrap(assets.subjectMask), d = try XCTUnwrap(assets.embeddedDepth)
        XCTAssertEqual(s.width, 32)
        XCTAssertEqual(s.height, 24)
        XCTAssertEqual(s.sample(u: 0.5, v: 0.5), 1, accuracy: 0.02)
        XCTAssertEqual(s.sample(u: 0.02, v: 0.02), 0, accuracy: 0.02)
        XCTAssertEqual(d.sample(u: 0.5, v: 0.5), 200.0 / 255.0, accuracy: 0.02)
    }

    func testStoreMissingPhotoIsReportedNotCrashed() throws {
        let (store, _) = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "Gone")
        try FileManager.default.removeItem(at: store.fileURL("source.jpg", in: created.project.id))
        XCTAssertThrowsError(try store.loadAssets(for: created.project)) { error in
            XCTAssertNotNil((error as? EngineError)?.errorDescription)
        }
    }

    func testAttachAudioCopiesTheFileAndRejectsOtherFiles() throws {
        let (store, folder) = makeStore()
        let created = try store.createPhotoProject(image: Fixture.photo(width: 64, height: 48), originalData: nil, title: "Audio")
        let wav = folder.appendingPathComponent("tone.wav")
        try Fixture.writeWAV(to: wav, seconds: 1.5)
        let spec = try store.attachAudio(from: wav, to: created.project.id)
        XCTAssertEqual(spec.displayName, "tone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(spec.fileName, in: created.project.id).path))
        XCTAssertEqual(ProjectStore.audioDuration(store.fileURL(spec.fileName, in: created.project.id)), 1.5, accuracy: 0.1)
        var p = created.project
        p.audio = spec
        let assets = try store.loadAssets(for: p)
        XCTAssertNotNil(assets.audioURL)

        let notAudio = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notAudio)
        XCTAssertThrowsError(try store.attachAudio(from: notAudio, to: created.project.id))
    }

    func testEncodeStillImages() throws {
        let photo = Fixture.photo(width: 40, height: 30)
        let jpeg = try XCTUnwrap(ProjectStore.encode(photo, type: "public.jpeg", quality: 0.8))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
        let png = try XCTUnwrap(ProjectStore.encode(photo, type: "public.png", quality: 1))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    // MARK: Masks and strokes

    func testMaskBufferBasics() throws {
        let mask = MaskBuffer(width: 4, height: 2, data: [0, 0, 255, 255, 0, 0, 255, 255])
        XCTAssertEqual(mask.average, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mask.sample(u: 0.1, v: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(mask.sample(u: 0.9, v: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(mask.sample(u: -5, v: 9), 0, accuracy: 1e-9, "outside the buffer uses the nearest edge")
        // A wrong sized data array is repaired rather than trusted.
        XCTAssertEqual(MaskBuffer(width: 3, height: 3, data: [1, 2]).data.count, 9)
        let big = mask.resized(width: 40, height: 20)
        XCTAssertEqual(big.width, 40)
        XCTAssertEqual(big.average, 0.5, accuracy: 0.05)
        let image = try XCTUnwrap(mask.cgImage)
        XCTAssertEqual(image.width, 4)
        let back = try XCTUnwrap(MaskBuffer.from(image))
        XCTAssertEqual(back.width, 4)
        for (x, y) in zip(back.data, mask.data) { XCTAssertEqual(Int(x), Int(y), accuracy: 3) }
    }

    func testStrokeRasterPaintsAndErases() throws {
        let paint = BrushStroke(points: [NPoint(0.2, 0.5), NPoint(0.8, 0.5)], radius: 0.1, feather: 0.3)
        let mask = try XCTUnwrap(StrokeRaster.paintMask([paint], width: 100, height: 50))
        XCTAssertEqual(mask.sample(u: 0.5, v: 0.5), 1, accuracy: 0.01, "inside the stroke")
        XCTAssertEqual(mask.sample(u: 0.5, v: 0.02), 0, accuracy: 0.01, "far from the stroke")
        XCTAssertEqual(mask.sample(u: 0.95, v: 0.5), 0, accuracy: 0.01, "beyond the end of the stroke")
        let erase = BrushStroke(points: [NPoint(0.5, 0.5)], radius: 0.08, feather: 0.1, erase: true)
        let erased = try XCTUnwrap(StrokeRaster.paintMask([paint, erase], width: 100, height: 50))
        XCTAssertLessThan(erased.sample(u: 0.5, v: 0.5), 0.1)
        XCTAssertEqual(erased.sample(u: 0.3, v: 0.5), 1, accuracy: 0.05)
        XCTAssertNil(StrokeRaster.paintMask([], width: 10, height: 10))
        XCTAssertNil(StrokeRaster.paintMask([erase], width: 10, height: 10), "only erasing paints nothing")
    }

    func testStrokeRasterIsIdenticalEveryTime() throws {
        let strokes = [BrushStroke(points: [NPoint(0.1, 0.1), NPoint(0.5, 0.9), NPoint(0.9, 0.2)], radius: 0.07, feather: 0.6)]
        let a = try XCTUnwrap(StrokeRaster.paintMask(strokes, width: 80, height: 60))
        let b = try XCTUnwrap(StrokeRaster.paintMask(strokes, width: 80, height: 60))
        XCTAssertEqual(a.data, b.data)
    }

    func testDepthHelpers() {
        let gradient = MaskProvider.gradientDepth(width: 8, height: 8)
        XCTAssertLessThan(gradient.sample(u: 0.5, v: 0.05), 0.2)
        XCTAssertGreaterThan(gradient.sample(u: 0.5, v: 0.95), 0.8)
        let manual = MaskProvider.manualDepth(strokes: [BrushStroke(points: [NPoint(0.5, 0.5)], radius: 0.2, feather: 0.2, value: 1)], width: 40, height: 40)
        XCTAssertGreaterThan(manual.sample(u: 0.5, v: 0.5), 0.9)
        XCTAssertEqual(manual.sample(u: 0.02, v: 0.02), 128.0 / 255.0, accuracy: 0.02)
    }

    func testSubjectMaskIsNilOrSensibleWithoutCrashing() async {
        // Vision can find nothing (or be unavailable) on the CI simulator. The only promise is that it does not crash.
        let mask = await MaskProvider.subjectMask(for: Fixture.photo(width: 96, height: 72))
        if let mask { XCTAssertGreaterThan(mask.width, 0) }
    }

    func testGIFOptionsAreClamped() {
        let o = GIFOptions(width: 10_000, fps: 1, paletteColors: 3, dither: true).clamped
        XCTAssertEqual(o.width, 1080)
        XCTAssertEqual(o.fps, 5)
        XCTAssertEqual(o.paletteColors, 16)
    }
}
