import XCTest
import CoreGraphics
@testable import Lumotion

/// Loop closure, masks, anchors, overlays, camera, looks, presets and speed, all at tiny sizes.
final class EngineRenderTests: XCTestCase {

    // MARK: Helpers

    private func bandStroke(y: Double = 0.5) -> BrushStroke {
        BrushStroke(points: [NPoint(0.02, y), NPoint(0.98, y)], radius: 0.35, feather: 0.6)
    }

    private func flowProject(strength: Double = 0.8, speed: Double = 1) -> Project {
        var p = Fixture.project()
        p.flowRegions = [FlowRegion(name: "Test", strokes: [bandStroke()],
                                    arrows: [FlowArrow(from: NPoint(0.2, 0.5), to: NPoint(0.8, 0.6))],
                                    speed: speed, strength: strength, softness: 0.5)]
        return p
    }

    // MARK: Loop closure

    func testFlowLoopsSeamlessly() {
        assertSeamless(flowProject(), label: "flow")
        assertSeamless(flowProject(strength: 1, speed: 2.5), label: "fast flow")
    }

    func testFlowLoopsInPingPongAndReverse() {
        var p = flowProject()
        p.loop.mode = .pingPong
        assertSeamless(p, label: "flow ping-pong")
        p.loop.mode = .loop
        p.loop.reverse = true
        assertSeamless(p, label: "flow reverse")
    }

    func testEveryLivingEffectLoopsSeamlessly() {
        for kind in LivingEffectKind.allCases where kind != .glitch && kind != .wiggle {
            var p = Fixture.project()
            p.livingEffects = [LivingEffect(kind: kind, strength: 0.9, speed: 1, scale: 1, angle: 0)]
            assertSeamless(p, label: "living effect \(kind.rawValue)")
        }
    }

    func testSteppedEffectsWrapAndMove() {
      for kind in [LivingEffectKind.glitch, .wiggle] {
        var p = Fixture.project()
        p.livingEffects = [LivingEffect(kind: kind, strength: 0.9, speed: 1)]
        // Stop-motion effects hold each look for a few frames and then jump, by design, so only the wrap and the motion are checked.
        let engine = Fixture.engine(p)
        let first = Fixture.bytes(engine, time: 0), wrapped = Fixture.bytes(engine, time: p.loop.clampedDuration)
        XCTAssertEqual(Fixture.meanDiff(first, wrapped), 0, accuracy: 0.0001)
        var travelled = 0.0
        for i in 1..<Fixture.fps * 2 { travelled = max(travelled, Fixture.meanDiff(first, Fixture.bytes(engine, time: Double(i) / Double(Fixture.fps)))) }
        XCTAssertGreaterThan(travelled, 0.05, "\(kind.rawValue) never changes the picture")
      }
    }

    func testEveryCameraMoveLoopsSeamlessly() {
        for kind in CameraKind.allCases where kind != .none {
            var p = Fixture.project()
            p.camera = CameraMotion(kind: kind, amount: 0.9, easing: .easeInOut, loops: true)
            assertSeamless(p, label: "camera \(kind.rawValue)")
        }
    }

    func testEveryParallaxStyleLoopsSeamlessly() {
        for style in ParallaxStyle.allCases {
            var p = Fixture.project()
            p.parallax = ParallaxSettings(enabled: true, depthSource: .gradient, style: style, strength: 0.8, edgeFill: .blur, invertDepth: false)
            assertSeamless(p, label: "parallax \(style.rawValue)")
        }
        for fill in EdgeFill.allCases {
            var p = Fixture.project()
            p.parallax = ParallaxSettings(enabled: true, depthSource: .gradient, style: .orbit, strength: 0.8, edgeFill: fill, invertDepth: false)
            assertSeamless(p, label: "parallax edge fill \(fill.rawValue)")
        }
    }

    func testEveryOverlayLoopsSeamlessly() {
        for kind in OverlayKind.allCases {
            var p = Fixture.project()
            p.overlays = [OverlayLayer(kind: kind, intensity: 0.8, speed: 1, size: 1.4, seed: 3)]
            // Fireworks burst and fade out inside the loop, so a quiet seam is expected rather than movement at every frame.
            assertSeamless(p, label: "overlay \(kind.rawValue)", longEdge: 128, expectMotion: false)
        }
    }

    func testOverlayMovesBetweenFrames() {
        for kind in [OverlayKind.rain, .snow, .leaves, .fireflies, .sparkles, .dust, .embers, .confetti, .hearts] {
            var p = Fixture.project()
            p.overlays = [OverlayLayer(kind: kind, intensity: 0.9, speed: 1, size: 1.6, seed: 5)]
            let engine = Fixture.engine(p)
            let a = Fixture.bytes(engine, time: 0, longEdge: 128), b = Fixture.bytes(engine, time: 0.5, longEdge: 128)
            XCTAssertGreaterThan(Fixture.meanDiff(a, b), 0.05, "overlay \(kind.rawValue) does not move")
        }
    }

    func testCombinedProjectLoopsSeamlessly() {
        var p = flowProject()
        p.livingEffects = [LivingEffect(kind: .windSway, strength: 0.6), LivingEffect(kind: .shimmer, strength: 0.4)]
        p.overlays = [OverlayLayer(kind: .snow, intensity: 0.7, seed: 2), OverlayLayer(kind: .sparkles, intensity: 0.5, seed: 4)]
        p.camera = CameraMotion(kind: .drift, amount: 0.6)
        p.parallax = ParallaxSettings(enabled: true, depthSource: .gradient, style: .swing, strength: 0.5, edgeFill: .mirror, invertDepth: false)
        p.look = Look(filter: .cinema, intensity: 70, adjust: LookAdjust(vignette: 0.3), animatedGrain: false, flicker: Flicker(amount: 0, speed: 1))
        assertSeamless(p, label: "combined", longEdge: 128)
    }

    func testGrainAndFlickerWrapAtTheLoopEnd() {
        var p = Fixture.project()
        p.look = Look(filter: .original, intensity: 100, adjust: LookAdjust(grain: 0.7), animatedGrain: true, flicker: Flicker(amount: 0.5, speed: 1))
        let engine = Fixture.engine(p)
        let a = Fixture.bytes(engine, time: 0), b = Fixture.bytes(engine, time: p.loop.clampedDuration), c = Fixture.bytes(engine, time: 0.5)
        XCTAssertEqual(Fixture.meanDiff(a, b), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(Fixture.meanDiff(a, c), 0.05, "animated grain should change from frame to frame")
        var still = p
        still.look.animatedGrain = false
        still.look.flicker = Flicker()
        let calm = Fixture.engine(still)
        XCTAssertEqual(Fixture.meanDiff(Fixture.bytes(calm, time: 0), Fixture.bytes(calm, time: 0.5)), 0, accuracy: 0.0001)
    }

    // MARK: Masks and anchors

    func testFlowLeavesPixelsOutsideTheMaskUntouched() {
        let base = Fixture.project()
        var p = base
        p.flowRegions = [FlowRegion(name: "Corner", strokes: [BrushStroke(points: [NPoint(0.18, 0.3), NPoint(0.3, 0.3)], radius: 0.05, feather: 0.4)],
                                    arrows: [FlowArrow(from: NPoint(0.2, 0.3), to: NPoint(0.3, 0.5))], speed: 1, strength: 0.9, softness: 0.3)]
        let still = Fixture.engine(base), moving = Fixture.engine(p)
        let w = RenderEngine.canvasSize(for: p, longEdge: 96).width
        var changedInside = 0.0
        for time in [0.0, 0.4, 0.9, 1.4] {
            let a = Fixture.bytes(still, time: time), b = Fixture.bytes(moving, time: time)
            // The painted area is in the top-left; the right 45% and the bottom 40% of the frame are far outside it.
            let h = a.count / 4 / w
            let worst = Fixture.maxDiff(a, b, width: w) { x, y in Double(x) >= Double(w) * 0.55 || Double(y) >= Double(h) * 0.6 }
            XCTAssertLessThanOrEqual(worst, 1, "pixels outside the flow mask changed at \(time) s")
            changedInside += Fixture.meanDiff(a, b)
        }
        XCTAssertGreaterThan(changedInside, 0.05, "the flow region did not move anything")
    }

    func testLivingEffectBrushLeavesOutsideUntouched() {
        let base = Fixture.project()
        var p = base
        p.livingEffects = [LivingEffect(kind: .ripple, strength: 1, speed: 1, scale: 1, angle: 0, center: NPoint(0.2, 0.2), gradient: nil,
                                        brush: [BrushStroke(points: [NPoint(0.15, 0.2), NPoint(0.25, 0.2)], radius: 0.05, feather: 0.4)])]
        let still = Fixture.engine(base), moving = Fixture.engine(p)
        let w = RenderEngine.canvasSize(for: p, longEdge: 96).width
        let a = Fixture.bytes(still, time: 0.5), b = Fixture.bytes(moving, time: 0.5)
        let h = a.count / 4 / w
        let worst = Fixture.maxDiff(a, b, width: w) { x, y in Double(x) >= Double(w) * 0.55 || Double(y) >= Double(h) * 0.6 }
        XCTAssertLessThanOrEqual(worst, 1)
        XCTAssertGreaterThan(Fixture.meanDiff(a, b), 0.0)
    }

    func testAnchorsHoldWhileEverythingElseMoves() {
        let base = Fixture.project()
        var p = flowProject(strength: 1)
        p.livingEffects = [LivingEffect(kind: .wiggle, strength: 0.9)]
        p.anchors = [BrushStroke(points: [NPoint(0.5, 0.5)], radius: 0.16, feather: 0.2)]
        let still = Fixture.engine(base), moving = Fixture.engine(p)
        let size = RenderEngine.canvasSize(for: p, longEdge: 96)
        let w = size.width, h = size.height
        var movedElsewhere = 0.0
        for time in [0.3, 0.8, 1.3] {
            let a = Fixture.bytes(still, time: time), b = Fixture.bytes(moving, time: time)
            let cx = Double(w) / 2, cy = Double(h) / 2
            let core = 0.16 * Double(max(w, h)) * 0.5
            let worst = Fixture.maxDiff(a, b, width: w) { x, y in hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) <= core }
            XCTAssertLessThanOrEqual(worst, 2, "the anchored core moved at \(time) s")
            movedElsewhere += Fixture.meanDiff(a, b, where: { x, y in hypot(Double(x) - cx, Double(y) - cy) > core * 3 }, width: w)
        }
        XCTAssertGreaterThan(movedElsewhere, 0.05, "nothing moved outside the anchor")
    }

    func testAnEmptyProjectShowsThePhotoUnchanged() {
        let p = Fixture.project()
        let engine = Fixture.engine(p)
        let rendered = Fixture.bytes(engine, time: 0.7, longEdge: 120)
        guard let original = engine.originalFrame(quality: RenderQuality(longEdge: 120)) else { return XCTFail("no original frame") }
        XCTAssertLessThanOrEqual(Fixture.meanDiff(rendered, Fixture.rgba(original)), 1.0)
        XCTAssertEqual(rendered.count, Fixture.rgba(original).count)
    }

    func testRenderSizeFollowsTheCanvasAspect() {
        var p = Fixture.project()
        let engine = Fixture.engine(p)
        for aspect in CanvasAspect.allCases {
            p.canvas.aspect = aspect
            engine.update(project: p)
            let expected = engine.canvasSize(longEdge: 80)
            let image = Fixture.render(engine, time: 0, longEdge: 80)
            XCTAssertEqual(image.width, expected.width, "\(aspect.rawValue)")
            XCTAssertEqual(image.height, expected.height, "\(aspect.rawValue)")
            XCTAssertEqual(max(image.width, image.height), 80, "\(aspect.rawValue)")
        }
    }

    func testFitModeKeepsThePhotoAndFillsTheRest() {
        var p = Fixture.project()
        p.canvas.aspect = .story916
        p.canvas.fit = .fit
        p.canvas.background = .color
        p.canvas.backgroundColor = RGBAColor(1, 0, 0)
        let engine = Fixture.engine(p)
        let image = Fixture.render(engine, time: 0, longEdge: 96)
        let bytes = Fixture.rgba(image)
        // The photo is wider than the story canvas, so the top row is background red.
        XCTAssertGreaterThan(Int(bytes[0]), 200)
        XCTAssertLessThan(Int(bytes[1]), 60)
        XCTAssertLessThan(Int(bytes[2]), 60)
    }

    // MARK: Determinism

    func testOverlaysAreDeterministicForASeed() {
        let kinds: [OverlayKind] = [.rain, .heavyRain, .snow, .blizzard, .leaves, .petals, .fireflies, .sparkles, .bokeh, .dust, .embers,
                                    .stars, .confetti, .hearts, .bubbles, .fog, .lensFlare, .lightLeaks, .shootingStars, .fireworks]
        for kind in kinds {
            var p = Fixture.project()
            p.overlays = [OverlayLayer(kind: kind, intensity: 0.8, speed: 1, size: 1.5, seed: 11)]
            let first = Fixture.bytes(Fixture.engine(p), time: 0.37, longEdge: 128)
            let second = Fixture.bytes(Fixture.engine(p), time: 0.37, longEdge: 128)
            XCTAssertEqual(first, second, "overlay \(kind.rawValue) is not repeatable")
        }
    }

    func testDifferentSeedsGiveDifferentOverlays() {
        for kind in [OverlayKind.rain, .snow, .leaves, .petals, .fireflies, .sparkles, .bokeh, .dust, .embers, .stars, .confetti, .hearts, .bubbles] {
            var a = Fixture.project(), b = Fixture.project()
            a.overlays = [OverlayLayer(kind: kind, intensity: 0.8, speed: 1, size: 1.5, seed: 1)]
            b.overlays = [OverlayLayer(kind: kind, intensity: 0.8, speed: 1, size: 1.5, seed: 2)]
            let fa = Fixture.bytes(Fixture.engine(a), time: 0.37, longEdge: 128), fb = Fixture.bytes(Fixture.engine(b), time: 0.37, longEdge: 128)
            XCTAssertGreaterThan(Fixture.meanDiff(fa, fb), 0.01, "seed has no effect on \(kind.rawValue)")
        }
    }

    func testRenderingIsRepeatableAcrossEngines() {
        var p = flowProject()
        p.livingEffects = [LivingEffect(kind: .waves, strength: 0.5)]
        p.camera = CameraMotion(kind: .zoomIn, amount: 0.5)
        p.overlays = [OverlayLayer(kind: .dust, intensity: 0.5, seed: 9)]
        let one = Fixture.bytes(Fixture.engine(p), time: 0.61)
        let two = Fixture.bytes(Fixture.engine(p), time: 0.61)
        XCTAssertEqual(one, two)
    }

    // MARK: Camera, parallax, looks, layers

    func testCameraNoneIsTheIdentityAndZoomChangesPixels() {
        let base = Fixture.project()
        var zoom = base
        zoom.camera = CameraMotion(kind: .zoomIn, amount: 0.8, easing: .linear, loops: true)
        let a = Fixture.bytes(Fixture.engine(base), time: 0.5), b = Fixture.bytes(Fixture.engine(zoom), time: 0.5)
        XCTAssertGreaterThan(Fixture.meanDiff(a, b), 1.0)
        let again = Fixture.bytes(Fixture.engine(base), time: 1.1)
        XCTAssertEqual(Fixture.meanDiff(a, again), 0, accuracy: 0.0001)
    }

    func testParallaxUsesTheSubjectMaskWhenThereIsOne() {
        var p = Fixture.project()
        p.parallax = ParallaxSettings(enabled: true, depthSource: .subjectMask, style: .orbit, strength: 0.9, edgeFill: .blur, invertDepth: false)
        let noSubject = Fixture.engine(p)
        XCTAssertEqual(noSubject.effectiveDepthSource, .gradient, "without a subject mask the engine falls back to the gradient")
        var bytes = [UInt8](repeating: 0, count: 40 * 30)
        for y in 8..<24 { for x in 12..<28 { bytes[y * 40 + x] = 255 } }
        let mask = MaskBuffer(width: 40, height: 30, data: bytes)
        let withSubject = Fixture.engine(p, subject: mask)
        XCTAssertEqual(withSubject.effectiveDepthSource, .subjectMask)
        let a = Fixture.bytes(noSubject, time: 0.5), b = Fixture.bytes(withSubject, time: 0.5)
        XCTAssertGreaterThan(Fixture.meanDiff(a, b), 0.05)
        assertSeamless(p, label: "parallax subject mask", subject: mask)
    }

    func testLooksChangeThePicture() {
        let base = Fixture.project()
        let plain = Fixture.bytes(Fixture.engine(base), time: 0)
        var original = base
        original.look = Look(filter: .original, intensity: 100)
        original.look.animatedGrain = false
        XCTAssertEqual(Fixture.meanDiff(plain, Fixture.bytes(Fixture.engine(original), time: 0)), 0, accuracy: 0.0001)
        for filter in [LookID.cinema, .amber, .vivid, .faded, .nocturne] {
            var p = base
            p.look = Look(filter: filter, intensity: 100)
            p.look.animatedGrain = false
            XCTAssertGreaterThan(Fixture.meanDiff(plain, Fixture.bytes(Fixture.engine(p), time: 0)), 0.5, "look \(filter.rawValue) changed nothing")
        }
        var mono = base
        mono.look = Look(filter: .mono, intensity: 100)
        mono.look.animatedGrain = false
        let m = Fixture.bytes(Fixture.engine(mono), time: 0)
        var spread = 0.0
        for p in 0..<(m.count / 4) { spread += Double(abs(Int(m[p * 4]) - Int(m[p * 4 + 2]))) }
        XCTAssertLessThan(spread / Double(m.count / 4), 12, "a black and white look should leave little colour")
    }

    func testAdjustDialsAffectBrightness() {
        let base = Fixture.project()
        func average(_ bytes: [UInt8]) -> Double {
            var s = 0.0
            for p in 0..<(bytes.count / 4) { s += Double(bytes[p * 4]) + Double(bytes[p * 4 + 1]) + Double(bytes[p * 4 + 2]) }
            return s / Double(bytes.count / 4 * 3)
        }
        var up = base, down = base
        up.look.adjust.exposure = 0.6
        down.look.adjust.exposure = -0.6
        let a = average(Fixture.bytes(Fixture.engine(up), time: 0)), b = average(Fixture.bytes(Fixture.engine(base), time: 0)), c = average(Fixture.bytes(Fixture.engine(down), time: 0))
        XCTAssertGreaterThan(a, b + 3)
        XCTAssertLessThan(c, b - 3)
    }

    func testTextAndStickersAreDrawn() {
        let base = Fixture.project()
        var text = base
        var layer = TextLayer(text: "LOOP")
        layer.size = 0.3
        layer.color = RGBAColor(1, 1, 1)
        layer.entrance = LayerAnimation(kind: .none, duration: 0.2)
        text.texts = [layer]
        let plain = Fixture.bytes(Fixture.engine(base), time: 0.5, longEdge: 160)
        let withText = Fixture.bytes(Fixture.engine(text), time: 0.5, longEdge: 160)
        XCTAssertGreaterThan(Fixture.meanDiff(plain, withText), 0.2, "text was not drawn")
        var sticker = base
        var s = StickerLayer(emoji: "A")
        s.size = 0.4
        s.entrance = LayerAnimation(kind: .none, duration: 0.2)
        sticker.stickers = [s]
        let withSticker = Fixture.bytes(Fixture.engine(sticker), time: 0.5, longEdge: 160)
        XCTAssertGreaterThan(Fixture.meanDiff(plain, withSticker), 0.1, "sticker was not drawn")
        // A text that enters later is not there at the start.
        var late = layer
        late.startTime = 1.5
        late.entrance = LayerAnimation(kind: .none, duration: 0.2)
        var delayed = base
        delayed.texts = [late]
        let early = Fixture.bytes(Fixture.engine(delayed), time: 0.2, longEdge: 160)
        XCTAssertEqual(Fixture.meanDiff(plain, early), 0, accuracy: 0.0001)
    }

    func testCancelledRenderReturnsNil() {
        let engine = Fixture.engine(flowProject())
        let token = RenderToken()
        token.cancel()
        XCTAssertNil(engine.renderFrame(time: 0, quality: RenderQuality(longEdge: 96), token: token))
        XCTAssertNotNil(engine.renderFrame(time: 0, quality: RenderQuality(longEdge: 96)))
    }

    func testUpdatingTheProjectChangesTheNextFrame() {
        var p = Fixture.project()
        let engine = Fixture.engine(p)
        let before = Fixture.bytes(engine, time: 0.5)
        p.overlays = [OverlayLayer(kind: .snow, intensity: 0.9, seed: 1)]
        engine.update(project: p)
        let after = Fixture.bytes(engine, time: 0.5)
        XCTAssertGreaterThan(Fixture.meanDiff(before, after), 0.05)
    }

    // MARK: Presets

    func testEveryPresetRendersAtSmallSize() {
        XCTAssertGreaterThanOrEqual(PresetLibrary.all.count, 12)
        XCTAssertEqual(Set(PresetLibrary.all.map(\.id)).count, PresetLibrary.all.count, "preset ids must be unique")
        for info in PresetLibrary.all {
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertFalse(info.summary.isEmpty)
            XCTAssertFalse(info.symbol.isEmpty)
            let base = Fixture.project(title: "Keep me")
            let applied = PresetLibrary.apply(info.id, to: base)
            XCTAssertEqual(applied.presetID, info.id)
            XCTAssertEqual(applied.title, "Keep me")
            XCTAssertEqual(applied.source, base.source)
            XCTAssertEqual(applied.canvas, base.canvas)
            XCTAssertNotEqual(applied, base, "preset \(info.id) changed nothing")
            let engine = Fixture.engine(applied)
            for time in [0.0, 0.7] {
                let image = engine.renderFrame(time: time, quality: RenderQuality(longEdge: 64))
                XCTAssertNotNil(image, "preset \(info.id) failed to render at \(time) s")
                if let image {
                    let expected = engine.canvasSize(longEdge: 64)
                    XCTAssertEqual(image.width, expected.width)
                    XCTAssertEqual(image.height, expected.height)
                }
            }
        }
    }

    func testPresetsAnimateAndLoop() {
        for info in PresetLibrary.all {
            var p = PresetLibrary.apply(info.id, to: Fixture.project())
            p.look.animatedGrain = false
            p.look.flicker = Flicker()
            p.loop.fps = Fixture.fps
            p.loop.duration = Fixture.duration
            assertSeamless(p, label: "preset \(info.id)", longEdge: 80)
        }
    }

    func testApplyingAPresetTwiceOrOverAnotherLeavesNoResidue() {
        let base = Fixture.project()
        let a = PresetLibrary.apply("rainy-window", to: base)
        let b = PresetLibrary.apply("rainy-window", to: PresetLibrary.apply("snow-globe", to: base))
        XCTAssertEqual(a.overlays.map(\.kind), b.overlays.map(\.kind))
        XCTAssertEqual(a.livingEffects.map(\.kind), b.livingEffects.map(\.kind))
        XCTAssertEqual(a.look, b.look)
        XCTAssertEqual(PresetLibrary.apply("no-such-preset", to: base), base)
        XCTAssertNil(PresetLibrary.info(for: "no-such-preset"))
    }

    func testPresetsKeepTextAndAudio() {
        var base = Fixture.project()
        base.texts = [TextLayer(text: "Hello")]
        base.stickers = [StickerLayer(emoji: "A")]
        base.audio = AudioTrackSpec(fileName: "audio.m4a", displayName: "Song")
        let applied = PresetLibrary.apply("dream-sparkle", to: base)
        XCTAssertEqual(applied.texts, base.texts)
        XCTAssertEqual(applied.stickers, base.stickers)
        XCTAssertEqual(applied.audio, base.audio)
    }

    // MARK: Performance

    func testPreviewFrameStaysWithinAGenerousBudget() {
        let photo = Fixture.photo(width: 512, height: 384)
        var p = PresetLibrary.apply("waterfall", to: Fixture.project(width: 512, height: 384))
        p.overlays.append(OverlayLayer(kind: .snow, intensity: 0.6, seed: 3))
        p.camera = CameraMotion(kind: .drift, amount: 0.5)
        let engine = RenderEngine(project: p, assets: SourceAssets(still: photo))
        let cold = Date()
        XCTAssertNotNil(engine.renderFrame(time: 0, quality: .draft))
        let coldSeconds = Date().timeIntervalSince(cold)
        let warm = Date()
        for i in 1...3 { XCTAssertNotNil(engine.renderFrame(time: Double(i) * 0.1, quality: .draft)) }
        let warmSeconds = Date().timeIntervalSince(warm) / 3
        // Generous: tests run without compiler optimisation on a shared CI machine, a release build is many times faster.
        XCTAssertLessThan(coldSeconds, 20, "first preview frame took \(coldSeconds) s")
        XCTAssertLessThan(warmSeconds, 8, "a warm preview frame took \(warmSeconds) s")
    }

    func testFramesAreRenderedOffTheMainThread() async {
        let engine = Fixture.engine(flowProject())
        let image = await engine.renderFrameAsync(time: 0.2, quality: RenderQuality(longEdge: 64))
        XCTAssertNotNil(image)
    }
}
