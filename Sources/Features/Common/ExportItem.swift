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

    /// Folder for files that are written only so they can be shared. Cleared when the app starts.
    static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumotionShare", isDirectory: true)
    }

    /// Deletes files left over from earlier exports. Call before writing new ones and when the app starts.
    static func clearShareFolder() {
        try? FileManager.default.removeItem(at: shareFolder)
    }

    /// A fresh file URL inside the share folder, for example `makeURL(base: "Lumotion", ext: "mp4")`.
    static func makeURL(base: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: shareFolder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000) % 100_000_000
        return shareFolder.appendingPathComponent("\(base)-\(stamp).\(ext)")
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

    /// Adds the file to the photo library. Needs the "add only" permission, which the system asks for once.
    static func save(_ item: ExportItem) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
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

/// The system share sheet (Messages, WhatsApp, Instagram, TikTok and so on).
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Save to Files": the system document picker in export mode.
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
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
