import XCTest
import CoreGraphics
@testable import Lumotion

/// Keeps the living effects subtle and natural: smooth, small displacements, no folds, sparse glints. Also writes contact
/// sheets of real sample photos so the result can be looked at (CI uploads them as an artifact).
final class EngineEffectLookTests: XCTestCase {

    private let phases: [Double] = [0, 0.13, 0.25, 0.5, 0.77]

    private func effect(_ kind: LivingEffectKind, strength: Double, scale: Double = 1) -> LivingEffect {
        LivingEffect(kind: kind, strength: strength, speed: 1, scale: scale, angle: 0)
    }

    // MARK: Displacement bounds

    func testSmoothDisplacementEffectsStayAFewPixelsAndNeverFold() {
        let w = 240, h = 180
        let s = Float(max(w, h))
        let kinds: [LivingEffectKind] = [.ripple, .waves, .windSway, .heatHaze]
        for kind in kinds {
            for strength in [0.25, 0.5, 1.0] {
                for scale in [0.25, 1.0, 4.0] {
                    for phase in phases {
                        let st = LivingFX.stats(effect(kind, strength: strength, scale: scale), width: w, height: h, phase: phase, cycles: 1, step: 2)
                        let label = "\(kind.rawValue) strength \(strength) scale \(scale) phase \(phase)"
                        let k = Float(strength)
                        XCTAssertLessThanOrEqual(st.meanDisplacement, 0.0065 * s * k, "mean displacement too large: \(label)")
                        XCTAssertLessThanOrEqual(st.maxDisplacement, 0.02 * s * k, "largest displacement too large: \(label)")
                        XCTAssertLessThanOrEqual(st.foldShare, 0.002, "the picture folds over itself: \(label)")
                        XCTAssertEqual(st.meanAdd, 0, accuracy: 0.0001, "\(label) should not add light")
                    }
                }
            }
        }
    }

    func testDefaultStrengthMovesPixelsByAboutAFewPixelsAtPreviewSize() {
        // 720 px preview, default strength 0.5: the mean pull stays under about 3 px, the largest under 7 px.
        let w = 720, h = 540
        for kind in [LivingEffectKind.ripple, .waves, .windSway, .heatHaze] {
            var worstMean: Float = 0, worstMax: Float = 0
            for phase in [0.0, 0.25, 0.5, 0.75] {
                let st = LivingFX.stats(effect(kind, strength: 0.5), width: w, height: h, phase: phase, cycles: 1, step: 6)
                worstMean = max(worstMean, st.meanDisplacement)
                worstMax = max(worstMax, st.maxDisplacement)
            }
            XCTAssertLessThanOrEqual(worstMean, 3.0, "\(kind.rawValue) mean displacement at default strength")
            XCTAssertLessThanOrEqual(worstMax, 7.0, "\(kind.rawValue) largest displacement at default strength")
        }
    }

    func testDisplacementScalesWithImageSize() {
        // The same effect on a small and a large frame moves by the same share of the picture.
        let small = LivingFX.stats(effect(.ripple, strength: 0.5), width: 240, height: 180, phase: 0.25, cycles: 1, step: 2)
        let large = LivingFX.stats(effect(.ripple, strength: 0.5), width: 960, height: 720, phase: 0.25, cycles: 1, step: 8)
        XCTAssertEqual(large.meanDisplacement / small.meanDisplacement, 4, accuracy: 0.6)
    }

    func testRotatingEffectsStayWithinBoundsAndNeverFold() {
        let w = 240, h = 180
        let s = Float(max(w, h))
        for strength in [0.25, 0.5, 1.0] {
            for phase in phases {
                let wobble = LivingFX.stats(effect(.wobble, strength: strength), width: w, height: h, phase: phase, cycles: 1, step: 2)
                XCTAssertLessThanOrEqual(wobble.meanDisplacement, 0.015 * s * Float(strength), "wobble \(strength) \(phase)")
                XCTAssertLessThanOrEqual(wobble.maxDisplacement, 0.04 * s * Float(strength), "wobble \(strength) \(phase)")
                XCTAssertLessThanOrEqual(wobble.foldShare, 0.002)
                let swirl = LivingFX.stats(effect(.swirl, strength: strength), width: w, height: h, phase: phase, cycles: 1, step: 2)
                XCTAssertLessThanOrEqual(swirl.maxDisplacement, 0.12 * s * Float(strength) + 0.5, "swirl \(strength) \(phase)")
                XCTAssertLessThanOrEqual(swirl.foldShare, 0.002, "swirl \(strength) \(phase)")
            }
        }
    }

    func testShimmerIsSparseGlintsNotBlotches() {
        let w = 240, h = 180
        for strength in [0.25, 0.5, 1.0] {
            for phase in phases {
                let st = LivingFX.stats(effect(.shimmer, strength: strength), width: w, height: h, phase: phase, cycles: 1, step: 1)
                XCTAssertLessThanOrEqual(st.maxDisplacement, 0.0001, "shimmer must not move pixels")
                XCTAssertLessThanOrEqual(st.maxAdd, 71 * Float(strength) + 0.01, "glints too bright: \(strength) \(phase)")
                XCTAssertLessThanOrEqual(st.meanAdd, 14 * Float(strength), "too much light added: \(strength) \(phase)")
                XCTAssertLessThanOrEqual(st.brightShare, 0.2, "too many bright pixels: \(strength) \(phase)")
            }
        }
        // At the default strength nothing gets a harsh flash.
        let normal = LivingFX.stats(effect(.shimmer, strength: 0.5), width: w, height: h, phase: 0.25, cycles: 1)
        XCTAssertLessThanOrEqual(normal.brightShare, 0.001)
    }

    func testRenderedEffectChangesTheRealPictureOnlyModestly() {
        // End to end on a real sample (or the generated photo when no sample is bundled): the default effects change
        // the picture a little, not wholesale.
        let photo = samplePhoto(named: "ocean-waves", maxPixel: 720)
        for kind in [LivingEffectKind.ripple, .waves, .windSway, .heatHaze, .shimmer] {
            var p = Project.new(title: "Look", kind: .still, fileName: "source.jpg", pixelWidth: photo.width, pixelHeight: photo.height)
            p.loop.duration = 2
            p.loop.fps = 12
            p.look.animatedGrain = false
            let plain = Fixture.engine(p, photo: photo)
            var animated = p
            animated.livingEffects = [effect(kind, strength: 0.5)]
            let engine = Fixture.engine(animated, photo: photo)
            for time in [0.0, 0.5, 1.0, 1.5] {
                let a = Fixture.bytes(plain, time: time, longEdge: 240), b = Fixture.bytes(engine, time: time, longEdge: 240)
                XCTAssertLessThanOrEqual(Fixture.meanDiff(a, b), 14, "\(kind.rawValue) changes a real photo too much at \(time) s")
            }
        }
    }

    // MARK: Contact sheets for a human look

    private func samplePhoto(named name: String, maxPixel: Int) -> CGImage {
        if let image = SampleLibrary.image(named: name, maxPixel: maxPixel) { return image }
        if let first = SampleLibrary.availableNames().first, let image = SampleLibrary.image(named: first, maxPixel: maxPixel) { return image }
        return Fixture.photo(width: 320, height: 240)
    }

    private func framesFolder() -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("build", isDirectory: true).appendingPathComponent("engine-frames", isDirectory: true)
    }

    /// Rows are strengths 0.25, 0.5 and 1.0; columns are the original, then loop phases 0, 0.25, 0.5 and 0.75.
    private func sheet(for kind: LivingEffectKind, photoName: String) -> CGImage? {
        let photo = samplePhoto(named: photoName, maxPixel: 1000)
        var base = Project.new(title: "Sheet", kind: .still, fileName: "source.jpg", pixelWidth: photo.width, pixelHeight: photo.height)
        base.loop.duration = 2
        base.loop.fps = 12
        base.look.animatedGrain = false
        let edge = 300
        let size = RenderEngine.canvasSize(for: base, longEdge: edge)
        let strengths = [0.25, 0.5, 1.0]
        let phasesShown: [Double] = [0, 0.25, 0.5, 0.75]
        let columns = phasesShown.count + 1
        let gap = 4
        let sheetW = columns * size.width + (columns + 1) * gap
        let sheetH = strengths.count * size.height + (strengths.count + 1) * gap
        var bytes = [UInt8](repeating: 24, count: sheetW * sheetH * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        let original = Fixture.engine(base, photo: photo).originalFrame(quality: RenderQuality(longEdge: edge))
        for (row, strength) in strengths.enumerated() {
            var p = base
            p.livingEffects = [effect(kind, strength: strength)]
            let engine = Fixture.engine(p, photo: photo)
            var cells = [CGImage?]()
            cells.append(original)
            for phase in phasesShown { cells.append(engine.renderFrame(time: phase * 2, quality: RenderQuality(longEdge: edge))) }
            for (col, cell) in cells.enumerated() {
                guard let cell else { continue }
                let rgba = Fixture.rgba(cell)
                let ox = gap + col * (size.width + gap), oy = gap + row * (size.height + gap)
                for y in 0..<min(size.height, cell.height) {
                    for x in 0..<min(size.width, cell.width) {
                        let from = (y * cell.width + x) * 4, to = ((oy + y) * sheetW + ox + x) * 4
                        bytes[to] = rgba[from]; bytes[to + 1] = rgba[from + 1]; bytes[to + 2] = rgba[from + 2]
                    }
                }
            }
        }
        return Fixture.image(fromRGBA: bytes, width: sheetW, height: sheetH)
    }

    func testWriteEffectContactSheets() throws {
        let folder = framesFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kinds: [LivingEffectKind] = [.ripple, .shimmer, .windSway, .heatHaze, .swirl, .waves, .wobble]
        var written = 0
        for kind in kinds {
            for name in ["ocean-waves", "waterfall", "sunset-lake"] {
                guard let image = sheet(for: kind, photoName: name), let data = ProjectStore.encode(image, type: "public.png", quality: 1) else { continue }
                try data.write(to: folder.appendingPathComponent("\(kind.rawValue)_\(name)_rows-strength-25-50-100_cols-original-phase-0-25-50-75.png"))
                written += 1
            }
        }
        XCTAssertGreaterThanOrEqual(written, kinds.count)
    }
}
