import Foundation
import CoreGraphics

// STEP 1 SURFACE. These are the stable entry points the screens code against. Bodies are neutral placeholders that are
// replaced by the real engine in follow-up commits; signatures do not change.

// MARK: - RenderEngine

/// Turns a `Project` plus `SourceAssets` into frames. One code path serves the live preview, the exporter and the tests.
/// Thread safe: `update(project:)` may be called from the main thread while another thread renders; a render uses the
/// project that was current when it started. Rendering is CPU only and deterministic.
final class RenderEngine {
    private let lock = NSLock()
    private var currentProject: Project
    private var currentAssets: SourceAssets

    init(project: Project, assets: SourceAssets) {
        self.currentProject = project
        self.currentAssets = assets
    }

    /// The project the engine is currently rendering.
    var project: Project {
        lock.lock(); defer { lock.unlock() }
        return currentProject
    }

    /// The assets the engine is currently using.
    var assets: SourceAssets {
        lock.lock(); defer { lock.unlock() }
        return currentAssets
    }

    /// Swaps in an edited project. Cheap: cached work is reused for everything that did not change.
    func update(project: Project) {
        lock.lock(); currentProject = project; lock.unlock()
    }

    /// Swaps in new assets, for example when the subject mask finishes computing in the background.
    func update(assets: SourceAssets) {
        lock.lock(); currentAssets = assets; lock.unlock()
    }

    /// Canvas size in pixels for a long edge, from the project's aspect ratio. Both sides are even numbers.
    func canvasSize(longEdge: Int) -> (width: Int, height: Int) {
        RenderEngine.canvasSize(for: project, longEdge: longEdge)
    }

    /// Canvas size in pixels for a project and a long edge. Both sides are even numbers.
    static func canvasSize(for project: Project, longEdge: Int) -> (width: Int, height: Int) {
        let ratio = project.canvas.aspect.ratio(sourceAspect: project.source.aspect)
        let long = Double(max(16, longEdge))
        var w: Double, h: Double
        if ratio >= 1 { w = long; h = long / ratio } else { h = long; w = long * ratio }
        w = max(2, (w / 2).rounded() * 2)
        h = max(2, (h / 2).rounded() * 2)
        return (Int(w), Int(h))
    }

    /// Renders the frame at `time` seconds (any time; it wraps around the loop). Blocks, so call it off the main thread.
    /// Returns nil when cancelled through `token` or when no source picture is available.
    func renderFrame(time: Double, quality: RenderQuality = .preview, token: RenderToken? = nil) -> CGImage? {
        assets.still
    }

    /// Like `renderFrame`, but picks the resolution itself: it starts at `RenderQuality.preview` and steps down to
    /// `RenderQuality.draft` when frames take too long to keep up with 30 fps, and back up when there is headroom.
    func previewFrame(time: Double, token: RenderToken? = nil) -> CGImage? {
        renderFrame(time: time, quality: .preview, token: token)
    }

    /// The canvas-framed source with no effects, for the "compare with original" button.
    func originalFrame(quality: RenderQuality = .preview) -> CGImage? {
        assets.still
    }

    /// Async wrapper that renders on a background queue. Cancelling the calling task cancels the render.
    func renderFrameAsync(time: Double, quality: RenderQuality = .preview) async -> CGImage? {
        let token = RenderToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.renderFrame(time: time, quality: quality, token: token))
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Frees cached pictures and masks (call on memory warnings).
    func clearCaches() {}
}

// MARK: - ProjectStore

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

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Folder of one project.
    func folderURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Thumbnail location for a project (may not exist yet).
    func thumbnailURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("thumb.jpg")
    }

    /// All saved projects, newest first.
    func listProjects() -> [ProjectListing] { [] }

    /// Creates a project from a decoded photo. `originalData` (the file the photo came from) is only used to read the
    /// depth that portrait photos carry. The photo is stored as a JPEG copy inside the project folder.
    func createPhotoProject(image: CGImage, originalData: Data?, title: String?) throws -> (project: Project, assets: SourceAssets) {
        throw EngineError.unsupported("Projects cannot be saved yet.")
    }

    /// Creates a cinemagraph project from a video file. The video is copied into the project folder.
    func createVideoProject(videoURL: URL, title: String?) async throws -> (project: Project, assets: SourceAssets) {
        throw EngineError.unsupported("Projects cannot be saved yet.")
    }

    /// Writes `project.json` atomically (and updates `modifiedAt`).
    func save(_ project: Project) throws {}

    /// Reads a project. Falls back to the backup copy when the main file is damaged.
    func load(id: UUID) throws -> Project {
        throw EngineError.failed("This project could not be found.")
    }

    /// Decodes the source photo or video reference and cached masks for a project.
    func loadAssets(for project: Project) throws -> SourceAssets {
        throw EngineError.failed("This project could not be found.")
    }

    /// Saves the gallery thumbnail.
    func saveThumbnail(_ image: CGImage, for id: UUID) {}

    /// Stores masks computed by `MaskProvider` so they are not recomputed on the next open.
    func saveMasks(subject: MaskBuffer?, depth: MaskBuffer?, for id: UUID) {}

    /// Copies the person's audio file into the project folder and returns the spec to put in `project.audio`.
    func attachAudio(from url: URL, to id: UUID) throws -> AudioTrackSpec {
        throw EngineError.unsupported("Audio cannot be added yet.")
    }

    /// Copies a project, including its files, under a new id with "copy" appended to the title.
    func duplicate(id: UUID) throws -> Project {
        throw EngineError.failed("This project could not be found.")
    }

    func rename(id: UUID, title: String) throws {}

    /// Deletes the project folder.
    func delete(id: UUID) throws {}
}

// MARK: - MaskProvider

/// Finds the masks and depth maps the engine needs. Everything runs on the device.
enum MaskProvider {
    /// The main subject of a photo, found with Apple Vision (iOS 17). White is the subject. Returns nil when Vision finds
    /// no subject or is unavailable (for example on the CI simulator), so callers must handle nil.
    static func subjectMask(for image: CGImage) async -> MaskBuffer? { nil }

    /// Depth that a portrait photo carries (ImageIO auxiliary disparity or depth data), normalised so near is white.
    /// Nil when the file has no depth.
    static func embeddedDepth(fromImageData data: Data) -> MaskBuffer? { nil }

    /// Same, reading from a file.
    static func embeddedDepth(fromFileAt url: URL) -> MaskBuffer? { nil }

    /// A simple depth map: bottom of the frame near (white), top far (black).
    static func gradientDepth(width: Int, height: Int) -> MaskBuffer {
        MaskBuffer(width: width, height: height, value: 128)
    }

    /// Depth from painted strokes (each stroke's `value`) over a neutral grey. Strokes are in photo coordinates.
    static func manualDepth(strokes: [BrushStroke], width: Int, height: Int) -> MaskBuffer {
        MaskBuffer(width: width, height: height, value: 128)
    }
}

// MARK: - Exporter

/// Writes finished files. Each call renders every frame at full size, one at a time, so memory stays flat. Calls are
/// async, report progress, and stop quickly on `cancel()` or when the calling task is cancelled. Files are created in a
/// temporary folder; move or share them from there. If the project has an audio track it is mixed into MP4 files.
final class Exporter {
    private let project: Project
    private let assets: SourceAssets
    private let token = RenderToken()

    init(project: Project, assets: SourceAssets) {
        self.project = project
        self.assets = assets
    }

    /// Stops a running export.
    func cancel() { token.cancel() }

    /// Seamless-loop MP4 (H.264 or HEVC). Frame count is `loop.frameCount`; the final frame equals the first so it loops.
    func exportMP4(codec: VideoCodec, size: ExportResolution, progress: ExportProgress? = nil) async throws -> URL {
        throw EngineError.unsupported("Video export is not available yet.")
    }

    /// Looping GIF (loop count 0 means forever).
    func exportGIF(options: GIFOptions, progress: ExportProgress? = nil) async throws -> URL {
        throw EngineError.unsupported("GIF export is not available yet.")
    }

    /// Convenience for width and frame rate only.
    func exportGIF(width: Int, fps: Int, progress: ExportProgress? = nil) async throws -> URL {
        try await exportGIF(options: GIFOptions(width: width, fps: fps), progress: progress)
    }

    /// One frame as an image file. `longEdge` nil uses the largest size the source allows.
    func exportStill(format: StillFormat, time: Double = 0, longEdge: Int? = nil) async throws -> URL {
        throw EngineError.unsupported("Still export is not available yet.")
    }

    /// Size estimate for an MP4 before it is rendered.
    func estimateMP4(codec: VideoCodec, size: ExportResolution) -> ExportEstimate {
        ExportEstimate(bytes: 0, frameCount: project.loop.frameCount, width: 0, height: 0, note: nil)
    }

    /// Size estimate for a GIF before it is rendered.
    func estimateGIF(options: GIFOptions) -> ExportEstimate {
        ExportEstimate(bytes: 0, frameCount: 0, width: 0, height: 0, note: nil)
    }

    /// Resolutions the device can encode with the codec (4K HEVC needs hardware support).
    static func supportedResolutions(codec: VideoCodec) -> [ExportResolution] {
        [.p720, .p1080]
    }
}

// MARK: - PresetLibrary

/// One-tap Magic Presets. Presets are starting points: they set effects, overlays, camera, look and loop length and add
/// a default flow region that the person can edit.
enum PresetLibrary {
    /// All presets in display order (12 or more).
    static let all: [PresetInfo] = []

    static func info(for id: String) -> PresetInfo? { all.first { $0.id == id } }

    /// Returns `base` with the preset applied: source, canvas, audio and title are kept, effect settings are replaced.
    static func apply(_ id: String, to base: Project) -> Project { base }
}

// MARK: - SampleLibrary

/// Loads the built-in sample photos that the brand pass bundles under `Sources/Resources/Samples`. Returns nil when a
/// sample is not in the bundle, so the app can hide the sample row instead of showing a blank tile.
enum SampleLibrary {
    /// File names (without extension) found in the bundle's Samples folder, sorted.
    static func availableNames(bundle: Bundle = .main) -> [String] { [] }

    /// Decodes a bundled sample upright, at most `maxPixel` on the long side.
    static func image(named name: String, maxPixel: Int = 3000, bundle: Bundle = .main) -> CGImage? { nil }
}
