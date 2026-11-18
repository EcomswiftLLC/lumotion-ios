import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Presets

struct PresetsPanel: View {
    @ObservedObject var model: EditorModel
    @StateObject private var thumbnails = VariantThumbnails()
    @State private var category: PresetCategory?

    private var presets: [PresetInfo] {
        PresetLibrary.all.filter { category == nil || $0.category == category }
    }

    var body: some View {
        PanelBody {
            if PresetLibrary.all.isEmpty {
                PanelNote(text: "No presets are available in this version.")
            } else {
                PanelNote(text: "A preset is a starting point. It sets the motion, weather, camera and look, and you can change anything afterwards.")
                OptionChips(
                    options: [PresetCategory?.none] + PresetCategory.allCases.map { Optional($0) },
                    selection: $category,
                    scrolls: true,
                    title: { $0?.title ?? "All" }
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: LM.Space.s)], alignment: .leading, spacing: LM.Space.m) {
                    ForEach(presets) { preset in
                        ThumbnailTile(
                            title: preset.name,
                            image: thumbnails.images[preset.id],
                            symbol: preset.symbol,
                            selected: model.project.presetID == preset.id,
                            side: 92
                        ) {
                            apply(preset)
                        }
                    }
                }
                if let id = model.project.presetID, let info = PresetLibrary.info(for: id) {
                    PanelNote(text: info.summary)
                }
            }
        }
        .onAppear { generate() }
        .onDisappear { thumbnails.cancel() }
    }

    private func apply(_ preset: PresetInfo) {
        model.mutate { $0 = PresetLibrary.apply(preset.id, to: $0) }
        model.selectedFlow = model.project.flowRegions.first?.id
        model.selectedArrow = nil
        model.selectedEffect = nil
        model.selectedOverlay = nil
        model.paintTarget = nil
        LMHaptics.success()
    }

    private func generate() {
        let base = model.project
        let items: [(key: String, project: Project)] = PresetLibrary.all.map { preset in
            var seed = Project(title: "Preview", source: base.source)
            seed.canvas = base.canvas
            let applied = PresetLibrary.apply(preset.id, to: seed)
            return (preset.id, applied)
        }
        thumbnails.generate(signature: "\(base.id)-\(base.canvas.aspect.rawValue)", items: items, assets: model.assets, longEdge: 200, time: 1.0)
    }
}

// MARK: - Canvas

struct CanvasPanel: View {
    @ObservedObject var model: EditorModel

    private var canvas: CanvasSpec { model.project.canvas }

    var body: some View {
        PanelBody {
            PanelSection(title: "Shape") {
                OptionChips(options: CanvasAspect.allCases, selection: model.binding(\.canvas.aspect), title: { $0.title })
            }
            if canvas.aspect != .original {
                PanelSection(title: "Photo in the frame") {
                    OptionChips(
                        options: CanvasFit.allCases,
                        selection: model.binding(\.canvas.fit),
                        title: { $0 == .fill ? "Fill the frame" : "Show whole photo" }
                    )
                }
            }
            if canvas.fit == .fill {
                ParamDial(title: "Zoom", value: model.binding(\.canvas.zoom), range: 1...4, defaultValue: 1, unit: "x", decimals: 1)
                PanelNote(text: "Drag the preview to move the crop. Pinch to zoom.")
                PanelButton(title: "Reset framing", symbol: "arrow.counterclockwise") {
                    model.mutate { $0.canvas.zoom = 1; $0.canvas.centerX = 0.5; $0.canvas.centerY = 0.5 }
                }
            } else {
                PanelSection(title: "Behind the photo") {
                    OptionChips(
                        options: CanvasBackground.allCases,
                        selection: model.binding(\.canvas.background),
                        title: { $0 == .blur ? "Blurred photo" : "Colour" }
                    )
                    if canvas.background == .color {
                        ColorRow(title: "Background colour", color: model.binding(\.canvas.backgroundColor))
                    }
                }
            }
        }
    }
}

// MARK: - Timing

struct TimingPanel: View {
    @ObservedObject var model: EditorModel

    private var loop: LoopSpec { model.project.loop }

    var body: some View {
        PanelBody {
            if model.isVideoProject {
                PanelNote(text: "The loop length follows the segment you chose in Video: \(LMFormat.seconds(loop.duration)).")
            } else {
                ParamDial(title: "Loop length", value: model.binding(\.loop.duration), range: LoopSpec.durationRange, defaultValue: 4, unit: " s", decimals: 1)
            }
            ParamDial(title: "Speed", value: model.binding(\.loop.speed), range: 0.25...4, defaultValue: 1, unit: "x", decimals: 2)
            PanelSection(title: "Frame rate", detail: "\(loop.frameCount) frames in each loop.") {
                OptionChips(options: LoopSpec.allowedFPS, selection: model.binding(\.loop.fps), title: { "\($0) fps" })
            }
            PanelSection(title: "How it repeats") {
                OptionChips(options: LoopMode.allCases, selection: model.binding(\.loop.mode), title: { Labels.loopMode($0) })
                ToggleRow(title: "Play in reverse", isOn: model.binding(\.loop.reverse))
            }
        }
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @ObservedObject var model: EditorModel
    @State private var importing = false
    @State private var audioLength: Double = 0
    @State private var errorText: String?

    private var audio: AudioTrackSpec? { model.project.audio }

    var body: some View {
        PanelBody {
            if let audio {
                PanelSection(title: audio.displayName) {
                    ToggleRow(title: "Mute", isOn: audioBinding(\.muted))
                    ParamDial(title: "Volume", value: audioBinding(\.volume), range: 0...1, defaultValue: 1, unit: "%", scale: 100)
                }
                if audioLength > 0 {
                    PanelSection(title: "Trim", detail: "Choose which part of the file plays.") {
                        ParamDial(title: "Starts at", value: audioBinding(\.trimStart), range: 0...max(audioLength - 0.5, 0.5), defaultValue: 0, unit: " s", decimals: 1)
                        ParamDial(
                            title: "Ends at",
                            value: Binding(
                                get: { audio.trimEnd ?? audioLength },
                                set: { value in setAudio("audio-end") { $0.trimEnd = value >= audioLength - 0.05 ? nil : value } }
                            ),
                            range: 0.5...audioLength, defaultValue: audioLength, unit: " s", decimals: 1
                        )
                    }
                }
                PanelSection(title: "Fades") {
                    ParamDial(title: "Fade in", value: audioBinding(\.fadeIn), range: 0...5, defaultValue: 0, unit: " s", decimals: 1)
                    ParamDial(title: "Fade out", value: audioBinding(\.fadeOut), range: 0...5, defaultValue: 0.5, unit: " s", decimals: 1)
                    ToggleRow(title: "Repeat to fill the video", isOn: audioBinding(\.loops))
                }
                HStack(spacing: LM.Space.s) {
                    PanelButton(title: "Choose another file", symbol: "folder") { importing = true }
                    PanelButton(title: "Remove audio", symbol: "trash", role: .destructive) { removeAudio() }
                }
                PanelNote(text: "Audio is mixed into exported videos. GIFs and still images have no sound.")
            } else {
                PanelNote(text: "Add a song or sound from the Files app. It plays under your animation in exported videos. Lumotion does not include music.")
                PanelButton(title: "Add audio from Files", symbol: "music.note", prominent: true) { importing = true }
            }
            if let errorText {
                PanelNote(text: errorText, color: LM.Palette.danger)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            attach(url)
        }
        .task(id: model.assets.audioURL) { await loadLength() }
    }

    private func audioBinding<V: Equatable>(_ keyPath: WritableKeyPath<AudioTrackSpec, V>) -> Binding<V> {
        Binding(
            get: { (model.project.audio ?? AudioTrackSpec(fileName: "", displayName: ""))[keyPath: keyPath] },
            set: { value in setAudio("audio-\(keyPath)") { $0[keyPath: keyPath] = value } }
        )
    }

    private func setAudio(_ key: String, _ change: (inout AudioTrackSpec) -> Void) {
        model.mutate(key) { project in
            guard var spec = project.audio else { return }
            change(&spec)
            project.audio = spec
        }
    }

    private func attach(_ url: URL) {
        errorText = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let spec = try model.store.attachAudio(from: url, to: model.project.id)
            model.mutate { $0.audio = spec }
            reloadAssets()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func removeAudio() {
        model.mutate { $0.audio = nil }
        var next = model.assets
        next.audioURL = nil
        model.update(assets: next)
        audioLength = 0
    }

    private func reloadAssets() {
        if let loaded = try? model.store.loadAssets(for: model.project) {
            var next = model.assets
            next.audioURL = loaded.audioURL
            model.update(assets: next)
        }
    }

    private func loadLength() async {
        guard let url = model.assets.audioURL else { audioLength = 0; return }
        let length = await Task.detached(priority: .utility) { () -> Double in
            let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            return seconds.isFinite ? seconds : 0
        }.value
        audioLength = length
    }
}

// MARK: - Layers

struct LayersPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let project = model.project
        PanelBody {
            if isEmpty(project) {
                PanelNote(text: "Nothing has been added yet. Everything you add, such as flow regions, effects, overlays and text, is listed here.")
            }
            if !project.flowRegions.isEmpty {
                PanelSection(title: "Flow") {
                    ForEach(project.flowRegions) { region in
                        LayerRow(
                            title: region.name,
                            symbol: "wind",
                            enabled: model.binding(\.flowRegions, id: region.id, \.enabled, fallback: true),
                            onSelect: { model.selectedFlow = region.id; open(.flow) },
                            onDelete: { model.deleteFlowRegion(region.id) }
                        )
                    }
                }
            }
            if !project.anchors.isEmpty {
                PanelSection(title: "Anchors") {
                    LayerRow(
                        title: "Still areas",
                        subtitle: project.anchors.count == 1 ? "1 stroke" : "\(project.anchors.count) strokes",
                        symbol: "pin",
                        onSelect: { open(.flow) },
                        onDelete: { model.clearStrokes(target: .anchors) }
                    )
                }
            }
            if project.camera.kind != .none || project.parallax.enabled {
                PanelSection(title: "Camera") {
                    if project.camera.kind != .none {
                        LayerRow(
                            title: "Camera: \(Labels.camera(project.camera.kind))",
                            symbol: "camera.aperture",
                            onSelect: { open(.camera) },
                            onDelete: { model.mutate { $0.camera.kind = .none } }
                        )
                    }
                    if project.parallax.enabled {
                        LayerRow(
                            title: "3D depth: \(Labels.parallaxStyle(project.parallax.style))",
                            symbol: "cube.transparent",
                            enabled: model.binding(\.parallax.enabled),
                            onSelect: { open(.depth) }
                        )
                    }
                }
            }
            if !project.livingEffects.isEmpty {
                PanelSection(title: "Effects") {
                    let effects = project.livingEffects
                    ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                        LayerRow(
                            title: Labels.effect(effect.kind),
                            symbol: Labels.effectSymbol(effect.kind),
                            enabled: model.binding(\.livingEffects, id: effect.id, \.enabled, fallback: true),
                            onSelect: { model.selectedEffect = effect.id; open(.effects) },
                            onMoveUp: index > 0 ? { model.mutate { $0.livingEffects.shift(index, by: -1) } } : nil,
                            onMoveDown: index < effects.count - 1 ? { model.mutate { $0.livingEffects.shift(index, by: 1) } } : nil,
                            onDelete: { model.mutate { $0.livingEffects.removeAll { $0.id == effect.id } } }
                        )
                    }
                }
            }
            if !project.overlays.isEmpty {
                PanelSection(title: "Overlays") {
                    let overlays = project.overlays
                    ForEach(Array(overlays.enumerated()), id: \.element.id) { index, layer in
                        LayerRow(
                            title: Labels.overlay(layer.kind),
                            symbol: Labels.overlaySymbol(layer.kind),
                            enabled: model.binding(\.overlays, id: layer.id, \.enabled, fallback: true),
                            onSelect: { model.selectedOverlay = layer.id; open(.overlays) },
                            onMoveUp: index > 0 ? { model.mutate { $0.overlays.shift(index, by: -1) } } : nil,
                            onMoveDown: index < overlays.count - 1 ? { model.mutate { $0.overlays.shift(index, by: 1) } } : nil,
                            onDelete: { model.mutate { $0.overlays.removeAll { $0.id == layer.id } } }
                        )
                    }
                }
            }
            if !project.texts.isEmpty || !project.stickers.isEmpty {
                PanelSection(title: "Text and stickers") {
                    let texts = project.texts
                    ForEach(Array(texts.enumerated()), id: \.element.id) { index, layer in
                        LayerRow(
                            title: layer.text.isEmpty ? "Empty text" : layer.text,
                            symbol: "textformat",
                            enabled: model.binding(\.texts, id: layer.id, \.enabled, fallback: true),
                            onSelect: { model.selectedText = layer.id; model.selectedSticker = nil; open(.text) },
                            onMoveUp: index > 0 ? { model.mutate { $0.texts.shift(index, by: -1) } } : nil,
                            onMoveDown: index < texts.count - 1 ? { model.mutate { $0.texts.shift(index, by: 1) } } : nil,
                            onDelete: { model.mutate { $0.texts.removeAll { $0.id == layer.id } } }
                        )
                    }
                    ForEach(project.stickers) { layer in
                        LayerRow(
                            title: layer.emoji,
                            symbol: "face.smiling",
                            enabled: model.binding(\.stickers, id: layer.id, \.enabled, fallback: true),
                            onSelect: { model.selectedSticker = layer.id; model.selectedText = nil; open(.text) },
                            onDelete: { model.mutate { $0.stickers.removeAll { $0.id == layer.id } } }
                        )
                    }
                }
            }
            if project.audio != nil {
                PanelSection(title: "Audio") {
                    LayerRow(
                        title: project.audio?.displayName ?? "Audio",
                        symbol: "music.note",
                        onSelect: { open(.audio) },
                        onDelete: { model.mutate { $0.audio = nil } }
                    )
                }
            }
        }
    }

    private func isEmpty(_ project: Project) -> Bool {
        project.flowRegions.isEmpty && project.anchors.isEmpty && project.camera.kind == .none && !project.parallax.enabled
            && project.livingEffects.isEmpty && project.overlays.isEmpty && project.texts.isEmpty && project.stickers.isEmpty && project.audio == nil
    }

    private func open(_ tool: EditorTool) {
        withAnimation(.easeOut(duration: 0.2)) { model.tool = tool }
    }
}
