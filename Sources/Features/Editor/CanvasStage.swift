import SwiftUI

// MARK: - Coordinates

/// Converts between positions on the preview (canvas coordinates, 0...1) and positions on the source photo, which is
/// where strokes and arrows are stored. Follows the canvas settings: aspect ratio, fill or fit, reframe and zoom.
struct CanvasMapping {
    let canvasAspect: Double
    let sourceAspect: Double
    let spec: CanvasSpec

    /// Visible part of the photo in photo coordinates (width, height, centre) when the canvas fills.
    private var crop: (w: Double, h: Double, cx: Double, cy: Double) {
        var w: Double, h: Double
        if canvasAspect > sourceAspect { w = 1; h = sourceAspect / canvasAspect } else { h = 1; w = canvasAspect / sourceAspect }
        let zoom = max(1, spec.zoom)
        w /= zoom
        h /= zoom
        let cx = min(max(spec.centerX, w / 2), 1 - w / 2)
        let cy = min(max(spec.centerY, h / 2), 1 - h / 2)
        return (w, h, cx, cy)
    }

    /// Share of the canvas the whole photo covers when it is fitted (not filled).
    private var fitted: (w: Double, h: Double) {
        if canvasAspect > sourceAspect { return (sourceAspect / canvasAspect, 1) }
        return (1, canvasAspect / sourceAspect)
    }

    func photoPoint(fromCanvas p: CGPoint) -> NPoint {
        let u = Double(p.x), v = Double(p.y)
        var x: Double, y: Double
        if spec.fit == .fill {
            let c = crop
            x = c.cx - c.w / 2 + u * c.w
            y = c.cy - c.h / 2 + v * c.h
        } else {
            let f = fitted
            x = (u - (1 - f.w) / 2) / f.w
            y = (v - (1 - f.h) / 2) / f.h
        }
        return NPoint(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    func canvasPoint(fromPhoto n: NPoint) -> CGPoint {
        if spec.fit == .fill {
            let c = crop
            return CGPoint(x: (n.x - (c.cx - c.w / 2)) / c.w, y: (n.y - (c.cy - c.h / 2)) / c.h)
        }
        let f = fitted
        return CGPoint(x: (1 - f.w) / 2 + n.x * f.w, y: (1 - f.h) / 2 + n.y * f.h)
    }

    /// Brush radius (a share of the photo's long edge) in points on a preview of `size`.
    func radius(_ fraction: Double, in size: CGSize) -> CGFloat {
        let widthShare = spec.fit == .fill ? crop.w : fitted.w
        let heightShare = spec.fit == .fill ? crop.h : fitted.h
        let photoWidth = Double(size.width) / widthShare
        let photoHeight = Double(size.height) / heightShare
        let longEdge = sourceAspect >= 1 ? photoWidth : photoHeight
        return CGFloat(fraction * longEdge)
    }

    /// The part of the photo that a drag of `translation` (as a share of the preview) moves across.
    var cropSize: (w: Double, h: Double) { (crop.w, crop.h) }
}

extension EditorModel {
    var mapping: CanvasMapping {
        CanvasMapping(canvasAspect: canvasAspect, sourceAspect: project.source.aspect, spec: project.canvas)
    }

    // MARK: Strokes

    func strokes(for target: PaintTarget) -> [BrushStroke] {
        switch target {
        case .flow(let id): return project.flowRegions.first(where: { $0.id == id })?.strokes ?? []
        case .anchors: return project.anchors
        case .cinemagraph: return project.cinemagraph.maskStrokes
        case .depth: return project.parallax.depthStrokes
        case .effect(let id): return project.livingEffects.first(where: { $0.id == id })?.brush ?? []
        }
    }

    func commitStroke(points: [NPoint], target: PaintTarget) {
        guard !points.isEmpty else { return }
        let stroke = BrushStroke(
            points: points,
            radius: brushRadius,
            feather: brushFeather,
            erase: paintTool == .erase,
            value: depthValue
        )
        mutate { project in
            switch target {
            case .flow(let id):
                if let index = project.flowRegions.firstIndex(where: { $0.id == id }) { project.flowRegions[index].strokes.append(stroke) }
            case .anchors: project.anchors.append(stroke)
            case .cinemagraph: project.cinemagraph.maskStrokes.append(stroke)
            case .depth: project.parallax.depthStrokes.append(stroke)
            case .effect(let id):
                if let index = project.livingEffects.firstIndex(where: { $0.id == id }) { project.livingEffects[index].brush.append(stroke) }
            }
        }
    }

    func clearStrokes(target: PaintTarget) {
        mutate { project in
            switch target {
            case .flow(let id):
                if let index = project.flowRegions.firstIndex(where: { $0.id == id }) { project.flowRegions[index].strokes = [] }
            case .anchors: project.anchors = []
            case .cinemagraph: project.cinemagraph.maskStrokes = []
            case .depth: project.parallax.depthStrokes = []
            case .effect(let id):
                if let index = project.livingEffects.firstIndex(where: { $0.id == id }) { project.livingEffects[index].brush = [] }
            }
        }
    }

    /// Removes the most recent stroke of the target (the dock's undo also does this, step by step).
    func removeLastStroke(target: PaintTarget) {
        mutate { project in
            switch target {
            case .flow(let id):
                if let index = project.flowRegions.firstIndex(where: { $0.id == id }), !project.flowRegions[index].strokes.isEmpty {
                    project.flowRegions[index].strokes.removeLast()
                }
            case .anchors: if !project.anchors.isEmpty { project.anchors.removeLast() }
            case .cinemagraph: if !project.cinemagraph.maskStrokes.isEmpty { project.cinemagraph.maskStrokes.removeLast() }
            case .depth: if !project.parallax.depthStrokes.isEmpty { project.parallax.depthStrokes.removeLast() }
            case .effect(let id):
                if let index = project.livingEffects.firstIndex(where: { $0.id == id }), !project.livingEffects[index].brush.isEmpty {
                    project.livingEffects[index].brush.removeLast()
                }
            }
        }
    }
}

// MARK: - Stage

/// The live preview, with the drawing and layer gestures laid over it.
struct CanvasStage: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        GeometryReader { geo in
            let box = fitted(in: geo.size)
            ZStack {
                LM.Palette.carbon
                if let frame = model.frame {
                    Image(uiImage: frame)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: box.width, height: box.height)
                } else {
                    ProgressView().tint(LM.Palette.mist)
                }
                canvasOverlay(size: box)
                if model.showingOriginal {
                    Text("Original")
                        .font(LM.Font.label)
                        .foregroundStyle(LM.Palette.paper)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LM.Palette.line, lineWidth: 1))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(LM.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Preview of your animation"))
    }

    private func fitted(in available: CGSize) -> CGSize {
        let aspect = max(0.1, model.canvasAspect)
        let maxW = max(1, available.width)
        let maxH = max(1, available.height)
        if maxW / maxH > aspect { return CGSize(width: maxH * aspect, height: maxH) }
        return CGSize(width: maxW, height: maxW / aspect)
    }

    @ViewBuilder
    private func canvasOverlay(size: CGSize) -> some View {
        if let target = model.paintTarget {
            PaintOverlay(model: model, target: target, size: size)
        } else if model.tool == .text {
            LayerOverlay(model: model, size: size)
        } else if model.tool == .canvas && model.project.canvas.fit == .fill {
            ReframeOverlay(model: model, size: size)
        }
    }
}

// MARK: - Painting and arrows

struct PaintOverlay: View {
    @ObservedObject var model: EditorModel
    let target: PaintTarget
    let size: CGSize

    @State private var live: [NPoint] = []
    @State private var liveArrow: FlowArrow?
    @State private var handle: (index: Int, isEnd: Bool)?
    @State private var touch: CGPoint?
    @State private var started = false

    private var mapping: CanvasMapping { model.mapping }

    private var isArrowMode: Bool {
        if case .flow = target { return model.paintTool == .arrow }
        return false
    }

    private var flowID: UUID? {
        if case .flow(let id) = target { return id }
        return nil
    }

    private var arrows: [FlowArrow] {
        guard let id = flowID else { return [] }
        return model.project.flowRegions.first(where: { $0.id == id })?.arrows ?? []
    }

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                drawStrokes(&context, canvasSize)
                drawArrows(&context, canvasSize)
                drawBrush(&context, canvasSize)
            }
            .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .gesture(drag)
        }
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func viewPoint(_ n: NPoint) -> CGPoint {
        let c = mapping.canvasPoint(fromPhoto: n)
        return CGPoint(x: c.x * size.width, y: c.y * size.height)
    }

    private var tint: Color {
        switch target {
        case .anchors: return Color(hex: 0x7C86FF)
        case .depth: return LM.Palette.glow
        default: return LM.Palette.glow
        }
    }

    private func color(for stroke: BrushStroke) -> Color {
        guard case .depth = target else { return tint }
        let t = min(max(stroke.value, 0), 1)
        return Color(red: 0.43 + (0.95 - 0.43) * t, green: 0.48 + (0.77 - 0.48) * t, blue: 1.0 + (0.55 - 1.0) * t)
    }

    private func path(for points: [NPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: viewPoint(first))
        for point in points.dropFirst() { path.addLine(to: viewPoint(point)) }
        return path
    }

    private func drawStrokes(_ context: inout GraphicsContext, _ canvasSize: CGSize) {
        let strokes = model.strokes(for: target)
        context.opacity = 0.5
        context.drawLayer { layer in
            for stroke in strokes {
                paint(stroke.points, radius: stroke.radius, erase: stroke.erase, color: color(for: stroke), into: &layer)
            }
            if !live.isEmpty && !isArrowMode {
                let erase = model.paintTool == .erase
                paint(live, radius: model.brushRadius, erase: erase, color: depthColor, into: &layer)
            }
        }
        context.opacity = 1
    }

    private var depthColor: Color {
        guard case .depth = target else { return tint }
        let t = min(max(model.depthValue, 0), 1)
        return Color(red: 0.43 + 0.52 * t, green: 0.48 + 0.29 * t, blue: 1.0 - 0.45 * t)
    }

    private func paint(_ points: [NPoint], radius: Double, erase: Bool, color: Color, into layer: inout GraphicsContext) {
        guard !points.isEmpty else { return }
        let width = max(2, mapping.radius(radius, in: size) * 2)
        layer.blendMode = erase ? .clear : .normal
        if points.count == 1 {
            let c = viewPoint(points[0])
            layer.fill(Path(ellipseIn: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width)), with: .color(color))
        } else {
            layer.stroke(path(for: points), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawArrows(_ context: inout GraphicsContext, _ canvasSize: CGSize) {
        guard flowID != nil else { return }
        var all = arrows
        if let liveArrow { all.append(liveArrow) }
        for (index, arrow) in all.enumerated() {
            let from = viewPoint(arrow.from)
            let to = viewPoint(arrow.to)
            let selected = model.selectedArrow == index
            let stroke = selected ? LM.Palette.glow : Color.white
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            context.stroke(line, with: .color(Color.black.opacity(0.5)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // Arrow head
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head: CGFloat = 14
            var tip = Path()
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x - head * cos(angle - 0.45), y: to.y - head * sin(angle - 0.45)))
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x - head * cos(angle + 0.45), y: to.y - head * sin(angle + 0.45)))
            context.stroke(tip, with: .color(stroke), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // Handles
            for end in [from, to] {
                let rect = CGRect(x: end.x - 9, y: end.y - 9, width: 18, height: 18)
                context.fill(Path(ellipseIn: rect), with: .color(stroke))
                context.stroke(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.6)), lineWidth: 1.5)
            }
        }
    }

    private func drawBrush(_ context: inout GraphicsContext, _ canvasSize: CGSize) {
        guard !isArrowMode, let touch else { return }
        let r = mapping.radius(model.brushRadius, in: size)
        let rect = CGRect(x: touch.x - r, y: touch.y - r, width: r * 2, height: r * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = clamp(value.location)
                touch = location
                if isArrowMode { arrowChanged(start: value.startLocation, location: location) } else { paintChanged(location) }
            }
            .onEnded { value in
                let location = clamp(value.location)
                if isArrowMode { arrowEnded(start: value.startLocation, location: location) } else { paintEnded() }
                touch = nil
                started = false
            }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    private func normalized(_ p: CGPoint) -> NPoint {
        mapping.photoPoint(fromCanvas: CGPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1)))
    }

    private func paintChanged(_ location: CGPoint) {
        let point = normalized(location)
        if let last = live.last {
            let dx = point.x - last.x, dy = point.y - last.y
            if dx * dx + dy * dy < 0.000016 { return }
        }
        live.append(point)
    }

    private func paintEnded() {
        let points = live
        live = []
        model.commitStroke(points: points, target: target)
    }

    private func nearestHandle(to location: CGPoint) -> (index: Int, isEnd: Bool)? {
        var best: (index: Int, isEnd: Bool, distance: CGFloat)?
        for (index, arrow) in arrows.enumerated() {
            for (isEnd, point) in [(false, arrow.from), (true, arrow.to)] {
                let p = viewPoint(point)
                let d = hypot(p.x - location.x, p.y - location.y)
                if d < 30, d < (best?.distance ?? .infinity) { best = (index, isEnd, d) }
            }
        }
        return best.map { (index: $0.index, isEnd: $0.isEnd) }
    }

    private func arrowChanged(start: CGPoint, location: CGPoint) {
        guard let id = flowID else { return }
        if !started {
            started = true
            handle = nearestHandle(to: start)
            if let handle { model.selectedArrow = handle.index }
        }
        if let handle {
            let point = normalized(location)
            model.mutate("arrow-\(id)-\(handle.index)-\(handle.isEnd)") { project in
                guard let r = project.flowRegions.firstIndex(where: { $0.id == id }), project.flowRegions[r].arrows.indices.contains(handle.index) else { return }
                if handle.isEnd { project.flowRegions[r].arrows[handle.index].to = point } else { project.flowRegions[r].arrows[handle.index].from = point }
            }
        } else if hypot(location.x - start.x, location.y - start.y) > 6 {
            liveArrow = FlowArrow(from: normalized(start), to: normalized(location))
        }
    }

    private func arrowEnded(start: CGPoint, location: CGPoint) {
        defer { handle = nil; liveArrow = nil }
        guard let id = flowID, handle == nil else { return }
        if hypot(location.x - start.x, location.y - start.y) > 24 {
            let arrow = FlowArrow(from: normalized(start), to: normalized(location))
            model.mutate { project in
                if let r = project.flowRegions.firstIndex(where: { $0.id == id }) { project.flowRegions[r].arrows.append(arrow) }
            }
            model.selectedArrow = max(0, arrows.count - 1)
            LMHaptics.tap()
        } else {
            // A tap selects the arrow whose line is closest, or clears the selection.
            var best: (index: Int, distance: CGFloat)?
            for (index, arrow) in arrows.enumerated() {
                let d = distanceToSegment(location, viewPoint(arrow.from), viewPoint(arrow.to))
                if d < 28, d < (best?.distance ?? .infinity) { best = (index, d) }
            }
            model.selectedArrow = best?.index
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Text and sticker placement

struct LayerOverlay: View {
    @ObservedObject var model: EditorModel
    let size: CGSize

    @State private var startCenter: NPoint?
    @State private var startScale: Double?
    @State private var startRotation: Double?

    private var selectedCenter: (center: NPoint, radius: CGFloat)? {
        if let id = model.selectedText, let layer = model.project.texts.first(where: { $0.id == id }) {
            let height = layer.size * Double(size.height) * layer.scale
            let width = height * 0.55 * Double(max(layer.text.count, 1))
            return (layer.center, CGFloat(max(min(width, Double(size.width)) / 2, 24)))
        }
        if let id = model.selectedSticker, let layer = model.project.stickers.first(where: { $0.id == id }) {
            return (layer.center, CGFloat(max(layer.size * Double(size.height) * layer.scale * 0.6, 24)))
        }
        return nil
    }

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                guard let selected = selectedCenter else { return }
                let c = CGPoint(x: selected.center.x * canvasSize.width, y: selected.center.y * canvasSize.height)
                let rect = CGRect(x: c.x - selected.radius, y: c.y - selected.radius, width: selected.radius * 2, height: selected.radius * 2)
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 10),
                    with: .color(LM.Palette.glow),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
            }
            .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in select(near: value.location) })
                .gesture(dragGesture.simultaneously(with: magnifyGesture).simultaneously(with: rotateGesture))
        }
        .accessibilityHidden(true)
    }

    private func select(near location: CGPoint) {
        let target = NPoint(Double(location.x / max(size.width, 1)), Double(location.y / max(size.height, 1)))
        var best: (kind: Int, id: UUID, distance: Double)?
        for layer in model.project.texts {
            let d = hypot((layer.center.x - target.x) * Double(size.width), (layer.center.y - target.y) * Double(size.height))
            if d < (best?.distance ?? 80) { best = (0, layer.id, d) }
        }
        for layer in model.project.stickers {
            let d = hypot((layer.center.x - target.x) * Double(size.width), (layer.center.y - target.y) * Double(size.height))
            if d < (best?.distance ?? 80) { best = (1, layer.id, d) }
        }
        guard let best else { return }
        if best.kind == 0 { model.selectedText = best.id; model.selectedSticker = nil } else { model.selectedSticker = best.id; model.selectedText = nil }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let selected = selectedCenter else { return }
                if startCenter == nil { startCenter = selected.center }
                guard let origin = startCenter else { return }
                let next = NPoint(
                    min(max(origin.x + Double(value.translation.width / max(size.width, 1)), 0), 1),
                    min(max(origin.y + Double(value.translation.height / max(size.height, 1)), 0), 1)
                )
                setCenter(next)
            }
            .onEnded { _ in startCenter = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let current = currentScale else { return }
                if startScale == nil { startScale = current }
                setScale(min(max((startScale ?? 1) * Double(value.magnification), 0.2), 6))
            }
            .onEnded { _ in startScale = nil }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard let current = currentRotation else { return }
                if startRotation == nil { startRotation = current }
                setRotation((startRotation ?? 0) + value.rotation.degrees)
            }
            .onEnded { _ in startRotation = nil }
    }

    private var currentScale: Double? {
        if let id = model.selectedText { return model.project.texts.first(where: { $0.id == id })?.scale }
        if let id = model.selectedSticker { return model.project.stickers.first(where: { $0.id == id })?.scale }
        return nil
    }

    private var currentRotation: Double? {
        if let id = model.selectedText { return model.project.texts.first(where: { $0.id == id })?.rotation }
        if let id = model.selectedSticker { return model.project.stickers.first(where: { $0.id == id })?.rotation }
        return nil
    }

    private func setCenter(_ point: NPoint) {
        if let id = model.selectedText {
            model.mutate("move-\(id)") { p in if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].center = point } }
        } else if let id = model.selectedSticker {
            model.mutate("move-\(id)") { p in if let i = p.stickers.firstIndex(where: { $0.id == id }) { p.stickers[i].center = point } }
        }
    }

    private func setScale(_ value: Double) {
        if let id = model.selectedText {
            model.mutate("scale-\(id)") { p in if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].scale = value } }
        } else if let id = model.selectedSticker {
            model.mutate("scale-\(id)") { p in if let i = p.stickers.firstIndex(where: { $0.id == id }) { p.stickers[i].scale = value } }
        }
    }

    private func setRotation(_ value: Double) {
        if let id = model.selectedText {
            model.mutate("rotate-\(id)") { p in if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].rotation = value } }
        } else if let id = model.selectedSticker {
            model.mutate("rotate-\(id)") { p in if let i = p.stickers.firstIndex(where: { $0.id == id }) { p.stickers[i].rotation = value } }
        }
    }
}

// MARK: - Reframe

/// Drag to move the crop and pinch to zoom when the canvas fills.
struct ReframeOverlay: View {
    @ObservedObject var model: EditorModel
    let size: CGSize

    @State private var startCentre: (x: Double, y: Double)?
    @State private var startZoom: Double?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let spec = model.project.canvas
                        if startCentre == nil { startCentre = (spec.centerX, spec.centerY) }
                        guard let origin = startCentre else { return }
                        let crop = model.mapping.cropSize
                        let dx = Double(value.translation.width / max(size.width, 1)) * crop.w
                        let dy = Double(value.translation.height / max(size.height, 1)) * crop.h
                        model.mutate("reframe") { p in
                            p.canvas.centerX = min(max(origin.x - dx, 0), 1)
                            p.canvas.centerY = min(max(origin.y - dy, 0), 1)
                        }
                    }
                    .onEnded { _ in startCentre = nil }
                    .simultaneously(with:
                        MagnifyGesture()
                            .onChanged { value in
                                if startZoom == nil { startZoom = model.project.canvas.zoom }
                                let next = min(max((startZoom ?? 1) * Double(value.magnification), 1), 4)
                                model.mutate("reframe-zoom") { $0.canvas.zoom = next }
                            }
                            .onEnded { _ in startZoom = nil }
                    )
            )
            .accessibilityHidden(true)
    }
}
