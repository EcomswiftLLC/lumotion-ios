import SwiftUI
import AVFoundation

/// What the person chose on the export screen. The editor turns it into engine calls (see `EditorModel.makeExportRenderer`).
struct ExportChoice: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case h264, hevc, gif, still
        var id: String { rawValue }

        var title: String {
            switch self {
            case .h264: return "Video (H.264)"
            case .hevc: return "Video (HEVC)"
            case .gif: return "GIF"
            case .still: return "Still image"
            }
        }

        var detail: String {
            switch self {
            case .h264: return "Plays everywhere. Best for sharing."
            case .hevc: return "Smaller files on newer devices."
            case .gif: return "Silent, loops forever, larger files."
            case .still: return "One frame saved as a photo."
            }
        }
    }

    var format: Format = .h264
    var resolution: ExportResolution = .p1080
    var gif = GIFOptions()
    var still: StillFormat = .jpg
    /// Which moment of the loop a still comes from, 0...1.
    var stillPosition: Double = 0

    var codec: VideoCodec? {
        switch format {
        case .h264: return .h264
        case .hevc: return .hevc
        default: return nil
        }
    }
}

extension StillFormat {
    var chipTitle: String { rawValue.uppercased() }
}

enum ExportFailure: Error {
    case unavailable
    case message(String)

    var text: String {
        switch self {
        case .unavailable: return "Export is not available for this project yet."
        case .message(let text): return text
        }
    }
}

/// Runs an export and the action that follows it (Photos, Share or Files). The rewarded ad comes first: every action goes
/// through `RewardedGate`, which lets the export straight through when no ad is ready. The file is made after the ad,
/// and kept while the project is unchanged, so saving and then sharing the same result renders once.
///
/// Only one export task exists at a time. Cancelling hides the progress straight away, but a new export cannot start until
/// the cancelled task has really stopped, and results from a cancelled run are ignored (see `generation`).
@MainActor
final class ExportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle, rendering
        case saved(String)
        case failed(String)
    }

    enum Action { case photos, share, files }

    typealias Renderer = (ExportChoice, @escaping @Sendable (Double) -> Void) async throws -> ExportItem

    @Published var choice = ExportChoice()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    /// Rough seconds left, once enough of the export is done to tell.
    @Published private(set) var remainingSeconds: Double?
    @Published var shareURL: URL?
    @Published var filesURL: URL?
    @Published private(set) var photosDenied = false
    /// True while a cancelled task is still stopping.
    @Published private(set) var winding = false
    /// True while the Photos permission is being checked.
    @Published private(set) var checkingAccess = false

    /// Set by the editor. Reports progress 0...1 and honours task cancellation.
    var renderer: Renderer?
    /// Wording for the size estimate under the options, or nil when it is not known.
    var estimate: ((ExportChoice) -> String?)?
    /// A heads-up for exports that take long, or nil.
    var warning: ((ExportChoice) -> String?)?
    /// Longest side of the project in pixels, so resolutions larger than the source are not offered.
    var sourceLongSide: Int = 4096
    var supportsHEVC: Bool = {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }()

    private var cached: (choice: ExportChoice, item: ExportItem)?
    private var generation = 0
    /// Counts changes to the project, so a file made from an older state is never kept.
    private var revision = 0
    private var task: Task<Void, Never>?
    private var startedAt = Date()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var expiredInBackground = false
    private var wentToBackground = false
    private var previousIdleTimer = false

    var isBusy: Bool { phase == .rendering || winding || checkingAccess }
    var isStopping: Bool { winding && phase != .rendering }

    // MARK: Choices

    /// Resolutions the device can encode with the codec and that the project is large enough to fill.
    func offeredResolutions(for codec: VideoCodec) -> [ExportResolution] {
        let supported = Exporter.supportedResolutions(codec: codec)
        let fitting = supported.filter { $0.longEdge <= max(1280, sourceLongSide) }
        return fitting.isEmpty ? supported : fitting
    }

    /// Keeps the chosen resolution inside what is offered, so what the screen shows is what gets exported and estimated.
    func clampChoice() {
        guard let codec = choice.codec else { return }
        let offered = offeredResolutions(for: codec)
        guard !offered.isEmpty, !offered.contains(choice.resolution) else { return }
        choice.resolution = offered.last(where: { $0.longEdge <= choice.resolution.longEdge }) ?? offered[0]
    }

    /// The project changed, so a file made earlier no longer matches it.
    func invalidateCache() {
        revision += 1
        cached?.item.deleteFile()
        cached = nil
    }

    // MARK: Running

    func perform(_ action: Action) {
        guard !isBusy else { return }
        clampChoice()
        if action == .photos {
            // Ask for Photos access first, so nobody watches an ad and waits for a render just to be told no.
            checkingAccess = true
            Task {
                let allowed = await LibrarySaver.ensureAccess()
                checkingAccess = false
                guard allowed else {
                    photosDenied = true
                    phase = .failed(Self.deniedText)
                    return
                }
                gate(action)
            }
        } else {
            gate(action)
        }
    }

    private static let deniedText = "Lumotion needs permission to add to Photos. Allow it in Settings, or choose Share or Save to Files instead."

    private func gate(_ action: Action) {
        RewardedGate.shared.requestExport { [weak self] in
            self?.start(action)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        phase = .idle
        progress = 0
        remainingSeconds = nil
    }

    func clearStatus() {
        if phase != .rendering { phase = .idle }
        photosDenied = false
    }

    private func start(_ action: Action) {
        guard !isBusy else { return }
        generation += 1
        let id = generation
        winding = true
        phase = .rendering
        progress = 0
        remainingSeconds = nil
        photosDenied = false
        startedAt = Date()
        expiredInBackground = false
        wentToBackground = false
        beginProtection()
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(action, generation: id)
            self.endProtection()
            self.winding = false
            Exporter.clearOldExports()
        }
    }

    private func run(_ action: Action, generation id: Int) async {
        do {
            let item = try await itemForCurrentChoice(generation: id)
            try Task.checkCancellation()
            guard id == generation else { return }
            switch action {
            case .photos:
                try await LibrarySaver.save(item)
                guard id == generation else { return }
                LMHaptics.success()
                phase = .saved(item.kind == .video ? "Saved to Photos. Find it in Recents." : "Saved to Photos.")
            case .share:
                phase = .idle
                shareURL = item.url
            case .files:
                phase = .idle
                filesURL = item.url
            }
        } catch is CancellationError {
            finishCancelled(id)
        } catch EngineError.cancelled {
            finishCancelled(id)
        } catch LibrarySaver.SaveError.denied {
            guard id == generation else { return }
            photosDenied = true
            phase = .failed(Self.deniedText)
        } catch let failure as ExportFailure {
            guard id == generation else { return }
            phase = .failed(failure.text)
        } catch {
            guard id == generation else { return }
            phase = .failed(wentToBackground ? Self.backgroundText : "The export did not finish. Try a lower resolution, or free some space and try again.")
        }
    }

    private static let backgroundText = "Keep Lumotion open while exporting. The export stopped when the app went to the background. Try again."

    /// The export screen reports when the app leaves the foreground, so a stopped export can say why.
    func sceneChanged(active: Bool) {
        if !active && phase == .rendering { wentToBackground = true }
    }

    private func finishCancelled(_ id: Int) {
        guard id == generation else { return }
        if expiredInBackground {
            phase = .failed(Self.backgroundText)
        } else {
            phase = .idle
        }
    }

    private func itemForCurrentChoice(generation id: Int) async throws -> ExportItem {
        if let cached, cached.choice == choice, FileManager.default.fileExists(atPath: cached.item.url.path) {
            return cached.item
        }
        guard let renderer else { throw ExportFailure.unavailable }
        let requested = choice
        let startRevision = revision
        let item = try await renderer(requested) { [weak self] value in
            Task { @MainActor in self?.report(value, generation: id) }
        }
        guard id == generation else {
            // The person cancelled while the file was being finished: nobody wants it.
            item.deleteFile()
            throw CancellationError()
        }
        guard startRevision == revision else {
            // The project changed while this was rendering: use the file once, but do not keep it for later.
            return item
        }
        if let old = cached?.item, old.url != item.url { old.deleteFile() }
        cached = (requested, item)
        return item
    }

    private func report(_ value: Double, generation id: Int) {
        guard id == generation, phase == .rendering else { return }
        progress = max(progress, min(max(value, 0), 1))
        if progress > 0.04 {
            let elapsed = Date().timeIntervalSince(startedAt)
            remainingSeconds = elapsed / progress * (1 - progress)
        }
    }

    // MARK: Keeping the export alive

    /// The screen must not lock mid-export, and the app asks for the little extra time iOS gives when it goes to the background.
    private func beginProtection() {
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Lumotion export") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    private func endProtection() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func backgroundTimeExpired() {
        expiredInBackground = true
        task?.cancel()
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}

extension ExportChoice.Format {
    var videoCodec: VideoCodec? {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        default: return nil
        }
    }
}
