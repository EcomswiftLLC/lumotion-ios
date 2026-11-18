import SwiftUI

// MARK: - Camera motion

struct CameraPanel: View {
    @ObservedObject var model: EditorModel

    private var camera: CameraMotion { model.project.camera }

    var body: some View {
        PanelBody {
            PanelSection(title: "Move", detail: "A camera move across the whole picture, repeated every loop.") {
                OptionChips(options: CameraKind.allCases, selection: model.binding(\.camera.kind), title: { Labels.camera($0) })
            }
            if camera.kind == .pan || camera.kind == .drift {
                PanelSection(title: "Direction") {
                    DirectionPad(selection: model.binding(\.camera.direction))
                }
            }
            if camera.kind != .none {
                ParamDial(title: "Amount", value: model.binding(\.camera.amount), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
            }
            if camera.kind == .zoomIn || camera.kind == .zoomOut || camera.kind == .pan || camera.kind == .custom {
                PanelSection(title: "Timing curve") {
                    OptionChips(options: Easing.allCases, selection: model.binding(\.camera.easing), title: { Labels.easing($0) })
                }
                ToggleRow(
                    title: "Return to the start",
                    isOn: model.binding(\.camera.loops),
                    detail: "On: the move goes out and back, so the loop is seamless. Off: a one-way move that jumps back when the loop restarts."
                )
            }
            if camera.kind == .custom {
                framing(title: "Start framing", zoom: model.binding(\.camera.start.zoom), x: model.binding(\.camera.start.offsetX), y: model.binding(\.camera.start.offsetY), rotation: model.binding(\.camera.start.rotation))
                framing(title: "End framing", zoom: model.binding(\.camera.end.zoom), x: model.binding(\.camera.end.offsetX), y: model.binding(\.camera.end.offsetY), rotation: model.binding(\.camera.end.rotation))
            }
        }
    }

    private func framing(title: String, zoom: Binding<Double>, x: Binding<Double>, y: Binding<Double>, rotation: Binding<Double>) -> some View {
        PanelSection(title: title) {
            ParamDial(title: "Zoom", value: zoom, range: 1...3, defaultValue: 1, unit: "x", decimals: 1)
            ParamDial(title: "Across", value: x, range: -0.5...0.5, defaultValue: 0, unit: "%", scale: 100)
            ParamDial(title: "Up and down", value: y, range: -0.5...0.5, defaultValue: 0, unit: "%", scale: 100)
            ParamDial(title: "Rotate", value: rotation, range: -45...45, defaultValue: 0, unit: " deg")
        }
    }
}

/// Eight arrows around a centre dot.
struct DirectionPad: View {
    @Binding var selection: PanDirection

    private let rows: [[PanDirection?]] = [
        [.upLeft, .up, .upRight],
        [.left, nil, .right],
        [.downLeft, .down, .downRight],
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { column in
                        if let direction = rows[row][column] {
                            let selected = selection == direction
                            Button { selection = direction } label: {
                                Image(systemName: Labels.directionSymbol(direction))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(selected ? LM.Palette.onGlow : LM.Palette.paper)
                                    .frame(width: 52, height: 44)
                                    .background(selected ? LM.Palette.glow : LM.Palette.graphite, in: RoundedRectangle(cornerRadius: LM.Radius.chip, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(Labels.direction(direction)))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        } else {
                            Color.clear.frame(width: 52, height: 44)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Depth

struct DepthPanel: View {
    @ObservedObject var model: EditorModel

    private var parallax: ParallaxSettings { model.project.parallax }

    var body: some View {
        PanelBody {
            ToggleRow(
                title: "3D depth motion",
                isOn: model.binding(\.parallax.enabled),
                detail: "Near parts of the photo move more than far parts, like looking through a window."
            )
            if parallax.enabled {
                PanelSection(title: "Where depth comes from") {
                    OptionChips(
                        options: DepthSource.allCases,
                        selection: Binding(
                            get: { parallax.depthSource },
                            set: { source in
                                model.mutate("depth-source") { $0.parallax.depthSource = source }
                                if source == .subjectMask { model.ensureSubjectMask() }
                                model.paintTarget = source == .manualBrush ? .depth : nil
                            }
                        ),
                        title: { Labels.depthSource($0) }
                    )
                    sourceNote
                }
                if parallax.depthSource == .manualBrush {
                    BrushControls(model: model, target: .depth, showsDepth: true, paintTitle: "Paint depth")
                }
                PanelSection(title: "Motion") {
                    OptionChips(options: ParallaxStyle.allCases, selection: model.binding(\.parallax.style), title: { Labels.parallaxStyle($0) })
                    ParamDial(title: "Strength", value: model.binding(\.parallax.strength), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
                }
                PanelSection(title: "Filling the edges", detail: "When the picture shifts, this fills the edge that appears.") {
                    OptionChips(options: EdgeFill.allCases, selection: model.binding(\.parallax.edgeFill), title: { Labels.edgeFill($0) })
                }
                ToggleRow(title: "Swap near and far", isOn: model.binding(\.parallax.invertDepth))
            }
        }
        .onAppear {
            if parallax.enabled && parallax.depthSource == .subjectMask { model.ensureSubjectMask() }
        }
    }

    @ViewBuilder
    private var sourceNote: some View {
        switch parallax.depthSource {
        case .subjectMask:
            if model.maskBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(LM.Palette.glow)
                    PanelNote(text: "Finding the subject on your device.")
                }
            } else if model.assets.subjectMask != nil {
                PanelNote(text: "The main subject is near, the rest is far.")
            } else if model.subjectChecked {
                PanelNote(text: "No subject was found in this photo, so everything is treated as far away. Try Gradient or Painted.")
            }
        case .embeddedDepth:
            if model.assets.embeddedDepth != nil {
                PanelNote(text: "Using the depth stored in this photo.")
            } else {
                PanelNote(text: "This photo has no stored depth. Portrait mode photos from an iPhone usually do.")
            }
        case .manualBrush:
            PanelNote(text: "Paint near parts bright and far parts dark with the brush.")
        case .gradient:
            PanelNote(text: "The bottom of the photo is near and the top is far.")
        }
    }
}

// MARK: - Living effects

extension EditorModel {
    func addEffect(_ kind: LivingEffectKind) {
        let effect = LivingEffect(kind: kind)
        mutate { $0.livingEffects.append(effect) }
        selectedEffect = effect.id
        LMHaptics.tap()
    }
}

struct EffectsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var painted = false

    private var selected: LivingEffect? {
        let id = model.selectedEffect ?? model.project.livingEffects.first?.id
        return model.project.livingEffects.first { $0.id == id }
    }

    var body: some View {
        PanelBody {
            PanelSection(title: "Add an effect", detail: "Effects move the whole photo, or only the part you limit them to.") {
                FlowLayout(spacing: LM.Space.s) {
                    ForEach(LivingEffectKind.allCases) { kind in
                        LMChip(title: Labels.effect(kind), systemImage: Labels.effectSymbol(kind), selected: false) { model.addEffect(kind) }
                    }
                }
            }
            if !model.project.livingEffects.isEmpty {
                PanelSection(title: "In this photo") {
                    let effects = model.project.livingEffects
                    ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                        LayerRow(
                            title: Labels.effect(effect.kind),
                            symbol: Labels.effectSymbol(effect.kind),
                            selected: selected?.id == effect.id,
                            enabled: model.binding(\.livingEffects, id: effect.id, \.enabled, fallback: true),
                            onSelect: { model.selectedEffect = effect.id; painted = false; model.paintTarget = nil },
                            onMoveUp: index > 0 ? { model.mutate { $0.livingEffects.shift(index, by: -1) } } : nil,
                            onMoveDown: index < effects.count - 1 ? { model.mutate { $0.livingEffects.shift(index, by: 1) } } : nil,
                            onDelete: {
                                model.mutate { $0.livingEffects.removeAll { $0.id == effect.id } }
                                if model.selectedEffect == effect.id { model.selectedEffect = nil }
                                model.paintTarget = nil
                            }
                        )
                    }
                }
            }
            if let effect = selected {
                controls(effect)
            } else if model.project.livingEffects.isEmpty {
                PanelNote(text: "Tap an effect above to add it. Try Water ripple on a lake or Wind sway on grass.")
            }
        }
    }

    @ViewBuilder
    private func controls(_ effect: LivingEffect) -> some View {
        let id = effect.id
        PanelSection(title: Labels.effect(effect.kind)) {
            ParamDial(title: "Strength", value: model.binding(\.livingEffects, id: id, \.strength, fallback: 0.5), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
            ParamDial(title: "Speed", value: model.binding(\.livingEffects, id: id, \.speed, fallback: 1), range: 0.1...3, defaultValue: 1, unit: "x", decimals: 1)
            ParamDial(title: "Pattern size", value: model.binding(\.livingEffects, id: id, \.scale, fallback: 1), range: 0.25...4, defaultValue: 1, unit: "x", decimals: 1)
            if Labels.usesAngle(effect.kind) {
                ParamDial(title: "Direction", value: model.binding(\.livingEffects, id: id, \.angle, fallback: 0), range: 0...360, defaultValue: 0, unit: " deg")
            }
            if Labels.usesCenter(effect.kind) {
                ParamDial(
                    title: "Centre across",
                    value: centreBinding(id: id, axis: .x),
                    range: 0...1, defaultValue: 0.5, unit: "%", scale: 100
                )
                ParamDial(
                    title: "Centre down",
                    value: centreBinding(id: id, axis: .y),
                    range: 0...1, defaultValue: 0.5, unit: "%", scale: 100
                )
            }
        }
        PanelSection(title: "Limit to", detail: "Choose where the effect is active.") {
            OptionChips(options: Limit.allCases, selection: limitBinding(effect), title: { $0.title })
            if painted || !effect.brush.isEmpty {
                BrushControls(model: model, target: .effect(id), paintTitle: "Paint area")
            }
        }
    }

    private enum Axis { case x, y }

    private func centreBinding(id: UUID, axis: Axis) -> Binding<Double> {
        Binding(
            get: {
                let c = model.project.livingEffects.first(where: { $0.id == id })?.center ?? .center
                return axis == .x ? c.x : c.y
            },
            set: { value in
                model.mutate("centre-\(id)-\(axis)") { project in
                    guard let i = project.livingEffects.firstIndex(where: { $0.id == id }) else { return }
                    if axis == .x { project.livingEffects[i].center.x = value } else { project.livingEffects[i].center.y = value }
                }
            }
        )
    }

    private enum Limit: CaseIterable, Hashable {
        case whole, top, bottom, left, right, painted

        var title: String {
            switch self {
            case .whole: return "Whole photo"
            case .top: return "Top"
            case .bottom: return "Bottom"
            case .left: return "Left"
            case .right: return "Right"
            case .painted: return "Painted"
            }
        }

        var mask: GradientMask? {
            switch self {
            case .whole, .painted: return nil
            case .top: return GradientMask(start: NPoint(0.5, 0.75), end: NPoint(0.5, 0.05), softness: 0.6, invert: false)
            case .bottom: return GradientMask(start: NPoint(0.5, 0.25), end: NPoint(0.5, 0.95), softness: 0.6, invert: false)
            case .left: return GradientMask(start: NPoint(0.75, 0.5), end: NPoint(0.05, 0.5), softness: 0.6, invert: false)
            case .right: return GradientMask(start: NPoint(0.25, 0.5), end: NPoint(0.95, 0.5), softness: 0.6, invert: false)
            }
        }
    }

    private func limitBinding(_ effect: LivingEffect) -> Binding<Limit> {
        let id = effect.id
        return Binding(
            get: {
                guard let current = model.project.livingEffects.first(where: { $0.id == id }) else { return .whole }
                if painted || !current.brush.isEmpty { return .painted }
                guard let gradient = current.gradient else { return .whole }
                return Limit.allCases.first { $0.mask?.start == gradient.start && $0.mask?.end == gradient.end } ?? .whole
            },
            set: { limit in
                painted = limit == .painted
                model.mutate("limit-\(id)") { project in
                    guard let i = project.livingEffects.firstIndex(where: { $0.id == id }) else { return }
                    project.livingEffects[i].gradient = limit.mask
                    if limit != .painted { project.livingEffects[i].brush = [] }
                }
                model.paintTarget = limit == .painted ? .effect(id) : nil
            }
        )
    }
}
