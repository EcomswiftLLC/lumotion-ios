import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

/// One row of the project gallery.
struct ProjectListing: Identifiable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    /// Loop length in seconds.
    var duration: Double
    var kind: SourceSpec.Kind
    /// JPEG thumbnail on disk, nil when none was saved yet.
    var thumbnailURL: URL?
}

/// Saves projects in Application Support: one folder per project with `project.json`, the source photo or video, a
/// thumbnail and cached masks. All writes are atomic, and the previous `project.json` is kept as a backup so a crash in
/// the middle of a save cannot lose the project. Safe to call from any thread.
final class ProjectStore {
    /// The store in the app's Application Support folder.
    static let shared = ProjectStore(rootURL: ProjectStore.defaultRoot)

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumotion", isDirectory: true).appendingPathComponent("Projects", isDirectory: true)
    }

    let rootURL: URL
    private let lock = NSLock()
    /// Projects deleted during this run: `save` refuses them, so a late autosave cannot bring a deleted project back.
    private var deleted = Set<UUID>()
    private var cleanedOrphans = false

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var fm: FileManager { FileManager.default }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Locations

    /// Folder of one project.
    func folderURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func jsonURL(_ id: UUID) -> URL { folderURL(for: id).appendingPathComponent("project.json") }
    private func backupURL(_ id: UUID) -> URL { folderURL(for: id).appendingPathComponent("project.json.bak") }
    private func metaURL(_ id: UUID) -> URL { folderURL(for: id).appendingPathComponent("meta.json") }

    /// Thumbnail location for a project (may not exist yet).
    func thumbnailURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("thumb.jpg")
    }

    /// Full path of a file that belongs to a project, for example `project.source.fileName`.
    func fileURL(_ name: String, in id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent(name)
    }

    // MARK: Listing

    /// What the gallery needs about a project, kept in a tiny `meta.json` next to `project.json` so listing a hundred
    /// projects reads a hundred small files instead of a hundred full projects (strokes can make those large).
    private struct Meta: Codable {
        var id: UUID
        var title: String
        var createdAt: Date
        var modifiedAt: Date
        var duration: Double
        var kind: SourceSpec.Kind
    }

    private static func meta(for p: Project) -> Meta {
        Meta(id: p.id, title: p.title, createdAt: p.createdAt, modifiedAt: p.modifiedAt, duration: p.loop.duration, kind: p.source.kind)
    }

    /// All saved projects, newest first. Reads only each project's small meta file; a project saved by an older build
    /// (no meta file yet) is read in full once and gets its meta file. The first call also removes empty project folders
    /// left behind by a crash (see `cleanUpOrphans`).
    func listProjects() -> [ProjectListing] {
        lock.lock(); defer { lock.unlock() }
        if !cleanedOrphans {
            cleanedOrphans = true
            _ = removeOrphansLocked(olderThan: 600)
        }
        guard let folders = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        let decoder = ProjectStore.makeDecoder()
        var rows = [ProjectListing]()
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            var found: Meta?
            if let data = try? Data(contentsOf: metaURL(id)), let m = try? decoder.decode(Meta.self, from: data), m.id == id { found = m }
            if found == nil {
                for url in [jsonURL(id), backupURL(id)] {
                    if let data = try? Data(contentsOf: url), let project = try? decoder.decode(Project.self, from: data) {
                        let m = ProjectStore.meta(for: project)
                        found = m
                        if let encoded = try? ProjectStore.makeEncoder().encode(m) { try? encoded.write(to: metaURL(id), options: .atomic) }
                        break
                    }
                }
            }
            guard let h = found else { continue }
            let thumb = thumbnailURL(for: id)
            rows.append(ProjectListing(
                id: id, title: h.title, createdAt: h.createdAt, modifiedAt: h.modifiedAt,
                duration: h.duration, kind: h.kind, thumbnailURL: fm.fileExists(atPath: thumb.path) ? thumb : nil))
        }
        return rows.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Removes project folders that hold no `project.json` (and no backup): what is left when the app is closed or
    /// crashes between creating a folder and saving the first version. Folders younger than `age` seconds are left
    /// alone, because a project may be being created right now. Call at launch; `listProjects` also does it once.
    /// Returns how many folders were removed.
    @discardableResult
    func cleanUpOrphans(olderThan age: TimeInterval = 600) -> Int {
        lock.lock(); defer { lock.unlock() }
        return removeOrphansLocked(olderThan: age)
    }

    private func removeOrphansLocked(olderThan age: TimeInterval) -> Int {
        guard let folders = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if fm.fileExists(atPath: jsonURL(id).path) || fm.fileExists(atPath: backupURL(id).path) { continue }
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) < age { continue }
            if (try? fm.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Creating

    /// Creates a project from a decoded photo. `originalData` (the file the photo came from) is only used to read the
    /// depth that portrait photos carry. The photo is stored as a JPEG copy inside the project folder.
    func createPhotoProject(image: CGImage, originalData: Data?, title: String?) throws -> (project: Project, assets: SourceAssets) {
        let id = UUID()
        try fm.createDirectory(at: folderURL(for: id), withIntermediateDirectories: true)
        do {
            guard let jpeg = ProjectStore.encode(image, type: "public.jpeg", quality: 0.95) else {
                throw EngineError.failed("This photo could not be saved.")
            }
            try jpeg.write(to: fileURL("source.jpg", in: id), options: .atomic)
            var assets = SourceAssets(still: image)
            if let data = originalData, let depth = MaskProvider.embeddedDepth(fromImageData: data) {
                assets.embeddedDepth = depth
                saveMasks(subject: nil, depth: depth, for: id)
            }
            let project = Project(id: id, title: title ?? "Untitled loop",
                                  source: SourceSpec(kind: .still, fileName: "source.jpg", pixelWidth: image.width, pixelHeight: image.height))
            try save(project)
            saveThumbnail(image, for: id)
            return (project, assets)
        } catch {
            try? fm.removeItem(at: folderURL(for: id))
            throw error
        }
    }

    /// Creates a cinemagraph project from a video file. The video is copied into the project folder.
    func createVideoProject(videoURL: URL, title: String?) async throws -> (project: Project, assets: SourceAssets) {
        try await Task.detached(priority: .userInitiated) { [self] () throws -> (project: Project, assets: SourceAssets) in
            let scoped = videoURL.startAccessingSecurityScopedResource()
            defer { if scoped { videoURL.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            try fm.createDirectory(at: folderURL(for: id), withIntermediateDirectories: true)
            do {
                let ext = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension.lowercased()
                let name = "source.\(ext)"
                let destination = fileURL(name, in: id)
                try fm.copyItem(at: videoURL, to: destination)
                guard let info = VideoFrameStore.videoInfo(destination) else {
                    throw EngineError.failed("This video could not be read. Try a different clip.")
                }
                let project = Project.new(title: title ?? "Untitled cinemagraph", kind: .video, fileName: name,
                                          pixelWidth: Int(info.size.width.rounded()), pixelHeight: Int(info.size.height.rounded()),
                                          videoDuration: info.duration.isFinite ? info.duration : 0)
                var copy = project
                copy.id = id
                try save(copy)
                if let first = VideoFrameStore.still(url: destination, at: 0, maxPixel: 720) { saveThumbnail(first, for: id) }
                return (copy, SourceAssets(videoURL: destination))
            } catch {
                try? fm.removeItem(at: folderURL(for: id))
                throw error
            }
        }.value
    }

    // MARK: Save and load

    /// Writes `project.json` atomically (and updates `modifiedAt`). The previous file is kept as `project.json.bak`.
    func save(_ project: Project) throws {
        lock.lock(); defer { lock.unlock() }
        if deleted.contains(project.id) {
            throw EngineError.failed("This project was deleted, so it was not saved again.")
        }
        var p = project
        p.modifiedAt = Date()
        let folder = folderURL(for: p.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try ProjectStore.makeEncoder().encode(p)
        let main = jsonURL(p.id)
        if fm.fileExists(atPath: main.path) {
            let backup = backupURL(p.id)
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: main, to: backup)
        }
        try data.write(to: main, options: .atomic)
        if let meta = try? ProjectStore.makeEncoder().encode(ProjectStore.meta(for: p)) {
            try? meta.write(to: metaURL(p.id), options: .atomic)
        }
    }

    /// Reads a project. Falls back to the backup copy when the main file is damaged.
    func load(id: UUID) throws -> Project {
        lock.lock(); defer { lock.unlock() }
        let decoder = ProjectStore.makeDecoder()
        for url in [jsonURL(id), backupURL(id)] {
            if let data = try? Data(contentsOf: url), let project = try? decoder.decode(Project.self, from: data) { return project }
        }
        throw EngineError.failed("This project could not be opened. It may have been deleted.")
    }

    /// Decodes the source photo or video reference and cached masks for a project.
    func loadAssets(for project: Project) throws -> SourceAssets {
        let id = project.id
        let sourceURL = fileURL(project.source.fileName, in: id)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw EngineError.failed("The \(project.source.kind == .video ? "video" : "photo") for this project is missing.")
        }
        var assets = SourceAssets()
        if project.source.kind == .still {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw EngineError.failed("The photo for this project could not be read.")
            }
            assets.still = image
        } else {
            assets.videoURL = sourceURL
        }
        assets.subjectMask = ProjectStore.readMask(fileURL("subject.png", in: id))
        assets.embeddedDepth = ProjectStore.readMask(fileURL("depth.png", in: id))
        if let audio = project.audio {
            let url = fileURL(audio.fileName, in: id)
            if fm.fileExists(atPath: url.path) { assets.audioURL = url }
        }
        return assets
    }

    private static func readMask(_ url: URL) -> MaskBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return MaskBuffer.from(image)
    }

    // MARK: Files

    /// Saves the gallery thumbnail (at most 480 pixels on the long edge).
    func saveThumbnail(_ image: CGImage, for id: UUID) {
        let longest = max(image.width, image.height)
        var small = image
        if longest > 480 {
            let k = 480.0 / Double(longest)
            if let scaled = PixelBuffer.scaled(image, width: max(1, Int(Double(image.width) * k)), height: max(1, Int(Double(image.height) * k)))?.makeCGImage() {
                small = scaled
            }
        }
        guard let data = ProjectStore.encode(small, type: "public.jpeg", quality: 0.85) else { return }
        try? data.write(to: thumbnailURL(for: id), options: .atomic)
    }

    /// Stores masks computed by `MaskProvider` so they are not recomputed on the next open.
    func saveMasks(subject: MaskBuffer?, depth: MaskBuffer?, for id: UUID) {
        if let subject, let image = subject.cgImage, let data = ProjectStore.encode(image, type: "public.png", quality: 1) {
            try? data.write(to: fileURL("subject.png", in: id), options: .atomic)
        }
        if let depth, let image = depth.cgImage, let data = ProjectStore.encode(image, type: "public.png", quality: 1) {
            try? data.write(to: fileURL("depth.png", in: id), options: .atomic)
        }
    }

    /// Copies the person's audio file into the project folder and returns the spec to put in `project.audio`.
    func attachAudio(from url: URL, to id: UUID) throws -> AudioTrackSpec {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        lock.lock()
        let gone = deleted.contains(id)
        lock.unlock()
        guard !gone, fm.fileExists(atPath: folderURL(for: id).path) else {
            throw EngineError.failed("This project no longer exists.")
        }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let name = "audio.\(ext)"
        let destination = fileURL(name, in: id)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: url, to: destination)
        let asset = AVURLAsset(url: destination)
        guard asset.tracks(withMediaType: .audio).first != nil else {
            try? fm.removeItem(at: destination)
            throw EngineError.failed("This file has no audio that Lumotion can use. Choose an audio file such as MP3, M4A or WAV.")
        }
        return AudioTrackSpec(fileName: name, displayName: url.deletingPathExtension().lastPathComponent)
    }

    /// Length of an audio file in seconds, or 0 when unreadable.
    static func audioDuration(_ url: URL) -> Double {
        let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return d.isFinite ? d : 0
    }

    // MARK: Editing the library

    /// Copies a project, including its files, under a new id with "copy" appended to the title.
    func duplicate(id: UUID) throws -> Project {
        var project = try load(id: id)
        let newID = UUID()
        try fm.copyItem(at: folderURL(for: id), to: folderURL(for: newID))
        try? fm.removeItem(at: backupURL(newID))
        project.id = newID
        project.title = project.title + " copy"
        project.createdAt = Date()
        do {
            try save(project)
        } catch {
            try? fm.removeItem(at: folderURL(for: newID))
            throw error
        }
        return try load(id: newID)
    }

    func rename(id: UUID, title: String) throws {
        var project = try load(id: id)
        project.title = title
        try save(project)
    }

    /// Deletes the project folder.
    func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        deleted.insert(id)
        let folder = folderURL(for: id)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
    }

    // MARK: Image encoding

    /// Encodes a picture with ImageIO. `type` is a uniform type identifier such as "public.jpeg" or "public.png".
    static func encode(_ image: CGImage, type: String, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
