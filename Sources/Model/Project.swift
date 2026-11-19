import Foundation
import CoreGraphics

// MARK: - Primitives

/// A point in normalised coordinates: x and y run 0...1 across the width and height of whatever space the value lives in
/// (the source photo for strokes and arrows, the canvas for text and stickers). Origin is the top left, y grows downwards.
/// Encoded as a compact `[x, y]` pair so long brush strokes stay small on disk.
struct NPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static let center = NPoint(0.5, 0.5)

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// A colour with straight (non-premultiplied) components, each 0...1.
struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// 0xRRGGBB.
    init(hex: UInt32, alpha: Double = 1) {
        self.r = Double((hex >> 16) & 0xFF) / 255
        self.g = Double((hex >> 8) & 0xFF) / 255
        self.b = Double(hex & 0xFF) / 255
        self.a = alpha
    }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
}

/// One brush stroke: a polyline stamped with a round, feathered brush. Used for flow regions, anchors, cinemagraph masks,
/// effect masks and manual depth. Points are in the space of the source photo.
struct BrushStroke: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var points: [NPoint]
    /// Brush radius as a fraction of the photo's LONG edge (0.04 is a medium brush).
    var radius: Double = 0.04
    /// 0 is a hard edge, 1 is fully soft.
    var feather: Double = 0.5
    /// An eraser stroke removes what earlier strokes painted.
    var erase: Bool = false
    /// Only used by manual depth strokes: 0 is far away, 1 is close to the camera.
    var value: Double = 1

    init(id: UUID = UUID(), points: [NPoint], radius: Double = 0.04, feather: Double = 0.5, erase: Bool = false, value: Double = 1) {
        self.id = id
        self.points = points
        self.radius = radius
        self.feather = feather
        self.erase = erase
        self.value = value
    }
}

// MARK: - Source, canvas, loop

/// Where the pixels come from. Files live inside the project folder (see `ProjectStore`).
struct SourceSpec: Codable, Hashable {
    enum Kind: String, Codable, Hashable { case still, video }
    var kind: Kind
    /// File name inside the project folder, for example "source.jpg" or "source.mov".
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    /// Seconds. 0 for photos.
    var videoDuration: Double = 0

    var aspect: Double { pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1 }
}

enum CanvasAspect: String, Codable, CaseIterable, Hashable, Identifiable {
    case original
    case square        // 1:1
    case portrait45    // 4:5
    case story916      // 9:16
    case wide169       // 16:9
    case portrait34    // 3:4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .story916: return "9:16"
        case .wide169: return "16:9"
        case .portrait34: return "3:4"
        }
    }

    /// Width divided by height. For `original` the source aspect is used.
    func ratio(sourceAspect: Double) -> Double {
        switch self {
        case .original: return max(0.1, sourceAspect)
        case .square: return 1
        case .portrait45: return 4.0 / 5.0
        case .story916: return 9.0 / 16.0
        case .wide169: return 16.0 / 9.0
        case .portrait34: return 3.0 / 4.0
        }
    }
}

/// How the photo sits inside a canvas whose shape differs from the photo.
enum CanvasFit: String, Codable, Hashable, CaseIterable {
    /// The photo fills the canvas and the edges are cropped. `reframe` moves and zooms the crop.
    case fill
    /// The whole photo is visible, the rest is `background`.
    case fit
}

enum CanvasBackground: String, Codable, Hashable, CaseIterable {
    case blur
    case color
}

struct CanvasSpec: Codable, Hashable {
    var aspect: CanvasAspect = .original
    var fit: CanvasFit = .fill
    /// Centre of the visible crop in photo coordinates (0.5, 0.5 is the middle). Only used with `fill`.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// 1 shows the largest crop, 3 magnifies three times. Only used with `fill`.
    var zoom: Double = 1
    var background: CanvasBackground = .blur
    var backgroundColor: RGBAColor = RGBAColor(hex: 0x0A0C13)
}

enum LoopMode: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Plays 0 to 1 and jumps back. Every effect is periodic, so the jump cannot be seen.
    case loop
    /// Plays forward, then backward.
    case pingPong
    var id: String { rawValue }
}

struct LoopSpec: Codable, Hashable {
    /// Length of one loop in seconds, 1...15.
    var duration: Double = 4
    /// 24, 30 or 60.
    var fps: Int = 30
    var mode: LoopMode = .loop
    var reverse: Bool = false
    /// Global speed multiplier for effects, 0.25...4.
    var speed: Double = 1

    static let durationRange: ClosedRange<Double> = 1...15
    static let allowedFPS: [Int] = [24, 30, 60]

    /// Number of frames in one loop. The frame at time `duration` equals frame 0 and is not written.
    var frameCount: Int { max(1, Int((clampedDuration * Double(fps)).rounded())) }

    var clampedDuration: Double { min(max(duration, 0.2), 60) }

    /// Loop phase 0...1 for a time in seconds. Time wraps, so any time may be passed.
    func phase(at time: Double) -> Double {
        let d = clampedDuration
        var u = time / d
        u -= u.rounded(.down)
        var p = u
        if mode == .pingPong { p = 1 - abs(2 * u - 1) }
        if reverse { p = 1 - p }
        return p
    }
}

// MARK: - Project

/// Everything that describes one animation. A plain value: copy it, change it, hand it back to the engine.
/// The engine turns a `Project` plus `SourceAssets` into frames, and the same value is saved to disk by `ProjectStore`.
struct Project: Codable, Hashable, Identifiable {
    /// The newest file layout this build understands. A file with a higher `schemaVersion` still opens, but the store
    /// keeps an untouched copy of it (`project.json.orig`) before saving over it.
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Project.currentSchemaVersion
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var source: SourceSpec
    var canvas: CanvasSpec = CanvasSpec()
    var loop: LoopSpec = LoopSpec()
    /// Painted regions that flow along arrows.
    var flowRegions: [FlowRegion] = []
    /// Areas pinned still while everything else moves.
    var anchors: [BrushStroke] = []
    var camera: CameraMotion = CameraMotion()
    var parallax: ParallaxSettings = ParallaxSettings()
    var livingEffects: [LivingEffect] = []
    var overlays: [OverlayLayer] = []
    var look: Look = Look()
    var texts: [TextLayer] = []
    var stickers: [StickerLayer] = []
    var audio: AudioTrackSpec? = nil
    var cinemagraph: CinemagraphSettings = CinemagraphSettings()
    /// The preset this project started from, if any (see `PresetLibrary`).
    var presetID: String? = nil

    init(id: UUID = UUID(), title: String, source: SourceSpec, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.source = source
    }

    /// A new project for a photo or a video of the given size.
    static func new(title: String, kind: SourceSpec.Kind, fileName: String, pixelWidth: Int, pixelHeight: Int, videoDuration: Double = 0) -> Project {
        var project = Project(title: title, source: SourceSpec(kind: kind, fileName: fileName, pixelWidth: pixelWidth, pixelHeight: pixelHeight, videoDuration: videoDuration))
        if kind == .video {
            let segment = min(max(videoDuration, 1), CinemagraphSettings.maxSegment)
            project.cinemagraph.segmentStart = 0
            project.cinemagraph.segmentEnd = segment
            project.cinemagraph.stillTime = 0
            project.loop.duration = max(1, project.cinemagraph.loopLength)
        }
        return project
    }

    // Lenient decoding (see ProjectDecoding.swift): a file with missing or unknown fields still opens.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, modifiedAt, source, canvas, loop, flowRegions, anchors, camera, parallax
        case livingEffects, overlays, look, texts, stickers, audio, cinemagraph, presetID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        schemaVersion = c.get("schemaVersion", 1)
        id = try c.need("id")
        title = c.get("title", "Untitled")
        createdAt = c.get("createdAt", Date())
        modifiedAt = c.get("modifiedAt", createdAt)
        source = try c.need("source")
        canvas = c.get("canvas", CanvasSpec())
        loop = c.get("loop", LoopSpec())
        flowRegions = c.list("flowRegions")
        anchors = c.list("anchors")
        camera = c.get("camera", CameraMotion())
        parallax = c.get("parallax", ParallaxSettings())
        livingEffects = c.list("livingEffects")
        overlays = c.list("overlays")
        look = c.get("look", Look())
        texts = c.list("texts")
        stickers = c.list("stickers")
        audio = c.opt("audio")
        cinemagraph = c.get("cinemagraph", CinemagraphSettings())
        presetID = c.opt("presetID")
    }
}
