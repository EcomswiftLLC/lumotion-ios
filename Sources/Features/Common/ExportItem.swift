import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers

/// One finished file, ready to be saved to Photos, shared or put in Files. Exports are written to disk by the engine
/// (video and GIF files can be large), so the item points at a file instead of holding the bytes.
struct ExportItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case video, gif, still

        var utType: UTType {
            switch self {
            case .video: return .mpeg4Movie
            case .gif: return .gif
            case .still: return .jpeg
            }
        }
    }

    let id = UUID()
    let url: URL
    let kind: Kind
    /// Overrides the type for stills (PNG or HEIC).
    var typeOverride: UTType? = nil

    var utType: UTType { typeOverride ?? UTType(filenameExtension: url.pathExtension) ?? kind.utType }
    var filename: String { url.lastPathComponent }

    var byteCount: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Deletes the file behind this item (used when a newer export replaces it).
    func deleteFile() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Plain wording for sizes and durations.
enum LMFormat {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "4.0 s"
    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    /// "0:04"
    static func clock(_ value: Double) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum LibrarySaver {
    enum SaveError: Error { case denied, failed }

    /// True when Lumotion may add to the library. Asks the system the first time, so call it before the slow work starts.
    static func ensureAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Adds the file to the photo library. Needs the "add only" permission (see `ensureAccess`).
    static func save(_ item: ExportItem) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        let url = item.url
        let kind = item.kind
        let identifier = item.utType.identifier
        try await PHPhotoLibrary.shared().performChanges {
            switch kind {
            case .video:
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            case .gif, .still:
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = identifier
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: url, options: options)
            }
        }
    }
}

/// The system share sheet (Messages, WhatsApp, Instagram, TikTok and so on). `onFinish` runs when it closes for any reason.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Save to Files": the system document picker in export mode. `onFinish` runs when a place was chosen or the picker was cancelled.
struct FilesExporter: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}
