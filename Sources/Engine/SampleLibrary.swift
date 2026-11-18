import Foundation
import CoreGraphics
import ImageIO

/// Loads the built-in sample photos and clips that the brand pass bundles under `Sources/Resources/Samples`.
/// Works whether the build keeps the `Samples` folder or flattens it into the bundle root. Returns nothing when a sample
/// is not in the bundle, so the app can hide the sample row instead of showing a blank tile.
enum SampleLibrary {
    private static let photoExtensions = ["jpg", "jpeg", "png", "heic"]
    private static let videoExtensions = ["mp4", "mov", "m4v"]

    private static func urls(_ extensions: [String], bundle: Bundle) -> [URL] {
        var found = [URL]()
        for ext in extensions {
            found += bundle.urls(forResourcesWithExtension: ext, subdirectory: "Samples") ?? []
            found += bundle.urls(forResourcesWithExtension: ext, subdirectory: "Samples/Videos") ?? []
            found += bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        return found
    }

    /// The order the brand file asks for (samples.json), if present.
    private static func preferredOrder(bundle: Bundle) -> [String] {
        let candidates = [bundle.url(forResource: "samples", withExtension: "json", subdirectory: "Samples"),
                          bundle.url(forResource: "samples", withExtension: "json")]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let photos = object["photos"] as? [[String: Any]] else { continue }
            return photos.compactMap { ($0["file"] as? String).map { ($0 as NSString).deletingPathExtension } }
        }
        return []
    }

    /// File names (without extension) of the bundled sample photos: the order of samples.json first, then any others, sorted.
    static func availableNames(bundle: Bundle = .main) -> [String] {
        let all = Set(urls(photoExtensions, bundle: bundle).map { $0.deletingPathExtension().lastPathComponent })
        let preferred = preferredOrder(bundle: bundle).filter { all.contains($0) }
        let rest = all.subtracting(preferred).sorted()
        return preferred + rest
    }

    /// Decodes a bundled sample upright, at most `maxPixel` on the long side.
    static func image(named name: String, maxPixel: Int = 3000, bundle: Bundle = .main) -> CGImage? {
        guard let url = urls(photoExtensions, bundle: bundle).first(where: { $0.deletingPathExtension().lastPathComponent == name }),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// File names (without extension) of the bundled sample clips for cinemagraphs.
    static func availableVideoNames(bundle: Bundle = .main) -> [String] {
        Set(urls(videoExtensions, bundle: bundle).map { $0.deletingPathExtension().lastPathComponent }).sorted()
    }

    /// The file URL of a bundled sample clip.
    static func videoURL(named name: String, bundle: Bundle = .main) -> URL? {
        urls(videoExtensions, bundle: bundle).first { $0.deletingPathExtension().lastPathComponent == name }
    }
}
