import Foundation
import CoreGraphics

// MARK: - Flow regions (the headline effect)

/// A direction hint: the painted region flows from `from` towards `to`.
struct FlowArrow: Codable, Hashable {
    var from: NPoint
    var to: NPoint

    init(from: NPoint, to: NPoint) { self.from = from; self.to = to }

    var length: Double { hypot(to.x - from.x, to.y - from.y) }
}

/// One independent flow region: paint it with strokes, steer it with arrows. With no arrows the region does not move.
struct FlowRegion: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Flow"
    var enabled: Bool = true
    var strokes: [BrushStroke] = []
    var arrows: [FlowArrow] = []
    /// 0.1...3. How fast the content travels (it never changes how seamless the loop is).
    var speed: Double = 1
    /// 0...1. How far the content travels in one cycle, as a share of the long edge (1 is about 8 percent).
    var strength: Double = 0.5
    /// 0...1. Widens the soft edge of the painted region on top of each stroke's own feather.
    var softness: Double = 0.5

    init(id: UUID = UUID(), name: String = "Flow", enabled: Bool = true, strokes: [BrushStroke] = [], arrows: [FlowArrow] = [],
         speed: Double = 1, strength: Double = 0.5, softness: Double = 0.5) {
        self.id = id; self.name = name; self.enabled = enabled; self.strokes = strokes; self.arrows = arrows
        self.speed = speed; self.strength = strength; self.softness = softness
    }

    var hasDirection: Bool { !arrows.isEmpty }
    var isPainted: Bool { strokes.contains { !$0.erase } }
}

// MARK: - Camera

enum CameraKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case none, zoomIn, zoomOut, pan, drift, rotate, shake, breathe, custom
    var id: String { rawValue }
}

enum PanDirection: String, Codable, Hashable, CaseIterable, Identifiable {
    case left, right, up, down, upLeft, upRight, downLeft, downRight
    var id: String { rawValue }

    /// Unit-ish vector of the camera travel in screen space (y grows downwards).
    var vector: (x: Double, y: Double) {
        switch self {
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .upLeft: return (-0.7071, -0.7071)
        case .upRight: return (0.7071, -0.7071)
        case .downLeft: return (-0.7071, 0.7071)
        case .downRight: return (0.7071, 0.7071)
        }
    }
}

enum Easing: String, Codable, Hashable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut
    var id: String { rawValue }

    func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x * x * (3 - 2 * x)
        }
    }
}

/// A camera pose for custom start and end framing.
struct CameraFraming: Codable, Hashable {
    /// 1 is the full frame, 2 is twice as close.
    var zoom: Double = 1
    /// Offset of the view centre as a share of the frame width and height (-0.5...0.5).
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Degrees.
    var rotation: Double = 0
}

struct CameraMotion: Codable, Hashable {
    var kind: CameraKind = .none
    var direction: PanDirection = .right
    /// 0...1.
    var amount: Double = 0.5
    var easing: Easing = .easeInOut
    /// When true, zoom and pan travel out and back, so the loop closes without a jump. When false they travel one way,
    /// which is what a push-in usually looks like (best with ping-pong, or accept the cut when the loop restarts).
    var loops: Bool = true
    /// Used by `.custom`: the camera goes from `start` to `end` over the loop.
    var start: CameraFraming = CameraFraming()
    var end: CameraFraming = CameraFraming(zoom: 1.2)
}

// MARK: - Parallax / depth

enum DepthSource: String, Codable, Hashable, CaseIterable, Identifiable {
    /// The foreground subject found by Vision is near, the rest is far.
    case subjectMask
    /// The portrait depth stored in the photo itself.
    case embeddedDepth
    /// Painted by hand with `ParallaxSettings.depthStrokes`.
    case manualBrush
    /// Bottom of the frame near, top far.
    case gradient
    var id: String { rawValue }
}

enum ParallaxStyle: String, Codable, Hashable, CaseIterable, Identifiable {
    case dolly, orbit, swing, push
    var id: String { rawValue }
}

enum EdgeFill: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Repeat the last pixel row.
    case stretch
    /// Mirror the picture at the edge.
    case mirror
    /// Fill with a blurred copy.
    case blur
    var id: String { rawValue }
}

struct ParallaxSettings: Codable, Hashable {
    var enabled: Bool = false
    var depthSource: DepthSource = .gradient
    var style: ParallaxStyle = .orbit
    /// 0...1.
    var strength: Double = 0.5
    var edgeFill: EdgeFill = .blur
    /// Swap near and far.
    var invertDepth: Bool = false
    /// Strokes for `.manualBrush`. Each stroke's `value` is its depth (1 near, 0 far).
    var depthStrokes: [BrushStroke] = []
}

// MARK: - Living effects

enum LivingEffectKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case ripple, waves, windSway, heatHaze, shimmer, pulse, lightSweep, glitch, wobble, wiggle, swirl
    var id: String { rawValue }
}

/// A linear fade used to limit an effect: 0 at `start`, 1 at `end`.
struct GradientMask: Codable, Hashable {
    var start: NPoint = NPoint(0.5, 0)
    var end: NPoint = NPoint(0.5, 1)
    /// 0 is a straight ramp, 1 is a very smooth ramp.
    var softness: Double = 0.5
    var invert: Bool = false
}

struct LivingEffect: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: LivingEffectKind
    var enabled: Bool = true
    /// 0...1.
    var strength: Double = 0.5
    /// 0.1...3.
    var speed: Double = 1
    /// Pattern size multiplier, 0.25...4.
    var scale: Double = 1
    /// Degrees, direction of waves, wind and sweeps (0 is to the right, 90 is down).
    var angle: Double = 0
    /// Centre of ripple, swirl, pulse and wobble.
    var center: NPoint = .center
    /// Limits the effect to part of the frame.
    var gradient: GradientMask? = nil
    /// Limits the effect to painted areas (photo coordinates). Combined with `gradient` by multiplying.
    var brush: [BrushStroke] = []

    init(id: UUID = UUID(), kind: LivingEffectKind, enabled: Bool = true, strength: Double = 0.5, speed: Double = 1, scale: Double = 1,
         angle: Double = 0, center: NPoint = .center, gradient: GradientMask? = nil, brush: [BrushStroke] = []) {
        self.id = id; self.kind = kind; self.enabled = enabled; self.strength = strength; self.speed = speed; self.scale = scale
        self.angle = angle; self.center = center; self.gradient = gradient; self.brush = brush
    }
}

// MARK: - Overlays

enum OverlayKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case rain, heavyRain, snow, blizzard, leaves, petals, fireflies, sparkles, bokeh, dust, embers, fog
    case lensFlare, lightLeaks, stars, confetti, hearts, bubbles, shootingStars, fireworks
    var id: String { rawValue }
}

enum OverlayPlacement: String, Codable, Hashable, CaseIterable, Identifiable {
    case over
    /// Behind the foreground subject (needs a subject mask, otherwise it behaves like `over`).
    case under
    var id: String { rawValue }
}

struct OverlayLayer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: OverlayKind
    var enabled: Bool = true
    /// 0...1: how many particles / how strong.
    var intensity: Double = 0.5
    /// 0.1...3.
    var speed: Double = 1
    /// 0.25...3, particle size multiplier.
    var size: Double = 1
    /// nil uses the natural colour of the overlay.
    var tint: RGBAColor? = nil
    /// Degrees of travel (0 is to the right, 90 is down).
    var direction: Double = 90
    /// 0...1: far particles get softer and smaller (bokeh depth).
    var depthBlur: Double = 0.4
    var placement: OverlayPlacement = .over
    var seed: Int = 1

    init(id: UUID = UUID(), kind: OverlayKind, enabled: Bool = true, intensity: Double = 0.5, speed: Double = 1, size: Double = 1,
         tint: RGBAColor? = nil, direction: Double? = nil, depthBlur: Double = 0.4, placement: OverlayPlacement = .over, seed: Int = 1) {
        self.id = id; self.kind = kind; self.enabled = enabled; self.intensity = intensity; self.speed = speed; self.size = size
        self.tint = tint; self.direction = direction ?? OverlayLayer.naturalDirection(kind); self.depthBlur = depthBlur
        self.placement = placement; self.seed = seed
    }

    /// The direction a kind of overlay travels when nobody changed it.
    static func naturalDirection(_ kind: OverlayKind) -> Double {
        switch kind {
        case .rain, .heavyRain: return 100
        case .snow, .blizzard: return 80
        case .leaves, .petals: return 60
        case .fireflies, .sparkles, .dust, .bokeh, .stars, .lightLeaks, .fireworks: return 270
        case .embers, .hearts, .bubbles: return 270
        case .fog, .lensFlare: return 0
        case .confetti: return 90
        case .shootingStars: return 25
        }
    }
}
