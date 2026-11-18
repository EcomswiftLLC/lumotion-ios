import Foundation
import CoreGraphics

// MARK: - Look

/// Colour looks. Original names, built from Core Image recipes in `LookProcessor`.
enum LookID: String, Codable, Hashable, CaseIterable, Identifiable {
    case original
    case lumen, ivory, gilt, rosette, verdant, cinema, nocturne, parchment, matte, riviera, slate, amber, polar, vivid, dusk
    case instant, chrome, noir, mono, tonal, faded, transfer, silver, ink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .lumen: return "Lumen"
        case .ivory: return "Ivory"
        case .gilt: return "Gilt"
        case .rosette: return "Rosette"
        case .verdant: return "Verdant"
        case .cinema: return "Cinema"
        case .nocturne: return "Nocturne"
        case .parchment: return "Parchment"
        case .matte: return "Matte"
        case .riviera: return "Riviera"
        case .slate: return "Slate"
        case .amber: return "Amber"
        case .polar: return "Polar"
        case .vivid: return "Vivid"
        case .dusk: return "Dusk"
        case .instant: return "Instant"
        case .chrome: return "Chrome"
        case .noir: return "Noir"
        case .mono: return "Mono"
        case .tonal: return "Tonal"
        case .faded: return "Faded"
        case .transfer: return "Transfer"
        case .silver: return "Silver"
        case .ink: return "Ink"
        }
    }
}

/// Adjustment dials. Dials marked -1...1 are neutral at 0, dials marked 0...1 are off at 0.
struct LookAdjust: Codable, Hashable {
    var exposure: Double = 0      // -1...1 (about +/- 2 stops)
    var contrast: Double = 0      // -1...1
    var saturation: Double = 0    // -1...1
    var warmth: Double = 0        // -1...1
    var tint: Double = 0          // -1...1
    var highlights: Double = 0    // -1...1
    var shadows: Double = 0       // -1...1
    var sharpen: Double = 0       // 0...1
    var vignette: Double = 0      // 0...1
    var grain: Double = 0         // 0...1 film grain amount
    var glow: Double = 0          // 0...1 bloom

    /// True when the dials that Core Image applies (everything except grain) are all neutral.
    var isNeutralForColor: Bool {
        exposure == 0 && contrast == 0 && saturation == 0 && warmth == 0 && tint == 0
            && highlights == 0 && shadows == 0 && sharpen == 0 && vignette == 0 && glow == 0
    }
}

/// Animated light pulse over the whole frame.
struct Flicker: Codable, Hashable {
    /// 0...1, 0 is off.
    var amount: Double = 0
    /// 0.1...3.
    var speed: Double = 1
}

struct Look: Codable, Hashable {
    var filter: LookID = .original
    /// 0...100.
    var intensity: Double = 100
    var adjust: LookAdjust = LookAdjust()
    /// Grain changes from frame to frame (still loops, because it cycles a fixed set of patterns).
    var animatedGrain: Bool = true
    var flicker: Flicker = Flicker()

    var isNeutralForColor: Bool { (filter == .original || intensity <= 0) && adjust.isNeutralForColor }
}

// MARK: - Text and stickers

enum LayerAnimationKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case none, fade, slideUp, slideDown, slideLeft, slideRight, pop, typewriter, float
    var id: String { rawValue }
}

struct LayerAnimation: Codable, Hashable {
    var kind: LayerAnimationKind = .fade
    /// Seconds, 0.1...3.
    var duration: Double = 0.6
}

/// A gentle movement that continues while the layer is visible.
enum LayerIdle: String, Codable, Hashable, CaseIterable, Identifiable {
    case none, float, pulse, sway
    var id: String { rawValue }
}

enum TextDesign: String, Codable, Hashable, CaseIterable, Identifiable {
    case standard, serif, rounded, monospaced
    var id: String { rawValue }
}

enum TextWeight: String, Codable, Hashable, CaseIterable, Identifiable {
    case light, regular, semibold, bold, heavy
    var id: String { rawValue }
}

struct TextLayer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var design: TextDesign = .serif
    var weight: TextWeight = .semibold
    /// Font size as a share of the canvas height.
    var size: Double = 0.07
    var color: RGBAColor = .white
    var shadow: Bool = true
    var outline: RGBAColor? = nil
    /// Centre in canvas coordinates.
    var center: NPoint = .center
    /// Degrees.
    var rotation: Double = 0
    var scale: Double = 1
    var entrance: LayerAnimation = LayerAnimation(kind: .fade, duration: 0.6)
    var exit: LayerAnimation = LayerAnimation(kind: .none, duration: 0.6)
    var idle: LayerIdle = .none
    /// Visible from `startTime` (seconds) until `endTime`; nil means until the end of the loop.
    var startTime: Double = 0
    var endTime: Double? = nil
    var enabled: Bool = true

    init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

struct StickerLayer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// An emoji (or any short string) drawn with the system emoji font.
    var emoji: String
    /// Height as a share of the canvas height.
    var size: Double = 0.14
    var center: NPoint = .center
    var rotation: Double = 0
    var scale: Double = 1
    var entrance: LayerAnimation = LayerAnimation(kind: .pop, duration: 0.5)
    var exit: LayerAnimation = LayerAnimation(kind: .none, duration: 0.5)
    var idle: LayerIdle = .none
    var startTime: Double = 0
    var endTime: Double? = nil
    var enabled: Bool = true

    init(id: UUID = UUID(), emoji: String) { self.id = id; self.emoji = emoji }
}

// MARK: - Audio

/// The person's own audio file, mixed into exported video. The file is copied into the project folder.
struct AudioTrackSpec: Codable, Hashable {
    /// File name inside the project folder.
    var fileName: String
    /// Shown in the UI.
    var displayName: String
    /// Seconds into the file where playback starts.
    var trimStart: Double = 0
    /// Seconds into the file where playback ends; nil plays to the end.
    var trimEnd: Double? = nil
    /// 0...1.
    var volume: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0.5
    /// Repeat the trimmed audio when it is shorter than the video.
    var loops: Bool = true
    var muted: Bool = false
}

// MARK: - Cinemagraph

/// Settings for a project whose source is a video. The part you paint keeps moving, the rest is frozen on `stillTime`.
struct CinemagraphSettings: Codable, Hashable {
    /// Longest loop segment in seconds.
    static let maxSegment: Double = 6

    /// Seconds into the video.
    var segmentStart: Double = 0
    var segmentEnd: Double = 4
    /// Which video frame is the frozen picture (seconds into the video).
    var stillTime: Double = 0
    /// 0...1: share of the segment used to cross-fade its end into its beginning. 0 is a hard cut.
    var loopSmoothing: Double = 0.4
    /// Paint the part that keeps moving (photo coordinates).
    var maskStrokes: [BrushStroke] = []
    /// Play the segment forward then backward instead of cross-fading.
    var pingPong: Bool = false
    /// Align frames with a global translation before use.
    var stabilize: Bool = false

    var segmentLength: Double { max(0.2, min(segmentEnd - segmentStart, CinemagraphSettings.maxSegment)) }

    /// Length of the cross-fade window in seconds.
    var crossfade: Double { pingPong ? 0 : min(max(loopSmoothing, 0), 1) * segmentLength * 0.5 }

    /// Length of the finished loop in seconds (one pass of the segment minus the cross-fade overlap, or the segment itself for ping-pong).
    var loopLength: Double { pingPong ? segmentLength : segmentLength - crossfade }
}
