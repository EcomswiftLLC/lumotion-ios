import SwiftUI

// MARK: - Live thumbnails

/// Small pictures of the current photo with a variation applied (a look, a preset), made one after another in the background.
@MainActor
final class VariantThumbnails: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    private var task: Task<Void, Never>?
    private var signature: String?

    /// Starts again only when `signature` changes (for example a different photo or canvas).
    func generate(signature: String, items: [(key: String, project: Project)], assets: SourceAssets, longEdge: Int = 180, time: Double = 0) {
        guard signature != self.signature else { return }
        self.signature = signature
        task?.cancel()
        images = [:]
        task = Task {
            for item in items {
                if Task.isCancelled { return }
                let made = await Task.detached(priority: .utility) { () -> CGImage? in
                    let engine = RenderEngine(project: item.project, assets: assets)
                    return engine.renderFrame(time: time, quality: RenderQuality(longEdge: longEdge))
                }.value
                if Task.isCancelled { return }
                if let made { images[item.key] = UIImage(cgImage: made) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        signature = nil
    }
}

/// A square picture tile with a caption underneath, used for looks and presets.
struct ThumbnailTile: View {
    let title: String
    let image: UIImage?
    var symbol: String? = nil
    var selected: Bool
    var side: CGFloat = 76
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LM.Palette.graphite
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(LM.Palette.mist)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: LM.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LM.Radius.chip, style: .continuous)
                        .strokeBorder(selected ? LM.Palette.glow : LM.Palette.line, lineWidth: selected ? 2 : 1)
                )
                Text(title)
                    .font(LM.Font.caption)
                    .foregroundStyle(selected ? LM.Palette.glow : LM.Palette.paper)
                    .lineLimit(1)
                    .frame(width: side)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A colour picker for a stored colour.
struct ColorRow: View {
    let title: String
    @Binding var color: RGBAColor

    var body: some View {
        ColorPicker(
            selection: Binding(get: { color.swiftUIColor }, set: { color = RGBAColor($0) }),
            supportsOpacity: false
        ) {
            Text(title).font(LM.Font.body).foregroundStyle(LM.Palette.paper)
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Looks

struct LooksPanel: View {
    @ObservedObject var model: EditorModel
    @StateObject private var thumbnails = VariantThumbnails()

    private var look: Look { model.project.look }

    var body: some View {
        PanelBody {
            PanelSection(title: "Filter") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LM.Space.s) {
                        ForEach(LookID.allCases) { id in
                            ThumbnailTile(
                                title: id.title,
                                image: thumbnails.images[id.rawValue],
                                symbol: "circle.lefthalf.filled",
                                selected: look.filter == id
                            ) {
                                model.mutate { $0.look.filter = id }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
            if look.filter != .original {
                ParamDial(title: "Filter strength", value: model.binding(\.look.intensity), range: 0...100, defaultValue: 100, unit: "%")
            }
            PanelSection(title: "Light") {
                dial("Exposure", \.look.adjust.exposure)
                dial("Contrast", \.look.adjust.contrast)
                dial("Highlights", \.look.adjust.highlights)
                dial("Shadows", \.look.adjust.shadows)
            }
            PanelSection(title: "Colour") {
                dial("Saturation", \.look.adjust.saturation)
                dial("Warmth", \.look.adjust.warmth)
                dial("Tint", \.look.adjust.tint)
            }
            PanelSection(title: "Finish") {
                dial("Sharpen", \.look.adjust.sharpen, lower: 0)
                dial("Glow", \.look.adjust.glow, lower: 0)
                dial("Vignette", \.look.adjust.vignette, lower: 0)
                dial("Film grain", \.look.adjust.grain, lower: 0)
                ToggleRow(title: "Animate the grain", isOn: model.binding(\.look.animatedGrain), detail: "Grain changes from frame to frame, like film.")
            }
            PanelSection(title: "Flicker", detail: "A soft pulse of light over the whole picture.") {
                ParamDial(title: "Amount", value: model.binding(\.look.flicker.amount), range: 0...1, defaultValue: 0, unit: "%", scale: 100)
                if look.flicker.amount > 0 {
                    ParamDial(title: "Speed", value: model.binding(\.look.flicker.speed), range: 0.1...3, defaultValue: 1, unit: "x", decimals: 1)
                }
            }
            PanelButton(title: "Reset all dials", symbol: "arrow.counterclockwise") {
                model.mutate { $0.look.adjust = LookAdjust(); $0.look.flicker = Flicker(); $0.look.filter = .original; $0.look.intensity = 100 }
            }
        }
        .onAppear { generate() }
        .onDisappear { thumbnails.cancel() }
    }

    /// A -100...100 dial for a -1...1 value, or 0...100 when `lower` is 0.
    private func dial(_ title: String, _ keyPath: WritableKeyPath<Project, Double>, lower: Double = -1) -> some View {
        ParamDial(title: title, value: model.binding(keyPath), range: lower...1, defaultValue: 0, unit: "", scale: 100)
    }

    private func generate() {
        let source = model.project.source
        let canvas = model.project.canvas
        let items: [(key: String, project: Project)] = LookID.allCases.map { id in
            var project = Project(title: "Look", source: source)
            project.canvas = canvas
            project.look = Look(filter: id)
            return (id.rawValue, project)
        }
        thumbnails.generate(signature: "\(model.project.id)-\(canvas.aspect.rawValue)", items: items, assets: model.assets, longEdge: 160)
    }
}

// MARK: - Overlays

extension EditorModel {
    func addOverlay(_ kind: OverlayKind) {
        var layer = OverlayLayer(kind: kind)
        layer.seed = Int.random(in: 1...9999)
        mutate { $0.overlays.append(layer) }
        selectedOverlay = layer.id
        LMHaptics.tap()
    }
}

struct OverlaysPanel: View {
    @ObservedObject var model: EditorModel

    private var selected: OverlayLayer? {
        let id = model.selectedOverlay ?? model.project.overlays.last?.id
        return model.project.overlays.first { $0.id == id }
    }

    var body: some View {
        PanelBody {
            PanelSection(title: "Add an overlay", detail: "Overlays are drawn by Lumotion and can be stacked.") {
                FlowLayout(spacing: LM.Space.s) {
                    ForEach(OverlayKind.allCases) { kind in
                        LMChip(title: Labels.overlay(kind), systemImage: Labels.overlaySymbol(kind), selected: false) { model.addOverlay(kind) }
                    }
                }
            }
            if !model.project.overlays.isEmpty {
                PanelSection(title: "Stack", detail: "The top of the list is drawn on top.") {
                    let overlays = model.project.overlays
                    ForEach(Array(overlays.enumerated()), id: \.element.id) { index, layer in
                        LayerRow(
                            title: Labels.overlay(layer.kind),
                            symbol: Labels.overlaySymbol(layer.kind),
                            selected: selected?.id == layer.id,
                            enabled: model.binding(\.overlays, id: layer.id, \.enabled, fallback: true),
                            onSelect: { model.selectedOverlay = layer.id },
                            onMoveUp: index > 0 ? { model.mutate { $0.overlays.shift(index, by: -1) } } : nil,
                            onMoveDown: index < overlays.count - 1 ? { model.mutate { $0.overlays.shift(index, by: 1) } } : nil,
                            onDelete: {
                                model.mutate { $0.overlays.removeAll { $0.id == layer.id } }
                                if model.selectedOverlay == layer.id { model.selectedOverlay = nil }
                            }
                        )
                    }
                }
            }
            if let layer = selected {
                controls(layer)
            } else {
                PanelNote(text: "Tap an overlay above to add it. Rain, snow, fireflies and sparkles are good places to start.")
            }
        }
    }

    @ViewBuilder
    private func controls(_ layer: OverlayLayer) -> some View {
        let id = layer.id
        PanelSection(title: Labels.overlay(layer.kind)) {
            ParamDial(title: "Amount", value: model.binding(\.overlays, id: id, \.intensity, fallback: 0.5), range: 0...1, defaultValue: 0.5, unit: "%", scale: 100)
            ParamDial(title: "Speed", value: model.binding(\.overlays, id: id, \.speed, fallback: 1), range: 0.1...3, defaultValue: 1, unit: "x", decimals: 1)
            ParamDial(title: "Size", value: model.binding(\.overlays, id: id, \.size, fallback: 1), range: 0.25...3, defaultValue: 1, unit: "x", decimals: 1)
            ParamDial(title: "Direction", value: model.binding(\.overlays, id: id, \.direction, fallback: 90), range: 0...360, defaultValue: OverlayLayer.naturalDirection(layer.kind), unit: " deg")
            ParamDial(title: "Depth blur", value: model.binding(\.overlays, id: id, \.depthBlur, fallback: 0.4), range: 0...1, defaultValue: 0.4, unit: "%", scale: 100)
        }
        PanelSection(title: "Position") {
            OptionChips(
                options: OverlayPlacement.allCases,
                selection: Binding(
                    get: { model.project.overlays.first(where: { $0.id == id })?.placement ?? .over },
                    set: { placement in
                        model.mutate("placement-\(id)") { project in
                            if let i = project.overlays.firstIndex(where: { $0.id == id }) { project.overlays[i].placement = placement }
                        }
                        if placement == .under { model.ensureSubjectMask() }
                    }
                ),
                title: { Labels.placement($0) }
            )
            if layer.placement == .under && model.subjectChecked && model.assets.subjectMask == nil {
                PanelNote(text: "No subject was found in this photo, so this overlay is drawn in front.")
            }
        }
        PanelSection(title: "Colour") {
            ToggleRow(
                title: "Custom colour",
                isOn: Binding(
                    get: { layer.tint != nil },
                    set: { on in
                        model.mutate { project in
                            if let i = project.overlays.firstIndex(where: { $0.id == id }) {
                                project.overlays[i].tint = on ? RGBAColor(hex: 0xF2C48D) : nil
                            }
                        }
                    }
                )
            )
            if let tint = layer.tint {
                ColorRow(
                    title: "Overlay colour",
                    color: Binding(
                        get: { model.project.overlays.first(where: { $0.id == id })?.tint ?? tint },
                        set: { newColor in
                            model.mutate("tint-\(id)") { project in
                                if let i = project.overlays.firstIndex(where: { $0.id == id }) { project.overlays[i].tint = newColor }
                            }
                        }
                    )
                )
            }
            PanelButton(title: "Shuffle pattern", symbol: "shuffle") {
                model.mutate { project in
                    if let i = project.overlays.firstIndex(where: { $0.id == id }) { project.overlays[i].seed = Int.random(in: 1...9999) }
                }
            }
        }
    }
}

// MARK: - Text and stickers

extension EditorModel {
    func addText() {
        var layer = TextLayer(text: "Your text")
        layer.center = NPoint(0.5, 0.82)
        mutate { $0.texts.append(layer) }
        selectedText = layer.id
        selectedSticker = nil
        LMHaptics.tap()
    }

    func addSticker(_ emoji: String) {
        var layer = StickerLayer(emoji: emoji)
        layer.center = NPoint(0.5, 0.5)
        mutate { $0.stickers.append(layer) }
        selectedSticker = layer.id
        selectedText = nil
        LMHaptics.tap()
    }
}

struct TextPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showsStickers = false

    private static let emoji = [
        "✨", "🌟", "💫", "🔥", "❤️", "💛", "🌸", "🌿", "🍂", "❄️",
        "☀️", "🌙", "⭐️", "🌈", "☁️", "⚡️", "🌊", "🦋", "🕊️", "🎈",
        "🎉", "🎵", "📍", "👑", "💎", "🪩", "🍀", "🌹", "🦄", "🐚",
    ]

    var body: some View {
        PanelBody {
            OptionChips(
                options: [false, true],
                selection: $showsStickers,
                title: { $0 ? "Stickers" : "Text" }
            )
            PanelNote(text: "Drag a layer on the photo to move it. Pinch to resize and twist to rotate.")
            if showsStickers { stickerSection } else { textSection }
        }
    }

    // MARK: Text

    private var selectedText: TextLayer? {
        let id = model.selectedText ?? model.project.texts.first?.id
        return model.project.texts.first { $0.id == id }
    }

    @ViewBuilder
    private var textSection: some View {
        PanelButton(title: "Add text", symbol: "plus", prominent: true) { model.addText() }
        ForEach(model.project.texts) { layer in
            LayerRow(
                title: layer.text.isEmpty ? "Empty text" : layer.text,
                symbol: "textformat",
                selected: selectedText?.id == layer.id,
                enabled: model.binding(\.texts, id: layer.id, \.enabled, fallback: true),
                onSelect: { model.selectedText = layer.id; model.selectedSticker = nil },
                onDelete: {
                    model.mutate { $0.texts.removeAll { $0.id == layer.id } }
                    if model.selectedText == layer.id { model.selectedText = nil }
                }
            )
        }
        if let layer = selectedText {
            let id = layer.id
            PanelSection(title: "Words") {
                TextField("Your text", text: model.binding(\.texts, id: id, \.text, fallback: ""), axis: .vertical)
                    .font(LM.Font.body)
                    .foregroundStyle(LM.Palette.paper)
                    .lineLimit(1...3)
                    .padding(12)
                    .frame(minHeight: 44)
                    .background(LM.Palette.graphite, in: RoundedRectangle(cornerRadius: LM.Radius.chip, style: .continuous))
            }
            PanelSection(title: "Style") {
                OptionChips(options: TextDesign.allCases, selection: model.binding(\.texts, id: id, \.design, fallback: .serif), title: { Labels.textDesign($0) })
                OptionChips(options: TextWeight.allCases, selection: model.binding(\.texts, id: id, \.weight, fallback: .semibold), title: { Labels.textWeight($0) })
                ParamDial(title: "Size", value: model.binding(\.texts, id: id, \.size, fallback: 0.07), range: 0.02...0.3, defaultValue: 0.07, unit: "%", scale: 100)
                ColorRow(title: "Colour", color: model.binding(\.texts, id: id, \.color, fallback: .white))
                ToggleRow(title: "Shadow", isOn: model.binding(\.texts, id: id, \.shadow, fallback: true))
                ToggleRow(
                    title: "Outline",
                    isOn: Binding(
                        get: { layer.outline != nil },
                        set: { on in
                            model.mutate { project in
                                if let i = project.texts.firstIndex(where: { $0.id == id }) { project.texts[i].outline = on ? RGBAColor.black : nil }
                            }
                        }
                    )
                )
            }
            animationSection(
                entrance: model.binding(\.texts, id: id, \.entrance, fallback: LayerAnimation(kind: .fade, duration: 0.6)),
                exit: model.binding(\.texts, id: id, \.exit, fallback: LayerAnimation(kind: .none, duration: 0.6)),
                idle: model.binding(\.texts, id: id, \.idle, fallback: LayerIdle.none),
                start: model.binding(\.texts, id: id, \.startTime, fallback: 0),
                end: model.binding(\.texts, id: id, \.endTime, fallback: nil)
            )
        }
    }

    // MARK: Stickers

    private var selectedSticker: StickerLayer? {
        let id = model.selectedSticker ?? model.project.stickers.first?.id
        return model.project.stickers.first { $0.id == id }
    }

    @ViewBuilder
    private var stickerSection: some View {
        PanelSection(title: "Add a sticker") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Self.emoji, id: \.self) { symbol in
                    Button { model.addSticker(symbol) } label: {
                        Text(symbol)
                            .font(.system(size: 28))
                            .frame(width: 48, height: 48)
                            .background(LM.Palette.graphite, in: RoundedRectangle(cornerRadius: LM.Radius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Add sticker \(symbol)"))
                }
            }
        }
        ForEach(model.project.stickers) { layer in
            LayerRow(
                title: layer.emoji,
                symbol: "face.smiling",
                selected: selectedSticker?.id == layer.id,
                enabled: model.binding(\.stickers, id: layer.id, \.enabled, fallback: true),
                onSelect: { model.selectedSticker = layer.id; model.selectedText = nil },
                onDelete: {
                    model.mutate { $0.stickers.removeAll { $0.id == layer.id } }
                    if model.selectedSticker == layer.id { model.selectedSticker = nil }
                }
            )
        }
        if let layer = selectedSticker {
            let id = layer.id
            ParamDial(title: "Size", value: model.binding(\.stickers, id: id, \.size, fallback: 0.14), range: 0.03...0.5, defaultValue: 0.14, unit: "%", scale: 100)
            animationSection(
                entrance: model.binding(\.stickers, id: id, \.entrance, fallback: LayerAnimation(kind: .pop, duration: 0.5)),
                exit: model.binding(\.stickers, id: id, \.exit, fallback: LayerAnimation(kind: .none, duration: 0.5)),
                idle: model.binding(\.stickers, id: id, \.idle, fallback: LayerIdle.none),
                start: model.binding(\.stickers, id: id, \.startTime, fallback: 0),
                end: model.binding(\.stickers, id: id, \.endTime, fallback: nil)
            )
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func animationSection(
        entrance: Binding<LayerAnimation>,
        exit: Binding<LayerAnimation>,
        idle: Binding<LayerIdle>,
        start: Binding<Double>,
        end: Binding<Double?>
    ) -> some View {
        PanelSection(title: "Enters") {
            OptionChips(
                options: LayerAnimationKind.allCases,
                selection: Binding(get: { entrance.wrappedValue.kind }, set: { entrance.wrappedValue.kind = $0 }),
                title: { Labels.layerAnimation($0) }
            )
            if entrance.wrappedValue.kind != .none {
                ParamDial(
                    title: "Entrance time",
                    value: Binding(get: { entrance.wrappedValue.duration }, set: { entrance.wrappedValue.duration = $0 }),
                    range: 0.1...3, defaultValue: 0.6, unit: " s", decimals: 1
                )
            }
        }
        PanelSection(title: "Leaves") {
            OptionChips(
                options: LayerAnimationKind.allCases,
                selection: Binding(get: { exit.wrappedValue.kind }, set: { exit.wrappedValue.kind = $0 }),
                title: { Labels.layerAnimation($0) }
            )
            if exit.wrappedValue.kind != .none {
                ParamDial(
                    title: "Exit time",
                    value: Binding(get: { exit.wrappedValue.duration }, set: { exit.wrappedValue.duration = $0 }),
                    range: 0.1...3, defaultValue: 0.6, unit: " s", decimals: 1
                )
            }
        }
        PanelSection(title: "While visible") {
            OptionChips(options: LayerIdle.allCases, selection: idle, title: { Labels.idle($0) })
        }
        PanelSection(title: "Shown from") {
            ParamDial(title: "Starts at", value: start, range: 0...max(model.duration, 1), defaultValue: 0, unit: " s", decimals: 1)
            ToggleRow(
                title: "Until the end of the loop",
                isOn: Binding(
                    get: { end.wrappedValue == nil },
                    set: { untilEnd in end.wrappedValue = untilEnd ? nil : model.duration }
                )
            )
            if end.wrappedValue != nil {
                ParamDial(
                    title: "Ends at",
                    value: Binding(get: { end.wrappedValue ?? model.duration }, set: { end.wrappedValue = $0 }),
                    range: 0...max(model.duration, 1), defaultValue: model.duration, unit: " s", decimals: 1
                )
            }
        }
    }
}
