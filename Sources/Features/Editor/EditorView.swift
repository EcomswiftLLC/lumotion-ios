import SwiftUI

/// Opens the project for a source (a new photo or video, or a saved project) and shows the editor, or says why it could not.
@MainActor
final class EditorHost: ObservableObject {
    enum State {
        case loading
        case ready(EditorModel)
        case failed(String)
    }

    @Published var state: State = .loading

    init() {}

    /// Debug screenshots only: starts with a ready model.
    init(ready model: EditorModel) { state = .ready(model) }

    func load(_ source: EditorSource) async {
        if case .ready = state { return }
        let store = ProjectStore.shared
        do {
            let created: (project: Project, assets: SourceAssets)
            switch source {
            case .photo(let photo):
                let image = photo.image
                let data = photo.data
                let title: String? = photo.name == "Photo" || photo.name == "Camera" ? nil : photo.name
                created = try await Task.detached(priority: .userInitiated) {
                    try store.createPhotoProject(image: image, originalData: data, title: title)
                }.value
            case .video(let url):
                created = try await store.createVideoProject(videoURL: url, title: nil)
            case .existing(let id):
                let project = try await Task.detached(priority: .userInitiated) { try store.load(id: id) }.value
                let assets = try await Task.detached(priority: .userInitiated) { try store.loadAssets(for: project) }.value
                created = (project, assets)
            }
            state = .ready(EditorModel(project: created.project, assets: created.assets, store: store))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct EditorView: View {
    let source: EditorSource

    @StateObject private var host: EditorHost
    @Environment(\.dismiss) private var dismiss

    init(source: EditorSource) {
        self.source = source
        _host = StateObject(wrappedValue: EditorHost())
    }

    #if DEBUG
    init(source: EditorSource, debugModel: EditorModel) {
        self.source = source
        _host = StateObject(wrappedValue: EditorHost(ready: debugModel))
    }
    #endif

    var body: some View {
        Group {
            switch host.state {
            case .loading:
                VStack(spacing: LM.Space.m) {
                    ProgressView().tint(LM.Palette.glow)
                    Text("Opening your project").font(LM.Font.callout).foregroundStyle(LM.Palette.mist)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: LM.Space.m) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(LM.Palette.danger)
                        .accessibilityHidden(true)
                    Text("This project could not be opened").font(LM.Font.title(22)).foregroundStyle(LM.Palette.paper)
                        .multilineTextAlignment(.center)
                    Text(message).font(LM.Font.callout).foregroundStyle(LM.Palette.mist)
                        .multilineTextAlignment(.center)
                    Button("Back to Home") { dismiss() }.buttonStyle(.apPrimary)
                }
                .padding(LM.Space.l)
                .readableWidth(520)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let model):
                EditorContent(model: model) {
                    model.flush()
                    dismiss()
                }
            }
        }
        .apScreen()
        .preferredColorScheme(.dark)
        .task { await host.load(source) }
    }
}

struct EditorContent: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void

    @StateObject private var exporter = ExportCoordinator()
    @State private var exportShown = false
    @Environment(\.scenePhase) private var scenePhase

    private var tools: [EditorTool] {
        EditorTool.allCases.filter { tool in
            switch tool {
            case .video: return model.isVideoProject
            case .depth: return !model.isVideoProject
            default: return true
            }
        }
    }

    var body: some View {
        EditorScaffold(
            hasPanel: model.tool != nil,
            topBar: { topBar },
            canvas: { CanvasStage(model: model) },
            transport: { TransportBar(model: model) },
            panel: { EditorPanel(model: model) },
            dock: { axis in
                EditorDock(tools: tools, selected: model.tool, axis: axis) { picked in
                    withAnimation(.easeOut(duration: 0.2)) { model.tool = model.tool == picked ? nil : picked }
                }
            }
        )
        .onAppear {
            model.startPreview()
            exporter.renderer = model.makeExportRenderer()
            exporter.estimate = { [weak model] choice in model?.exportEstimate(for: choice) }
            exporter.resolutions = { [weak model] codec in model?.availableResolutions(codec: codec) ?? [.p720] }
            exporter.warning = { [weak model] choice in model?.exportWarning(for: choice) }
            exporter.sourceLongSide = max(model.project.source.pixelWidth, model.project.source.pixelHeight)
            model.onChange = { [weak exporter] in exporter?.invalidateCache() }
        }
        .onDisappear { model.stopPreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        .sheet(isPresented: $exportShown, onDismiss: { model.startPreview() }) {
            ExportScreen(
                coordinator: exporter,
                previewImage: model.frame,
                hasAudio: model.project.audio != nil && model.assets.audioURL != nil && model.project.audio?.muted == false,
                sourceLongSide: max(model.project.source.pixelWidth, model.project.source.pixelHeight)
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            LMIconButton(symbol: "xmark", label: "Close editor", action: onClose)
            LMIconButton(symbol: "arrow.uturn.backward", label: "Undo", disabled: !model.canUndo) { model.undo() }
            LMIconButton(symbol: "arrow.uturn.forward", label: "Redo", disabled: !model.canRedo) { model.redo() }
            Spacer(minLength: 0)
            if model.saveFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LM.Palette.danger)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text("Your project could not be saved. Check that the device has free storage."))
            }
            Button {
                model.tool = nil
                model.paintTarget = nil
                model.stopPreview()
                model.saveNow()
                exportShown = true
            } label: {
                Text("Export")
                    .font(LM.Font.headline)
                    .foregroundStyle(LM.Palette.onGlow)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(LM.Palette.glow, in: Capsule())
            }
            .accessibilityLabel(Text("Export"))
        }
        .padding(.horizontal, LM.Space.s)
        .frame(height: 52)
    }
}

/// Play, scrub, and hold-to-compare under the preview.
struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: LM.Space.s) {
            LMIconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play") {
                model.togglePlay()
            }
            TransportScrubber(model: model, playback: model.playback)
            compare
        }
        .padding(.horizontal, LM.Space.s)
        .frame(minHeight: 48)
    }

    /// Press and hold to see the photo without any animation.
    private var compare: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(model.showingOriginal ? LM.Palette.glow : LM.Palette.paper)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.showingOriginal { model.showingOriginal = true; model.markDirty() } }
                    .onEnded { _ in model.showingOriginal = false; model.markDirty() }
            )
            .accessibilityLabel(Text("Hold to compare with the original"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Show original")) { model.showingOriginal = true; model.markDirty() }
            .accessibilityAction(named: Text("Show animation")) { model.showingOriginal = false; model.markDirty() }
    }
}

/// The position slider and time. Observes the playback state, which changes while the loop plays.
struct TransportScrubber: View {
    let model: EditorModel
    @ObservedObject var playback: PlaybackState

    var body: some View {
        HStack(spacing: LM.Space.s) {
            Slider(
                value: Binding(get: { playback.time }, set: { model.scrub(to: $0, editing: true) }),
                in: 0...max(model.duration, 0.1),
                onEditingChanged: { editing in model.scrub(to: playback.time, editing: editing) }
            )
            .tint(LM.Palette.glow)
            .accessibilityLabel(Text("Position in the loop"))
            .accessibilityValue(Text("\(LMFormat.seconds(playback.time)) of \(LMFormat.seconds(model.duration))"))
            Text("\(LMFormat.seconds(playback.time))")
                .font(LM.Font.number)
                .foregroundStyle(LM.Palette.mist)
                .frame(minWidth: 52, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// The panel for the selected tool.
struct EditorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: LM.Space.m) {
            if let tool = model.tool {
                HStack {
                    Text(tool.title)
                        .font(LM.Font.title(20))
                        .foregroundStyle(LM.Palette.paper)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    LMIconButton(symbol: "chevron.down", label: "Close \(tool.title) panel") {
                        withAnimation(.easeOut(duration: 0.2)) { model.tool = nil }
                    }
                }
                .padding(.horizontal, LM.Space.m)
                content(for: tool)
            } else {
                PanelBody {
                    PanelNote(text: "Choose a tool below. Presets is a quick way to start.")
                }
            }
        }
    }

    @ViewBuilder
    private func content(for tool: EditorTool) -> some View {
        switch tool {
        case .presets: PresetsPanel(model: model)
        case .flow: FlowPanel(model: model)
        case .video: VideoPanel(model: model)
        case .camera: CameraPanel(model: model)
        case .depth: DepthPanel(model: model)
        case .effects: EffectsPanel(model: model)
        case .overlays: OverlaysPanel(model: model)
        case .looks: LooksPanel(model: model)
        case .text: TextPanel(model: model)
        case .audio: AudioPanel(model: model)
        case .canvas: CanvasPanel(model: model)
        case .timing: TimingPanel(model: model)
        case .layers: LayersPanel(model: model)
        }
    }
}
