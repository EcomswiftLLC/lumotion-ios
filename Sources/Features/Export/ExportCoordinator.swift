import SwiftUI
import AVFoundation

/// What the person chose on the export screen. The editor turns it into engine export settings.
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
            case .hevc: return "Smaller files, newer devices."
            case .gif: return "Silent and loops forever. Larger files."
            case .still: return "One frame as a photo."
            }
        }
    }

    enum Resolution: Int, CaseIterable, Identifiable {
        case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "2K"
            case .p2160: return "4K"
            }
        }
    }

    enum StillFormat: String, CaseIterable, Identifiable {
        case jpeg, png, heic
        var id: String { rawValue }
        var title: String { rawValue == "jpeg" ? "JPG" : rawValue.uppercased() }
    }

    var format: Format = .h264
    var resolution: Resolution = .p1080
    /// Width in pixels for GIF exports.
    var gifWidth: Int = 480
    var still: StillFormat = .jpeg
    /// Which moment of the loop a still comes from, 0...1.
    var stillPosition: Double = 0
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
/// and kept so saving and then sharing the same result renders once.
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
    @Published var shareURL: URL?
    @Published var filesURL: URL?
    @Published private(set) var photosDenied = false

    /// Set by the editor. Reports progress 0...1 and honours task cancellation.
    var renderer: Renderer?
    /// Wording for the size estimate under the options, or nil when it is not known.
    var estimate: ((ExportChoice) -> String?)?
    var supportsHEVC: Bool = {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }()

    private var cached: (ExportChoice, ExportItem)?
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .rendering }

    func perform(_ action: Action) {
        guard !isBusy else { return }
        RewardedGate.shared.requestExport { [weak self] in
            self?.start(action)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func clearStatus() {
        if phase != .rendering { phase = .idle }
        photosDenied = false
    }

    private func start(_ action: Action) {
        task?.cancel()
        task = Task { await run(action) }
    }

    private func run(_ action: Action) async {
        phase = .rendering
        progress = 0
        photosDenied = false
        do {
            let item = try await itemForCurrentChoice()
            try Task.checkCancellation()
            switch action {
            case .photos:
                try await LibrarySaver.save(item)
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
            phase = .idle
        } catch LibrarySaver.SaveError.denied {
            photosDenied = true
            phase = .failed("Allow Photos access in Settings to save. You can still share it.")
        } catch let failure as ExportFailure {
            phase = .failed(failure.text)
        } catch {
            phase = .failed("The export did not finish. Try a lower resolution, or free some space and try again.")
        }
    }

    private func itemForCurrentChoice() async throws -> ExportItem {
        if let cached, cached.0 == choice, FileManager.default.fileExists(atPath: cached.1.url.path) {
            return cached.1
        }
        guard let renderer else { throw ExportFailure.unavailable }
        let item = try await renderer(choice) { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        cached = (choice, item)
        return item
    }
}
