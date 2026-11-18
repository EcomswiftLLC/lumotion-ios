import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// A photo the person chose, decoded upright and capped in size so a huge panorama cannot exhaust memory.
struct PhotoSource {
    let image: CGImage
    /// The file bytes the image was decoded from (JPEG, HEIC or PNG), used to read portrait depth. Nil for bundled samples.
    let data: Data?
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

/// A bundled sample photo, named as `SampleLibrary.availableNames()` reports it.
struct SampleRef: Identifiable, Hashable {
    let name: String
    var id: String { name }

    /// "sample_golden-hour_02" becomes "Golden hour".
    var title: String {
        var text = name
        if text.lowercased().hasPrefix("sample") { text = String(text.dropFirst("sample".count)) }
        let words = text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { Int($0) == nil }
            .map(String.init)
        guard let first = words.first else { return "Sample" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// Access to the bundled sample photos through the engine's `SampleLibrary`. The sample strip is left out when the app
/// ships no samples. Debug screenshot runs fall back to generated pictures (never in Release builds).
enum Samples {
    static func refs() -> [SampleRef] {
        let found = SampleLibrary.availableNames().map { SampleRef(name: $0) }
        #if DEBUG
        if found.isEmpty && DebugScreens.requested != nil { return DebugFixtures.sampleRefs }
        #endif
        return found
    }

    static func image(_ ref: SampleRef, maxPixel: Int) -> CGImage? {
        if let image = SampleLibrary.image(named: ref.name, maxPixel: maxPixel) { return image }
        #if DEBUG
        if DebugScreens.requested != nil {
            let seed = ref.name.utf8.reduce(0) { $0 &+ Int($1) }
            let side = CGFloat(maxPixel)
            return DebugFixtures.gradient(seed: seed, size: CGSize(width: side * 0.8, height: side)).cgImage
        }
        #endif
        return nil
    }

    static func photo(_ ref: SampleRef) -> PhotoSource? {
        image(ref, maxPixel: MediaLoader.maxPhotoPixel).map { PhotoSource(image: $0, data: nil, name: ref.title) }
    }
}
