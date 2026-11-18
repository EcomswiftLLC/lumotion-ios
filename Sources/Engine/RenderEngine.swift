import Foundation
import CoreGraphics
import QuartzCore

private struct Boxed<T> {
    var value: T?
}

private func combine(_ values: Int...) -> Int {
    var hasher = Hasher()
    for v in values { hasher.combine(v) }
    return hasher.finalize()
}

/// Turns a `Project` plus `SourceAssets` into frames. One code path serves the live preview, the exporter and the tests.
/// Thread safe: `update(project:)` may be called from the main thread while another thread renders; a render uses the
/// project that was current when it started. Rendering is CPU only and deterministic: the same project and time always
/// give the same pixels, and the frame at the end of the loop equals the frame at its start.
final class RenderEngine {
    private struct Digests {
        var canvas = 0
        var look = 0
        var anchors = 0
        var depth = 0
        var cinemaMask = 0
        var cinemaStill = 0
        var cinemaSegment = 0
        var flows: [Int] = []
        var brushes: [Int] = []
    }

    private struct Snapshot {
        let project: Project
        let assets: SourceAssets
        let version: Int
        let digests: Digests
    }

    private let lock = NSLock()
    private var snap: Snapshot
    private var version = 0
    private let memo = Memo(budgetBytes: 700 * 1024 * 1024)
    private var adaptiveEdge = 720
    private var smoothedMs: Double = 0

    init(project: Project, assets: SourceAssets) {
        snap = RenderEngine.makeSnapshot(project, assets, version: 0)
    }

    private static func makeSnapshot(_ p: Project, _ a: SourceAssets, version: Int) -> Snapshot {
        var d = Digests()
        d.canvas = combine(digest(p.canvas), p.source.pixelWidth, p.source.pixelHeight, p.source.kind == .video ? 1 : 0)
        d.look = combine(digest(p.look.filter), digest(p.look.intensity), digest(p.look.adjust))
        d.anchors = digest(p.anchors)
        d.depth = combine(digest(p.parallax.depthSource), digest(p.parallax.depthStrokes), digest(p.parallax.invertDepth))
        d.flows = p.flowRegions.map { combine(digest($0.strokes), digest($0.arrows), digest($0.softness)) }
        d.brushes = p.livingEffects.map { digest($0.brush) }
        d.cinemaMask = digest(p.cinemagraph.maskStrokes)
        d.cinemaStill = digest(p.cinemagraph.stillTime)
        d.cinemaSegment = combine(digest(p.cinemagraph.segmentStart), digest(p.cinemagraph.segmentLength))
        return Snapshot(project: p, assets: a, version: version, digests: d)
    }

    // MARK: Public state

    /// The project the engine is currently rendering.
    var project: Project {
        lock.lock(); defer { lock.unlock() }
        return snap.project
    }

    /// The assets the engine is currently using.
    var assets: SourceAssets {
        lock.lock(); defer { lock.unlock() }
        return snap.assets
    }

    /// Swaps in an edited project. Cheap: cached work is reused for everything that did not change.
    func update(project: Project) {
        lock.lock()
        snap = RenderEngine.makeSnapshot(project, snap.assets, version: version)
        lock.unlock()
    }

    /// Swaps in new assets, for example when the subject mask finishes computing in the background.
    func update(assets: SourceAssets) {
        lock.lock()
        version += 1
        snap = RenderEngine.makeSnapshot(snap.project, assets, version: version)
        lock.unlock()
        memo.removeAll()
    }

    /// Frees cached pictures and masks (call on memory warnings).
    func clearCaches() { memo.removeAll() }

    /// The long edge the adaptive preview currently renders at (360...720).
    var previewLongEdge: Int {
        lock.lock(); defer { lock.unlock() }
        return adaptiveEdge
    }

    private func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snap
    }

    // MARK: Size

    /// Canvas size in pixels for a long edge, from the project's aspect ratio. Both sides are even numbers.
    func canvasSize(longEdge: Int) -> (width: Int, height: Int) {
        RenderEngine.canvasSize(for: project, longEdge: longEdge)
    }

    /// Canvas size in pixels for a project and a long edge. Both sides are even numbers.
    static func canvasSize(for project: Project, longEdge: Int) -> (width: Int, height: Int) {
        let ratio = project.canvas.aspect.ratio(sourceAspect: project.source.aspect)
        let long = Double(max(16, longEdge))
        var w: Double, h: Double
        if ratio >= 1 { w = long; h = long / ratio } else { h = long; w = long * ratio }
        w = max(2, (w / 2).rounded() * 2)
        h = max(2, (h / 2).rounded() * 2)
        return (Int(w), Int(h))
    }

    /// The depth source the engine will really use for parallax (it falls back to the gradient when, for example, no subject mask exists).
    var effectiveDepthSource: DepthSource {
        let s = current()
        return DepthBuilder.effectiveSource(s.project.parallax, subject: s.assets.subjectMask, embedded: s.assets.embeddedDepth)
    }

    // MARK: Public rendering

    /// Renders the frame at `time` seconds (any time; it wraps around the loop). Blocks, so call it off the main thread.
    /// Returns nil when cancelled through `token` or when no source picture is available.
    func renderFrame(time: Double, quality: RenderQuality = .preview, token: RenderToken? = nil) -> CGImage? {
        renderBuffer(time: time, quality: quality, token: token)?.makeCGImage()
    }

    /// Like `renderFrame`, but picks the resolution itself: it starts at `RenderQuality.preview` and steps down towards
    /// `RenderQuality.draft` when frames take too long to keep up with 30 fps, and back up when there is headroom.
    func previewFrame(time: Double, token: RenderToken? = nil) -> CGImage? {
        let edge = previewLongEdge
        let start = CACurrentMediaTime()
        let image = renderBuffer(time: time, quality: RenderQuality(longEdge: edge), token: token)?.makeCGImage()
        let ms = (CACurrentMediaTime() - start) * 1000
        if image != nil {
            lock.lock()
            smoothedMs = smoothedMs == 0 ? ms : smoothedMs * 0.7 + ms * 0.3
            if smoothedMs > 38 && adaptiveEdge > 360 {
                adaptiveEdge = max(360, (Int(Double(adaptiveEdge) * 0.85) / 8) * 8)
                smoothedMs = 0
            } else if smoothedMs < 14 && adaptiveEdge < 720 {
                adaptiveEdge = min(720, (Int(Double(adaptiveEdge) * 1.15) / 8) * 8 + 8)
                smoothedMs = 0
            }
            lock.unlock()
        }
        return image
    }

    /// The canvas-framed source with no effects and no look, for the "compare with original" button.
    func originalFrame(quality: RenderQuality = .preview) -> CGImage? {
        let s = current()
        let size = RenderEngine.canvasSize(for: s.project, longEdge: quality.longEdge)
        let buffer: PixelBuffer? = s.project.source.kind == .video
            ? cinemaStill(s, size.width, size.height)
            : canvasBase(s, size.width, size.height)
        return buffer?.makeCGImage()
    }

    /// Async wrapper that renders on a background queue. Cancelling the calling task cancels the render.
    func renderFrameAsync(time: Double, quality: RenderQuality = .preview) async -> CGImage? {
        let token = RenderToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.renderFrame(time: time, quality: quality, token: token))
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Builds the caches for a quality level (decoding the cinemagraph segment, masks, look) so the first preview frame is fast.
    func prepare(quality: RenderQuality = .preview, token: RenderToken? = nil) {
        _ = renderBuffer(time: 0, quality: quality, token: token)
    }

    // MARK: Components

    private func canvasBase(_ s: Snapshot, _ w: Int, _ h: Int) -> PixelBuffer? {
        guard let still = s.assets.still else { return nil }
        let key = MemoKey(tag: "base", a: s.version, b: s.digests.canvas, w: w, h: h)
        let buffer: PixelBuffer = memo.get(key, cost: { $0.byteCount }) {
            CanvasCompose.compose(image: still, canvas: s.project.canvas, sourceAspect: s.project.source.aspect, width: w, height: h)
                ?? PixelBuffer(width: w, height: h)
        }
        return buffer
    }

    private func looked(_ s: Snapshot, base: PixelBuffer, _ w: Int, _ h: Int) -> PixelBuffer {
        if s.project.look.isNeutralForColor { return base }
        let key = MemoKey(tag: "look", a: s.version, b: combine(s.digests.canvas, s.digests.look), w: w, h: h)
        return memo.get(key, cost: { $0.byteCount }) { LookProcessor.apply(s.project.look, to: base) }
    }

    private func cinemaStill(_ s: Snapshot, _ w: Int, _ h: Int) -> PixelBuffer? {
        guard let url = s.assets.videoURL else { return nil }
        let key = MemoKey(tag: "cinestill", a: combine(s.version, s.digests.cinemaStill), b: s.digests.canvas, w: w, h: h)
        let buffer: PixelBuffer = memo.get(key, cost: { $0.byteCount }) {
            let maxPixel = min(3840, max(w, h) * 2)
            guard let image = VideoFrameStore.still(url: url, at: s.project.cinemagraph.stillTime, maxPixel: maxPixel) else {
                return PixelBuffer(width: w, height: h)
            }
            return CanvasCompose.compose(image: image, canvas: s.project.canvas, sourceAspect: s.project.source.aspect, width: w, height: h)
                ?? PixelBuffer(width: w, height: h)
        }
        return buffer
    }

    private func frameStore(_ s: Snapshot, longEdge: Int, token: RenderToken?) -> VideoFrameStore? {
        guard let url = s.assets.videoURL else { return nil }
        let edge = min(max(longEdge, 480), 1280)
        let key = MemoKey(tag: "cinestore", a: combine(s.version, s.digests.cinemaSegment), b: 0, w: edge, h: 0)
        let box: Boxed<VideoFrameStore> = memo.get(key, cost: { $0.value?.byteCost ?? 16 }) {
            Boxed(value: VideoFrameStore.extract(url: url, start: s.project.cinemagraph.segmentStart, length: s.project.cinemagraph.segmentLength,
                                                 maxLongEdge: edge, budgetBytes: 150 * 1024 * 1024, token: token))
        }
        return box.value
    }

    private func cinemaMask(_ s: Snapshot, _ w: Int, _ h: Int) -> FloatField {
        let key = MemoKey(tag: "cinemask", a: s.digests.cinemaMask, b: s.digests.canvas, w: w, h: h)
        return memo.get(key, cost: { $0.byteCost }) {
            let mapping = CanvasMapping(project: s.project)
            let src = StrokeRaster.size(aspect: s.project.source.aspect, longEdge: 768)
            let work = StrokeRaster.size(aspect: Double(w) / Double(max(1, h)), longEdge: 384)
            let strokes = s.project.cinemagraph.maskStrokes
            // Nothing painted yet: the whole picture plays.
            let painted = StrokeRaster.paintMask(strokes, width: src.width, height: src.height) ?? MaskBuffer(width: src.width, height: src.height, value: 255)
            return FloatField(mask: StrokeRaster.toCanvas(painted, mapping: mapping, width: work.width, height: work.height))
        }
    }

    private func flowField(_ s: Snapshot, _ index: Int, _ w: Int, _ h: Int) -> FlowField? {
        let region = s.project.flowRegions[index]
        let key = MemoKey(tag: "flow", a: s.digests.flows[index], b: s.digests.canvas, w: w, h: h)
        let box: Boxed<FlowField> = memo.get(key, cost: { $0.value?.byteCost ?? 16 }) {
            Boxed(value: FlowField.bake(region: region, mapping: CanvasMapping(project: s.project), sourceAspect: s.project.source.aspect, canvasW: w, canvasH: h))
        }
        return box.value
    }

    private func strokeField(_ strokes: [BrushStroke], digest d: Int, _ s: Snapshot, tag: String, _ w: Int, _ h: Int) -> FloatField? {
        if strokes.isEmpty { return nil }
        let key = MemoKey(tag: tag, a: d, b: s.digests.canvas, w: w, h: h)
        let box: Boxed<FloatField> = memo.get(key, cost: { $0.value?.byteCost ?? 16 }) {
            let src = StrokeRaster.size(aspect: s.project.source.aspect, longEdge: 768)
            guard let painted = StrokeRaster.paintMask(strokes, width: src.width, height: src.height, featherBoost: 0.1) else { return Boxed(value: nil) }
            let work = StrokeRaster.size(aspect: Double(w) / Double(max(1, h)), longEdge: 384)
            let canvasMask = StrokeRaster.toCanvas(painted, mapping: CanvasMapping(project: s.project), width: work.width, height: work.height)
            return Boxed(value: FloatField(mask: canvasMask))
        }
        return box.value
    }

    private func subjectField(_ s: Snapshot, _ w: Int, _ h: Int) -> FloatField? {
        guard let subject = s.assets.subjectMask else { return nil }
        let key = MemoKey(tag: "subject", a: s.version, b: s.digests.canvas, w: w, h: h)
        let field: FloatField = memo.get(key, cost: { $0.byteCost }) {
            let work = StrokeRaster.size(aspect: Double(w) / Double(max(1, h)), longEdge: 384)
            let canvas = StrokeRaster.toCanvas(subject, mapping: CanvasMapping(project: s.project), width: work.width, height: work.height)
            return FloatField(mask: StrokeRaster.blur(canvas, radius: max(1, work.width / 96), passes: 1))
        }
        return field
    }

    private func depthField(_ s: Snapshot, _ w: Int, _ h: Int) -> FloatField {
        let key = MemoKey(tag: "depth", a: combine(s.version, s.digests.depth), b: s.digests.canvas, w: w, h: h)
        return memo.get(key, cost: { $0.byteCost }) {
            DepthBuilder.build(settings: s.project.parallax, subject: s.assets.subjectMask, embedded: s.assets.embeddedDepth,
                               mapping: CanvasMapping(project: s.project), sourceAspect: s.project.source.aspect, canvasW: w, canvasH: h)
        }
    }

    // MARK: Timing helpers

    /// Whole cycles and the leftover scale for effects that move a fixed distance per cycle (flow).
    private static func flowCycles(speed: Double, loop: LoopSpec) -> (k: Int, scale: Double) {
        let real = max(0.02, min(max(speed, 0.1), 3)) * min(max(loop.speed, 0.25), 4) * 0.35 * loop.clampedDuration
        let k = max(1, Int(real.rounded(.down)))
        return (k, real / Double(k))
    }

    private static func livingHz(_ kind: LivingEffectKind) -> Double {
        switch kind {
        case .ripple: return 0.5
        case .waves: return 0.5
        case .windSway: return 0.4
        case .heatHaze: return 0.8
        case .shimmer: return 0.6
        case .pulse: return 0.35
        case .lightSweep: return 0.25
        case .glitch: return 0.3
        case .wobble: return 0.4
        case .wiggle: return 0.5
        case .swirl: return 0.25
        }
    }

    private static func livingCycles(_ e: LivingEffect, loop: LoopSpec) -> Int {
        let real = min(max(e.speed, 0.1), 3) * min(max(loop.speed, 0.25), 4) * livingHz(e.kind) * loop.clampedDuration
        return max(1, Int(real.rounded()))
    }

    // MARK: The frame

    /// The picture every effect starts from at `time`: the looked photo, or for a cinemagraph the frozen frame with the
    /// live part from the video laid over it.
    private func sourceFrame(_ s: Snapshot, time: Double, _ w: Int, _ h: Int, quality: RenderQuality, token: RenderToken?) -> PixelBuffer? {
        if s.project.source.kind == .still {
            guard let base = canvasBase(s, w, h) else { return nil }
            return looked(s, base: base, w, h)
        }
        guard let still = cinemaStill(s, w, h), let store = frameStore(s, longEdge: quality.longEdge, token: token) else { return nil }
        let loop = s.project.loop
        let cine = s.project.cinemagraph
        var u = time / loop.clampedDuration
        u -= u.rounded(.down)
        if loop.reverse { u = 1 - u }
        let length = store.length
        var raw: PixelBuffer
        if loop.mode == .pingPong || cine.pingPong {
            let tri = 1 - abs(2 * u - 1)
            raw = store.frame(at: tri * length)
        } else {
            let fade = min(cine.crossfade, length * 0.5)
            let loopLength = max(0.1, length - fade)
            let t = u * loopLength
            raw = store.frame(at: t)
            if fade > 0 && t < fade {
                let a = Float(smoothstep(0, 1, Float(t / fade)))
                raw = VideoFrameStore.mix(store.frame(at: length - fade + t), raw, a)
            }
        }
        let live = CanvasCompose.resample(raw, mapping: CanvasMapping(project: s.project), width: w, height: h)
        let composite = still.clone()
        PixelOps.blend(composite, with: live, mask: cinemaMask(s, w, h))
        if s.project.look.isNeutralForColor { return composite }
        return LookProcessor.apply(s.project.look, to: composite)
    }

    /// Renders one frame into a pixel buffer. Used by the preview, the exporter and the tests.
    func renderBuffer(time: Double, quality: RenderQuality, token: RenderToken?) -> PixelBuffer? {
        let s = current()
        let project = s.project
        let size = RenderEngine.canvasSize(for: project, longEdge: quality.longEdge)
        let w = size.width, h = size.height
        let loop = project.loop
        let p = loop.phase(at: time)
        func cancelled() -> Bool { token?.isCancelled == true }

        guard let base = sourceFrame(s, time: time, w, h, quality: quality, token: token) else { return nil }
        if cancelled() { return nil }
        let cur = base.clone()
        var scratch: PixelBuffer?

        // 1. Flow regions
        for (i, region) in project.flowRegions.enumerated() where region.enabled && region.isPainted && region.hasDirection {
            guard let field = flowField(s, i, w, h) else { continue }
            let c = RenderEngine.flowCycles(speed: region.speed, loop: loop)
            FlowApply.apply(field: field, region: region, src: base, dst: cur, phase: p, cycles: c.k, cycleScale: c.scale)
            if cancelled() { return nil }
        }

        // 2. Living effects
        for (i, effect) in project.livingEffects.enumerated() where effect.enabled && effect.strength > 0 {
            if scratch == nil { scratch = PixelBuffer(width: w, height: h) }
            guard let tmp = scratch else { break }
            tmp.copy(from: cur)
            let brush = strokeField(effect.brush, digest: s.digests.brushes[i], s, tag: "lbrush", w, h)
            LivingFX.apply(effect, brush: brush, src: tmp, dst: cur, phase: p, cycles: RenderEngine.livingCycles(effect, loop: loop))
            if cancelled() { return nil }
        }

        // 3. Anchors hold their original pixels
        if !project.anchors.isEmpty, let anchor = strokeField(project.anchors, digest: s.digests.anchors, s, tag: "anchor", w, h) {
            PixelOps.blend(cur, with: base, mask: anchor)
        }

        // 4. Camera and parallax
        let aspect = Double(max(w, h)) / Double(max(1, min(w, h)))
        let pose = CameraMath.pose(project.camera, phase: p, frameAspect: aspect)
        let parallaxOn = project.parallax.enabled
        let depth: FloatField? = parallaxOn ? depthField(s, w, h) : nil
        let map = GeometryMap(width: w, height: h, pose: pose, parallax: project.parallax, depth: depth, phase: p)
        var frame = cur
        if !map.isIdentity {
            frame = GeometryStage.render(cur, map: map, edge: parallaxOn ? project.parallax.edgeFill : .stretch)
        }
        if cancelled() { return nil }

        // 5. Overlays
        if project.overlays.contains(where: { $0.enabled && $0.intensity > 0 }) {
            let layers = OverlayRenderer.draw(overlays: project.overlays, loop: loop, phase: p, width: w, height: h)
            var holdout: FloatField?
            if layers.hasUnder, let subject = subjectField(s, w, h) {
                holdout = GeometryStage.warpField(subject, map: map, width: w, height: h)
            }
            if let l = layers.underNormal { PixelOps.over(frame, layer: l, holdout: holdout) }
            if let l = layers.underAdditive { PixelOps.add(frame, layer: l, holdout: holdout) }
            if let l = layers.overNormal { PixelOps.over(frame, layer: l, holdout: nil) }
            if let l = layers.overAdditive { PixelOps.add(frame, layer: l, holdout: nil) }
        }

        // 6. Text and stickers
        LayerRenderer.draw(texts: project.texts, stickers: project.stickers, loop: loop, time: time, into: frame)

        // 7. Grain and flicker
        PostFX.apply(look: project.look, buffer: frame, phase: p, loop: loop)
        return cancelled() ? nil : frame
    }
}
