import SwiftUI
import UIKit
import AVFoundation

/// What the brush on the canvas is painting right now.
enum PaintTarget: Hashable {
    case flow(UUID)
    case anchors
    case cinemagraph
    case depth
    case effect(UUID)
}

enum PaintTool: String, CaseIterable, Identifiable {
    case paint, erase, arrow
    var id: String { rawValue }
}

/// The playback position and the current preview picture. They change about thirty times a second, so they live in their
/// own object that only the canvas and the transport bar observe. Everything else in the editor stays still while playing.
@MainActor
final class PlaybackState: ObservableObject {
    @Published var time: Double = 0
    @Published var frame: UIImage?
}

/// The state behind the editor: the project being edited, the engine that renders it, undo and redo, autosave, and the
/// playback clock that drives the live preview. Every change goes through `mutate`, so undo, redo, autosave and the
/// preview all see it.
@MainActor
final class EditorModel: ObservableObject {
    let store: ProjectStore
    let engine: RenderEngine
    let playback = PlaybackState()

    @Published private(set) var project: Project
    @Published private(set) var assets: SourceAssets

    /// Called whenever the project or its assets change, so a file exported earlier can be discarded.
    var onChange: (@MainActor () -> Void)?

    // Playback
    @Published var isPlaying: Bool
    @Published var showingOriginal = false

    /// Playback position in seconds. Not published: views that show it observe `playback`.
    var time: Double {
        get { playback.time }
        set { playback.time = newValue }
    }
    /// The current preview picture. Not published: views that show it observe `playback`.
    var frame: UIImage? { playback.frame }

    // Tools
    @Published var tool: EditorTool? {
        didSet {
            guard tool != oldValue else { return }
            if tool == nil || !(tool == .flow || tool == .depth || tool == .video || tool == .effects) { paintTarget = nil }
            markDirty()
        }
    }
    @Published var paintTarget: PaintTarget? {
        didSet { if paintTarget != oldValue { markDirty() } }
    }
    @Published var paintTool: PaintTool = .paint
    /// Brush radius as a fraction of the long edge, and feather 0...1.
    @Published var brushRadius: Double = 0.04
    @Published var brushFeather: Double = 0.5
    /// Depth value painted by the manual depth brush: 1 near, 0 far.
    @Published var depthValue: Double = 1

    // Selection
    @Published var selectedFlow: UUID?
    @Published var selectedArrow: Int?
    @Published var selectedEffect: UUID?
    @Published var selectedOverlay: UUID?
    @Published var selectedText: UUID?
    @Published var selectedSticker: UUID?

    // History
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var saveFailed = false
    @Published private(set) var maskBusy = false
    /// True once subject detection has run for this photo (it may still have found nothing).
    @Published private(set) var subjectChecked = false

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastKey: String?
    private var lastKeyDate = Date.distantPast
    private var saveTask: Task<Void, Never>?

    // Preview clock
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var renderInFlight = false
    private var dirty = true
    private var scrubbing = false

    init(project: Project, assets: SourceAssets, store: ProjectStore = .shared) {
        self.project = project
        self.assets = assets
        self.store = store
        self.engine = RenderEngine(project: project, assets: assets)
        self.isPlaying = !UIAccessibility.isReduceMotionEnabled
    }

    // MARK: Derived

    var duration: Double { project.loop.clampedDuration }
    var isVideoProject: Bool { project.source.kind == .video }

    /// Width divided by height of the canvas, used to size the preview.
    var canvasAspect: Double {
        let size = engine.canvasSize(longEdge: 1000)
        return Double(size.width) / Double(max(1, size.height))
    }

    /// While painting, the preview shows the still, framed picture so strokes can be placed accurately.
    var displaysOriginal: Bool { showingOriginal || paintTarget != nil }

    // MARK: Changing the project

    /// Applies a change to the project. `key` groups quick repeated changes (a dial being dragged) into one undo step.
    func mutate(_ key: String? = nil, _ change: (inout Project) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        let now = Date()
        if let key, key == lastKey, now.timeIntervalSince(lastKeyDate) < 1.0 {
            // Same control, moments apart: stays one undo step.
        } else {
            undoStack.append(project)
            if undoStack.count > 120 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastKey = key
        lastKeyDate = now
        project = next
        projectChanged()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        lastKey = nil
        projectChanged()
        LMHaptics.tap()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        lastKey = nil
        projectChanged()
        LMHaptics.tap()
    }

    private func projectChanged() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        syncAudioAsset()
        engine.update(project: project)
        let length = project.loop.clampedDuration
        if time >= length { time = 0 }
        markDirty()
        scheduleSave()
        onChange?()
    }

    /// Keeps the audio file the engine plays in step with `project.audio`, including after undo and redo.
    private func syncAudioAsset() {
        var wanted: URL?
        if let name = project.audio?.fileName, !name.isEmpty {
            let url = store.fileURL(name, in: project.id)
            if FileManager.default.fileExists(atPath: url.path) { wanted = url }
        }
        guard wanted != assets.audioURL else { return }
        var next = assets
        next.audioURL = wanted
        assets = next
        engine.update(assets: next)
    }

    /// Adds a new audio file as one undoable step. Each file gets its own name, so undo can bring the previous one back.
    func attachAudio(from url: URL) throws {
        var spec = try store.attachAudio(from: url, to: project.id)
        let folder = store.folderURL(for: project.id)
        let ext = (spec.fileName as NSString).pathExtension
        let unique = "audio-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        try FileManager.default.moveItem(at: folder.appendingPathComponent(spec.fileName), to: folder.appendingPathComponent(unique))
        spec.fileName = unique
        mutate { $0.audio = spec }
    }

    /// Deletes audio files in the project folder that the project no longer uses. Called when the editor closes, when undo is over.
    private func purgeUnusedAudio() {
        let folder = store.folderURL(for: project.id)
        let keep = project.audio?.fileName
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("audio") && name != keep {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// A binding to one value of the project. Changes made while a dial is dragged share one undo step.
    func binding<V: Equatable>(_ keyPath: WritableKeyPath<Project, V>) -> Binding<V> {
        let key = "\(keyPath)"
        return Binding(
            get: { self.project[keyPath: keyPath] },
            set: { newValue in self.mutate(key) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A binding to one value of an element of an array in the project, found by id. Reading a removed element gives `fallback`.
    func binding<E: Identifiable, V: Equatable>(
        _ array: WritableKeyPath<Project, [E]>,
        id: E.ID,
        _ keyPath: WritableKeyPath<E, V>,
        fallback: V
    ) -> Binding<V> {
        let key = "\(array)/\(id)/\(keyPath)"
        return Binding(
            get: { self.project[keyPath: array].first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                self.mutate(key) { project in
                    guard let index = project[keyPath: array].firstIndex(where: { $0.id == id }) else { return }
                    project[keyPath: array][index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    // MARK: Assets

    func update(assets newAssets: SourceAssets) {
        assets = newAssets
        engine.update(assets: newAssets)
        markDirty()
        onChange?()
    }

    /// Finds the subject of the photo with Vision the first time something needs it. Does nothing when no subject is found.
    func ensureSubjectMask() {
        guard assets.subjectMask == nil, !maskBusy, let still = assets.still else { return }
        maskBusy = true
        Task {
            let mask = await MaskProvider.subjectMask(for: still)
            maskBusy = false
            subjectChecked = true
            guard let mask else { return }
            var next = assets
            next.subjectMask = mask
            update(assets: next)
            store.saveMasks(subject: mask, depth: assets.embeddedDepth, for: project.id)
        }
    }

    // MARK: Playback

    func startPreview() {
        guard link == nil else { return }
        let proxy = DisplayLinkProxy(self)
        let displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        lastTimestamp = 0
        markDirty()
    }

    func stopPreview() {
        link?.invalidate()
        link = nil
    }

    func markDirty() { dirty = true }

    func togglePlay() {
        isPlaying.toggle()
        if isPlaying { markDirty() }
        LMHaptics.tap()
    }

    func scrub(to newTime: Double, editing: Bool) {
        scrubbing = editing
        time = min(max(newTime, 0), max(duration - 0.001, 0))
        markDirty()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let delta = lastTimestamp == 0 ? 0 : min(now - lastTimestamp, 0.25)
        lastTimestamp = now
        if isPlaying && !scrubbing && !displaysOriginal {
            time = (time + delta).truncatingRemainder(dividingBy: max(duration, 0.2))
            dirty = true
        }
        if dirty && !renderInFlight { renderNow() }
    }

    private func renderNow() {
        renderInFlight = true
        dirty = false
        let engine = self.engine
        let at = time
        let original = displaysOriginal
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = original ? engine.originalFrame(quality: .preview) : engine.previewFrame(time: at)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let image { self.playback.frame = UIImage(cgImage: image) }
                    self.renderInFlight = false
                }
            }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(project)
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    /// Saves everything and the gallery thumbnail. Called when the editor closes.
    func flush() {
        saveTask?.cancel()
        stopPreview()
        saveNow()
        purgeUnusedAudio()
        let snapshot = engine
        let id = project.id
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            if let thumbnail = snapshot.renderFrame(time: 0, quality: RenderQuality(longEdge: 480)) {
                store.saveThumbnail(thumbnail, for: id)
            }
        }
    }

    // MARK: Export

    /// Builds the closure the export screen uses to make files from the project as it is now.
    func makeExportRenderer() -> ExportCoordinator.Renderer {
        return { [weak self] choice, progress in
            guard let self else { throw ExportFailure.unavailable }
            let exporter = Exporter(project: self.project, assets: self.assets)
            let duration = self.project.loop.clampedDuration
            return try await withTaskCancellationHandler {
                switch choice.format {
                case .h264, .hevc:
                    let url = try await exporter.exportMP4(codec: choice.format == .hevc ? .hevc : .h264, size: choice.resolution, progress: progress)
                    return ExportItem(url: url, kind: .video)
                case .gif:
                    let url = try await exporter.exportGIF(options: choice.gif.clamped, progress: progress)
                    return ExportItem(url: url, kind: .gif)
                case .still:
                    let url = try await exporter.exportStill(format: choice.still, time: choice.stillPosition * duration, longEdge: nil)
                    return ExportItem(url: url, kind: .still)
                }
            } onCancel: {
                exporter.cancel()
            }
        }
    }

    /// A heads-up before exports that take a while: big pictures, high frame rates and long loops.
    func exportWarning(for choice: ExportChoice) -> String? {
        let seconds = project.loop.clampedDuration
        var reasons: [String] = []
        switch choice.format {
        case .h264, .hevc:
            if choice.resolution == .k4 { reasons.append("4K size") } else if choice.resolution == .k2 { reasons.append("2K size") }
            if project.loop.fps >= 60 { reasons.append("60 frames per second") }
            if seconds > 10 { reasons.append("a loop of \(Int(seconds.rounded())) seconds") }
        case .gif:
            if seconds * Double(choice.gif.clamped.fps) > 300 { reasons.append("a long GIF") }
        case .still:
            break
        }
        guard !reasons.isEmpty else { return nil }
        return "This export is large (\(reasons.joined(separator: ", "))). It can take several minutes. Keep Lumotion open and the screen on until it finishes."
    }

    func exportEstimate(for choice: ExportChoice) -> String? {
        let exporter = Exporter(project: project, assets: assets)
        let estimate: ExportEstimate
        switch choice.format {
        case .h264, .hevc: estimate = exporter.estimateMP4(codec: choice.format == .hevc ? .hevc : .h264, size: choice.resolution)
        case .gif: estimate = exporter.estimateGIF(options: choice.gif.clamped)
        case .still: return nil
        }
        guard estimate.bytes > 0 else { return nil }
        var text = "About \(LMFormat.bytes(Int(estimate.bytes)))"
        if estimate.width > 0 { text += ", \(estimate.width) by \(estimate.height) pixels" }
        if estimate.frameCount > 0 { text += ", \(estimate.frameCount) frames" }
        text += "."
        if let note = estimate.note { text += " " + note }
        return text
    }
}

/// Holds the display link weakly so the link does not keep the model alive.
private final class DisplayLinkProxy: NSObject {
    weak var model: EditorModel?

    init(_ model: EditorModel) { self.model = model }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            if let model { model.tick(link) }
        }
    }
}
