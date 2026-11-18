import SwiftUI

// MARK: - Model helpers

extension EditorModel {
    func addFlowRegion() {
        let number = project.flowRegions.count + 1
        let region = FlowRegion(name: "Flow \(number)")
        mutate { $0.flowRegions.append(region) }
        selectedFlow = region.id
        selectedArrow = nil
        paintTool = .paint
        paintTarget = .flow(region.id)
    }

    func deleteFlowRegion(_ id: UUID) {
        mutate { $0.flowRegions.removeAll { $0.id == id } }
        if selectedFlow == id { selectedFlow = project.flowRegions.first?.id; selectedArrow = nil }
        if paintTarget == .flow(id) { paintTarget = nil }
    }

    func deleteSelectedArrow(in regionID: UUID) {
        guard let index = selectedArrow else { return }
        mutate { project in
            guard let r = project.flowRegions.firstIndex(where: { $0.id == regionID }), project.flowRegions[r].arrows.indices.contains(index) else { return }
            project.flowRegions[r].arrows.remove(at: index)
        }
        selectedArrow = nil
    }
}

// MARK: - Brush controls

/// Paint, erase and preview chips with the brush dials. Used by Flow, Anchors, Video and Depth.
struct BrushControls: View {
    @ObservedObject var model: EditorModel
    let target: PaintTarget
    var allowsArrows = false
    var showsDepth = false
    var paintTitle = "Paint"
    var heading = "On the photo"

    private enum Mode: Hashable { case paint, erase, arrow, preview }

    private var mode: Mode {
        guard model.paintTarget == target else { return .preview }
        switch model.paintTool {
        case .paint: return .paint
        case .erase: return .erase
        case .arrow: return .arrow
        }
    }

    private var modes: [Mode] { allowsArrows ? [.paint, .erase, .arrow, .preview] : [.paint, .erase, .preview] }

    var body: some View {
        VStack(alignment: .leading, spacing: LM.Space.m) {
            PanelSection(title: heading) {
                OptionChips(
                    options: modes,
                    selection: Binding(get: { mode }, set: { set($0) }),
                    title: { title(for: $0) }
                )
            }
            if mode == .paint || mode == .erase {
                ParamDial(title: "Brush size", value: $model.brushRadius, range: 0.01...0.15, defaultValue: 0.04, unit: "%", scale: 100)
                ParamDial(title: "Edge softness", value: $model.brushFeather, range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
                if showsDepth {
                    ParamDial(title: "Depth of paint", value: $model.depthValue, range: 0...1, defaultValue: 1, unit: "%", scale: 100)
                    PanelNote(text: "100% is close to the camera, 0% is far away.")
                }
                HStack(spacing: LM.Space.s) {
                    PanelButton(title: "Undo stroke", symbol: "arrow.uturn.backward") { model.removeLastStroke(target: target) }
                        .disabled(model.strokes(for: target).isEmpty)
                    PanelButton(title: "Clear all", symbol: "trash", role: .destructive) { model.clearStrokes(target: target) }
                        .disabled(model.strokes(for: target).isEmpty)
                }
            }
        }
    }

    private func title(for mode: Mode) -> String {
        switch mode {
        case .paint: return paintTitle
        case .erase: return "Erase"
        case .arrow: return "Arrows"
        case .preview: return "Preview"
        }
    }

    private func set(_ mode: Mode) {
        switch mode {
        case .paint: model.paintTool = .paint; model.paintTarget = target
        case .erase: model.paintTool = .erase; model.paintTarget = target
        case .arrow: model.paintTool = .arrow; model.paintTarget = target
        case .preview: model.paintTarget = nil
        }
    }
}

// MARK: - Flow

struct FlowPanel: View {
    @ObservedObject var model: EditorModel

    private var region: FlowRegion? {
        let id = model.selectedFlow ?? model.project.flowRegions.first?.id
        return model.project.flowRegions.first { $0.id == id }
    }

    var body: some View {
        PanelBody {
            PanelSection(title: "Flow regions", detail: "Each region is painted separately and has its own direction, speed and strength.") {
                ForEach(model.project.flowRegions) { item in
                    LayerRow(
                        title: item.name,
                        subtitle: subtitle(for: item),
                        symbol: "wind",
                        selected: region?.id == item.id,
                        enabled: model.binding(\.flowRegions, id: item.id, \.enabled, fallback: true),
                        onSelect: {
                            model.selectedFlow = item.id
                            model.selectedArrow = nil
                            if model.paintTarget != nil { model.paintTarget = .flow(item.id) }
                        },
                        onDelete: { model.deleteFlowRegion(item.id) }
                    )
                }
                PanelButton(title: "Add a region", symbol: "plus", prominent: true) { model.addFlowRegion() }
            }
            if let region {
                BrushControls(model: model, target: .flow(region.id), allowsArrows: true)
                arrowSection(region)
                PanelSection(title: "Motion") {
                    ParamDial(title: "Speed", value: model.binding(\.flowRegions, id: region.id, \.speed, fallback: 1), range: 0.1...3, defaultValue: 1, unit: "x", decimals: 1)
                    ParamDial(title: "Strength", value: model.binding(\.flowRegions, id: region.id, \.strength, fallback: 0.5), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
                    ParamDial(title: "Soft edge", value: model.binding(\.flowRegions, id: region.id, \.softness, fallback: 0.5), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
                }
                if region.isPainted && !region.hasDirection {
                    PanelNote(text: "This region has no arrows yet, so it will not move. Choose Arrows and drag across the photo to set a direction.")
                }
            } else {
                PanelNote(text: "Add a region, paint the part of the photo that should move, then draw an arrow to set its direction.")
            }
            PanelSection(title: "Anchors", detail: "Paint areas that stay perfectly still while everything around them flows.") {
                BrushControls(model: model, target: .anchors, paintTitle: "Paint anchor", heading: "Anchor brush")
            }
        }
        .onAppear {
            if model.selectedFlow == nil { model.selectedFlow = model.project.flowRegions.first?.id }
        }
    }

    private func subtitle(for item: FlowRegion) -> String {
        let arrows = item.arrows.count
        if !item.isPainted { return "Not painted yet" }
        return arrows == 0 ? "Painted, no arrows" : (arrows == 1 ? "1 arrow" : "\(arrows) arrows")
    }

    @ViewBuilder
    private func arrowSection(_ region: FlowRegion) -> some View {
        PanelSection(
            title: "Direction",
            detail: "With Arrows chosen, drag on the photo to draw an arrow. Drag its dots to adjust it, tap an arrow to select it."
        ) {
            HStack(spacing: LM.Space.s) {
                PanelButton(title: "Delete arrow", symbol: "xmark") { model.deleteSelectedArrow(in: region.id) }
                    .disabled(model.selectedArrow == nil)
                PanelButton(title: "Clear arrows", symbol: "trash", role: .destructive) {
                    model.mutate { project in
                        if let r = project.flowRegions.firstIndex(where: { $0.id == region.id }) { project.flowRegions[r].arrows = [] }
                    }
                    model.selectedArrow = nil
                }
                .disabled(region.arrows.isEmpty)
            }
        }
    }
}
