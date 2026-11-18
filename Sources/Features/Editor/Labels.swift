import Foundation

/// Plain names and symbols for the engine's options, so the screens never show a raw identifier.
enum Labels {
    static func camera(_ kind: CameraKind) -> String {
        switch kind {
        case .none: return "None"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .pan: return "Pan"
        case .drift: return "Drift"
        case .rotate: return "Rotate"
        case .shake: return "Handheld"
        case .breathe: return "Breathe"
        case .custom: return "Custom"
        }
    }

    static func direction(_ direction: PanDirection) -> String {
        switch direction {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .upLeft: return "Up left"
        case .upRight: return "Up right"
        case .downLeft: return "Down left"
        case .downRight: return "Down right"
        }
    }

    static func directionSymbol(_ direction: PanDirection) -> String {
        switch direction {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .upLeft: return "arrow.up.left"
        case .upRight: return "arrow.up.right"
        case .downLeft: return "arrow.down.left"
        case .downRight: return "arrow.down.right"
        }
    }

    static func easing(_ easing: Easing) -> String {
        switch easing {
        case .linear: return "Steady"
        case .easeIn: return "Ease in"
        case .easeOut: return "Ease out"
        case .easeInOut: return "Smooth"
        }
    }

    static func depthSource(_ source: DepthSource) -> String {
        switch source {
        case .subjectMask: return "Subject"
        case .embeddedDepth: return "Photo depth"
        case .manualBrush: return "Painted"
        case .gradient: return "Gradient"
        }
    }

    static func parallaxStyle(_ style: ParallaxStyle) -> String {
        switch style {
        case .dolly: return "Dolly"
        case .orbit: return "Orbit"
        case .swing: return "Swing"
        case .push: return "Push in"
        }
    }

    static func edgeFill(_ fill: EdgeFill) -> String {
        switch fill {
        case .stretch: return "Stretch"
        case .mirror: return "Mirror"
        case .blur: return "Blur"
        }
    }

    static func effect(_ kind: LivingEffectKind) -> String {
        switch kind {
        case .ripple: return "Water ripple"
        case .waves: return "Waves"
        case .windSway: return "Wind sway"
        case .heatHaze: return "Heat haze"
        case .shimmer: return "Shimmer"
        case .pulse: return "Pulse"
        case .lightSweep: return "Light sweep"
        case .glitch: return "Glitch"
        case .wobble: return "Wobble"
        case .wiggle: return "Wiggle"
        case .swirl: return "Ink swirl"
        }
    }

    static func effectSymbol(_ kind: LivingEffectKind) -> String {
        switch kind {
        case .ripple: return "drop"
        case .waves: return "water.waves"
        case .windSway: return "wind"
        case .heatHaze: return "thermometer.sun"
        case .shimmer: return "sparkle"
        case .pulse: return "circle.dotted"
        case .lightSweep: return "sun.max"
        case .glitch: return "waveform.path.ecg"
        case .wobble: return "arrow.left.and.right"
        case .wiggle: return "scribble"
        case .swirl: return "tornado"
        }
    }

    /// Effects that spread from a point, so the centre matters.
    static func usesCenter(_ kind: LivingEffectKind) -> Bool {
        switch kind {
        case .ripple, .swirl, .pulse, .wobble: return true
        default: return false
        }
    }

    /// Effects that travel in a direction, so the angle matters.
    static func usesAngle(_ kind: LivingEffectKind) -> Bool {
        switch kind {
        case .waves, .windSway, .lightSweep, .glitch, .heatHaze: return true
        default: return false
        }
    }

    static func overlay(_ kind: OverlayKind) -> String {
        switch kind {
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .snow: return "Snow"
        case .blizzard: return "Blizzard"
        case .leaves: return "Falling leaves"
        case .petals: return "Petals"
        case .fireflies: return "Fireflies"
        case .sparkles: return "Sparkles"
        case .bokeh: return "Bokeh"
        case .dust: return "Dust motes"
        case .embers: return "Embers"
        case .fog: return "Fog"
        case .lensFlare: return "Lens flare"
        case .lightLeaks: return "Light leaks"
        case .stars: return "Twinkling stars"
        case .confetti: return "Confetti"
        case .hearts: return "Hearts"
        case .bubbles: return "Bubbles"
        case .shootingStars: return "Shooting stars"
        case .fireworks: return "Fireworks"
        }
    }

    static func overlaySymbol(_ kind: OverlayKind) -> String {
        switch kind {
        case .rain, .heavyRain: return "cloud.rain"
        case .snow, .blizzard: return "snowflake"
        case .leaves: return "leaf"
        case .petals: return "camera.macro"
        case .fireflies: return "circle.hexagongrid"
        case .sparkles: return "sparkles"
        case .bokeh: return "circle.circle"
        case .dust: return "smallcircle.filled.circle"
        case .embers: return "flame"
        case .fog: return "cloud.fog"
        case .lensFlare: return "sun.max"
        case .lightLeaks: return "rays"
        case .stars: return "star"
        case .confetti: return "party.popper"
        case .hearts: return "heart"
        case .bubbles: return "bubbles.and.sparkles"
        case .shootingStars: return "moon.stars"
        case .fireworks: return "fireworks"
        }
    }

    static func placement(_ placement: OverlayPlacement) -> String {
        placement == .over ? "In front" : "Behind subject"
    }

    static func layerAnimation(_ kind: LayerAnimationKind) -> String {
        switch kind {
        case .none: return "None"
        case .fade: return "Fade"
        case .slideUp: return "Slide up"
        case .slideDown: return "Slide down"
        case .slideLeft: return "Slide left"
        case .slideRight: return "Slide right"
        case .pop: return "Pop"
        case .typewriter: return "Typewriter"
        case .float: return "Float"
        }
    }

    static func idle(_ idle: LayerIdle) -> String {
        switch idle {
        case .none: return "Still"
        case .float: return "Float"
        case .pulse: return "Pulse"
        case .sway: return "Sway"
        }
    }

    static func textDesign(_ design: TextDesign) -> String {
        switch design {
        case .standard: return "Sans"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        }
    }

    static func textWeight(_ weight: TextWeight) -> String {
        switch weight {
        case .light: return "Light"
        case .regular: return "Regular"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        case .heavy: return "Heavy"
        }
    }

    static func loopMode(_ mode: LoopMode) -> String {
        mode == .loop ? "Seamless loop" : "Ping-pong"
    }
}
