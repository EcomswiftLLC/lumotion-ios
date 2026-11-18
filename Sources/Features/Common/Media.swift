import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// A photo the person chose, decoded upright and capped in size so a huge panorama cannot exhaust memory.
struct PhotoSource {
    let image: CGImage
    /// The file bytes the image was decoded from (JPEG, HEIC or PNG), kept so the project can store the source.
    let data: Data
    let name: String

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// What the editor was opened with.
enum EditorSource {
    case photo(PhotoSource)
    /// A video file copied into the app's temporary folder, for a cinemagraph.
    case video(URL)
}

/// Identifiable wrapper so `fullScreenCover(item:)` can present the editor.
struct EditorSession: Identifiable {
    let id = UUID()
    let source: EditorSource
}

/// A video handed over by the Photos picker, copied to a file the app owns.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionImport", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum MediaLoader {
    /// Longest side kept for a photo in the editor.
    static let maxPhotoPixel = 4096

    /// Decodes photo bytes upright, at most `maxPixel` on the long side. Runs on whatever thread calls it.
    static func decodePhoto(_ data: Data, name: String, maxPixel: Int = maxPhotoPixel) -> PhotoSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? maxPixel
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? maxPixel
        let limit = max(64, min(maxPixel, max(width, height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PhotoSource(image: image, data: data, name: name)
    }

    static func photo(from item: PhotosPickerItem) async -> PhotoSource? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) { decodePhoto(data, name: "Photo") }.value
    }

    static func movie(from item: PhotosPickerItem) async -> URL? {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
        return movie.url
    }

    /// A file chosen in the Files app. Videos are copied into the temporary folder, photos are decoded.
    static func source(fromFile url: URL) async -> EditorSource? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .movie) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionImport", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
            return .video(destination)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let photo = await Task.detached(priority: .userInitiated) { decodePhoto(data, name: name) }.value
        return photo.map { .photo($0) }
    }

    /// Removes imported video copies left over from earlier sessions.
    static func clearImportFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionImport", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Camera capture. Only offered when the device has a camera (not on the simulator or some iPads).
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onPhoto: (PhotoSource?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (PhotoSource?) -> Void
        init(onPhoto: @escaping (PhotoSource?) -> Void) { self.onPhoto = onPhoto }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) else {
                onPhoto(nil)
                return
            }
            onPhoto(MediaLoader.decodePhoto(data, name: "Camera"))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPhoto(nil) }
    }
}

// MARK: - Sample photos

/// Sample photos that ship with the app (Sources/Resources/Samples), so Lumotion can be tried without choosing a photo.
/// The folder is optional: with no samples the Home screen simply leaves the strip out.
enum SampleLibrary {
    struct Sample: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL
    }

    private static let extensions = ["jpg", "jpeg", "heic", "png"]

    static func all() -> [Sample] {
        var urls: [URL] = []
        for ext in extensions {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Samples") ?? []
            // Xcode flattens resource groups, so a sample may also sit at the top of the bundle.
            let root = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            urls += root.filter { $0.lastPathComponent.lowercased().hasPrefix("sample") }
        }
        #if DEBUG
        urls += DebugSampleFolder.urls()
        #endif
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.deletingPathExtension().lastPathComponent).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Sample(id: $0.deletingPathExtension().lastPathComponent, title: title(for: $0), url: $0) }
    }

    static func photo(_ sample: Sample) -> PhotoSource? {
        guard let data = try? Data(contentsOf: sample.url) else { return nil }
        return MediaLoader.decodePhoto(data, name: sample.title)
    }

    /// "sample_golden-hour_02.jpg" becomes "Golden hour".
    static func title(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasPrefix("sample") { name = String(name.dropFirst("sample".count)) }
        let words = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { Int($0) == nil }
        guard let first = words.first else { return "Sample" }
        let text = ([String(first).capitalized] + words.dropFirst().map(String.init)).joined(separator: " ")
        return text
    }
}

#if DEBUG
/// CI can copy extra photos into the simulator app's Documents/samples folder.
enum DebugSampleFolder {
    static func urls() -> [URL] {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("samples", isDirectory: true),
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
    }
}
#endif
