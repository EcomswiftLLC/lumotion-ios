import Foundation
import CoreGraphics

/// One-tap Magic Presets. Presets are starting points: they set effects, overlays, camera, look and loop length and add
/// a default flow region that the person can edit. They are honest: a preset that needs a subject mask or a flow area
/// uses a sensible default (gradient depth, a band across the frame) rather than pretending to understand the photo.
enum PresetLibrary {
    /// All presets in display order. The ids are stable and match `Sources/Resources/Samples/samples.json`.
    static let all: [PresetInfo] = [
        PresetInfo(id: "waterfall", name: "Waterfall", summary: "Water pours down the middle of the frame in a seamless loop. Paint the real water to fit your photo.", category: .flow, symbol: "drop.fill"),
        PresetInfo(id: "ocean-waves", name: "Ocean waves", summary: "The lower part of the frame rolls sideways with gentle swell. Adjust the area to match the water.", category: .flow, symbol: "water.waves"),
        PresetInfo(id: "clouds-drift", name: "Clouds drift", summary: "The upper part of the frame drifts slowly across with a soft camera sway.", category: .flow, symbol: "cloud.fill"),
        PresetInfo(id: "wind-in-hair", name: "Wind in hair", summary: "A wind sway that grows towards the top of the frame, with a few drifting petals.", category: .flow, symbol: "wind"),
        PresetInfo(id: "golden-hour-dust", name: "Golden hour dust", summary: "Warm light, floating dust and a slow sweep of light.", category: .light, symbol: "sun.max.fill"),
        PresetInfo(id: "fireflies-dusk", name: "Fireflies dusk", summary: "Glowing fireflies over a dusk look.", category: .light, symbol: "sparkle"),
        PresetInfo(id: "dream-sparkle", name: "Dream sparkle", summary: "Twinkling glints, soft bokeh and a gentle glow.", category: .light, symbol: "sparkles"),
        PresetInfo(id: "starry-night", name: "Starry night", summary: "Twinkling stars with the odd shooting star.", category: .light, symbol: "moon.stars.fill"),
        PresetInfo(id: "ember-glow", name: "Ember glow", summary: "Rising embers and heat shimmer over a flickering warm look.", category: .light, symbol: "flame.fill"),
        PresetInfo(id: "rainy-window", name: "Rainy window", summary: "Rain, mist and a cool grey look.", category: .weather, symbol: "cloud.rain.fill"),
        PresetInfo(id: "snow-globe", name: "Snow globe", summary: "Falling snow with a few glints and a cold look.", category: .weather, symbol: "snowflake"),
        PresetInfo(id: "neon-rain", name: "Neon rain", summary: "Cyan-tinted rain, glowing bokeh and a touch of glitch.", category: .weather, symbol: "bolt.fill"),
        PresetInfo(id: "autumn-leaves", name: "Autumn leaves", summary: "Leaves tumble past a warm amber look with a light breeze.", category: .weather, symbol: "leaf.fill"),
        PresetInfo(id: "glitch-vhs", name: "Glitch VHS", summary: "Slipping scan lines, colour splits and film grain.", category: .light, symbol: "waveform"),
        PresetInfo(id: "party-confetti", name: "Party confetti", summary: "Confetti falls over a bright, saturated look.", category: .light, symbol: "gift.fill"),
        PresetInfo(id: "love-hearts", name: "Love hearts", summary: "Hearts rise and sparkle over a soft pink look.", category: .light, symbol: "heart.fill"),
        PresetInfo(id: "cinematic-push-in", name: "Cinematic push-in", summary: "A slow push towards the middle of the frame, then back, with a film look.", category: .camera, symbol: "viewfinder"),
        PresetInfo(id: "parallax-portrait", name: "Parallax portrait", summary: "Foreground and background drift apart in 3D. Uses the subject found in your photo when there is one.", category: .camera, symbol: "person.crop.square"),
    ]

    static func info(for id: String) -> PresetInfo? { all.first { $0.id == id } }

    /// Returns `base` with the preset applied: source, canvas, text, stickers, audio and title are kept; flow, effects,
    /// overlays, camera, parallax and look are replaced. Unknown ids return `base` unchanged.
    static func apply(_ id: String, to base: Project) -> Project {
        guard info(for: id) != nil else { return base }
        var p = base
        p.flowRegions = []
        p.anchors = []
        p.camera = CameraMotion()
        p.parallax = ParallaxSettings()
        p.livingEffects = []
        p.overlays = []
        p.look = Look()
        p.presetID = id
        let aspect = max(0.1, p.canvas.aspect.ratio(sourceAspect: p.source.aspect))
        if p.source.kind == .still { p.loop.duration = 4 }

        func overlay(_ kind: OverlayKind, _ intensity: Double, speed: Double = 1, size: Double = 1, tint: RGBAColor? = nil,
                     direction: Double? = nil, depthBlur: Double = 0.4, seed: Int = 7) {
            p.overlays.append(OverlayLayer(kind: kind, intensity: intensity, speed: speed, size: size, tint: tint, direction: direction,
                                           depthBlur: depthBlur, seed: seed))
        }
        func effect(_ kind: LivingEffectKind, _ strength: Double, speed: Double = 1, scale: Double = 1, angle: Double = 0,
                    gradient: GradientMask? = nil) {
            p.livingEffects.append(LivingEffect(kind: kind, strength: strength, speed: speed, scale: scale, angle: angle, gradient: gradient))
        }
        func flow(_ name: String, _ strokes: [BrushStroke], _ arrows: [FlowArrow], speed: Double, strength: Double) {
            p.flowRegions.append(FlowRegion(name: name, strokes: strokes, arrows: arrows, speed: speed, strength: strength, softness: 0.6))
        }
        let topDown = GradientMask(start: NPoint(0.5, 0), end: NPoint(0.5, 1), softness: 0.6, invert: false)
        let bottomUp = GradientMask(start: NPoint(0.5, 1), end: NPoint(0.5, 0), softness: 0.6, invert: false)

        switch id {
        case "waterfall":
            flow("Falling water", [column(aspect, x: 0.5, width: 0.3, from: 0.08, to: 0.8)],
                 [FlowArrow(from: NPoint(0.5, 0.2), to: NPoint(0.5, 0.7)), FlowArrow(from: NPoint(0.45, 0.3), to: NPoint(0.45, 0.75)),
                  FlowArrow(from: NPoint(0.55, 0.3), to: NPoint(0.55, 0.75))], speed: 1.4, strength: 0.7)
            flow("Pool", [band(aspect, y: 0.86, height: 0.2)], [FlowArrow(from: NPoint(0.2, 0.86), to: NPoint(0.8, 0.88))], speed: 0.8, strength: 0.4)
            overlay(.fog, 0.3, speed: 0.6)
            p.look = Look(filter: .verdant, intensity: 55)
        case "ocean-waves":
            flow("Water", [band(aspect, y: 0.78, height: 0.42)],
                 [FlowArrow(from: NPoint(0.15, 0.72), to: NPoint(0.85, 0.74)), FlowArrow(from: NPoint(0.85, 0.86), to: NPoint(0.15, 0.84))], speed: 1, strength: 0.55)
            effect(.waves, 0.35, speed: 0.8, scale: 1, angle: 0, gradient: bottomUp)
            p.camera = CameraMotion(kind: .zoomIn, amount: 0.25, easing: .easeInOut, loops: true)
            p.look = Look(filter: .riviera, intensity: 60)
        case "clouds-drift":
            flow("Sky", [band(aspect, y: 0.2, height: 0.4)], [FlowArrow(from: NPoint(0.15, 0.2), to: NPoint(0.85, 0.2)), FlowArrow(from: NPoint(0.2, 0.35), to: NPoint(0.8, 0.33))], speed: 0.6, strength: 0.45)
            p.camera = CameraMotion(kind: .drift, amount: 0.3, easing: .easeInOut, loops: true)
            p.look = Look(filter: .lumen, intensity: 70)
            p.loop.duration = 6
        case "wind-in-hair":
            effect(.windSway, 0.6, speed: 1, scale: 1, angle: 0, gradient: topDown.inverted())
            overlay(.petals, 0.25, speed: 0.8)
            p.camera = CameraMotion(kind: .drift, amount: 0.2, easing: .easeInOut, loops: true)
            p.look = Look(filter: .ivory, intensity: 60)
        case "golden-hour-dust":
            overlay(.dust, 0.6, speed: 0.8, tint: RGBAColor(1, 0.85, 0.55))
            overlay(.lightLeaks, 0.4)
            effect(.lightSweep, 0.3, speed: 0.5, scale: 1.4, angle: 20)
            p.camera = CameraMotion(kind: .breathe, amount: 0.3)
            p.look = Look(filter: .gilt, intensity: 70, adjust: LookAdjust(glow: 0.25), animatedGrain: true, flicker: Flicker(amount: 0.15, speed: 0.8))
        case "fireflies-dusk":
            overlay(.fireflies, 0.7, speed: 1, size: 1.1)
            overlay(.dust, 0.25, speed: 0.6, tint: RGBAColor(1, 0.9, 0.6))
            p.camera = CameraMotion(kind: .drift, amount: 0.3, easing: .easeInOut, loops: true)
            p.look = Look(filter: .dusk, intensity: 85, adjust: LookAdjust(vignette: 0.3))
        case "dream-sparkle":
            overlay(.sparkles, 0.7, speed: 1)
            overlay(.bokeh, 0.4, speed: 0.8, depthBlur: 0.8)
            effect(.pulse, 0.3, speed: 0.7)
            p.camera = CameraMotion(kind: .breathe, amount: 0.35)
            p.look = Look(filter: .rosette, intensity: 60, adjust: LookAdjust(glow: 0.5))
        case "starry-night":
            overlay(.stars, 0.8, speed: 1)
            overlay(.shootingStars, 0.3, speed: 1)
            p.look = Look(filter: .nocturne, intensity: 70, adjust: LookAdjust(vignette: 0.2))
            p.loop.duration = 6
        case "ember-glow":
            overlay(.embers, 0.7, speed: 1)
            effect(.heatHaze, 0.4, speed: 1, gradient: bottomUp)
            p.look = Look(filter: .amber, intensity: 60, adjust: LookAdjust(vignette: 0.3), animatedGrain: true, flicker: Flicker(amount: 0.3, speed: 1.2))
        case "rainy-window":
            overlay(.rain, 0.6, speed: 1)
            overlay(.fog, 0.3, speed: 0.6)
            effect(.heatHaze, 0.2, speed: 0.6)
            p.look = Look(filter: .slate, intensity: 80, adjust: LookAdjust(grain: 0.25))
        case "snow-globe":
            overlay(.snow, 0.7, speed: 1)
            overlay(.sparkles, 0.25, speed: 0.8)
            p.camera = CameraMotion(kind: .breathe, amount: 0.2)
            p.look = Look(filter: .polar, intensity: 60)
        case "neon-rain":
            overlay(.rain, 0.7, speed: 1.1, tint: RGBAColor(0.55, 0.9, 1))
            overlay(.bokeh, 0.35, speed: 0.8, tint: RGBAColor(1, 0.45, 0.8), depthBlur: 0.8)
            effect(.glitch, 0.15, speed: 0.6)
            p.camera = CameraMotion(kind: .shake, amount: 0.2)
            p.look = Look(filter: .cinema, intensity: 85, adjust: LookAdjust(saturation: 0.2, glow: 0.3))
        case "autumn-leaves":
            overlay(.leaves, 0.6, speed: 1)
            effect(.windSway, 0.25, speed: 0.8, gradient: topDown.inverted())
            p.look = Look(filter: .amber, intensity: 65)
        case "glitch-vhs":
            effect(.glitch, 0.6, speed: 1)
            effect(.shimmer, 0.2, speed: 1)
            p.look = Look(filter: .faded, intensity: 70, adjust: LookAdjust(grain: 0.5), animatedGrain: true, flicker: Flicker(amount: 0.3, speed: 1))
        case "party-confetti":
            overlay(.confetti, 0.7, speed: 1)
            overlay(.sparkles, 0.3, speed: 1)
            p.look = Look(filter: .vivid, intensity: 60)
        case "love-hearts":
            overlay(.hearts, 0.6, speed: 1)
            overlay(.sparkles, 0.3, speed: 0.8)
            p.look = Look(filter: .rosette, intensity: 70, adjust: LookAdjust(glow: 0.25))
        case "cinematic-push-in":
            p.camera = CameraMotion(kind: .zoomIn, amount: 0.6, easing: .easeInOut, loops: true)
            p.look = Look(filter: .cinema, intensity: 80, adjust: LookAdjust(vignette: 0.3, grain: 0.25), animatedGrain: true)
            p.loop.duration = 5
        case "parallax-portrait":
            p.parallax = ParallaxSettings(enabled: true, depthSource: .subjectMask, style: .orbit, strength: 0.55, edgeFill: .blur, invertDepth: false)
            overlay(.dust, 0.25, speed: 0.7)
            p.look = Look(filter: .lumen, intensity: 60)
        default:
            break
        }
        _ = aspect
        return p
    }

    // MARK: Default flow areas

    /// A horizontal band across the frame. `y` is the centre and `height` the thickness, both as a share of the frame height.
    private static func band(_ aspect: Double, y: Double, height: Double) -> BrushStroke {
        // Brush radius is a share of the LONG edge, so convert the half thickness.
        let radius = aspect >= 1 ? height / (2 * aspect) : height / 2
        return BrushStroke(points: [NPoint(0.02, y), NPoint(0.98, y)], radius: radius, feather: 0.8)
    }

    /// A vertical column. `x` is the centre and `width` the thickness as a share of the frame width.
    private static func column(_ aspect: Double, x: Double, width: Double, from: Double, to: Double) -> BrushStroke {
        let radius = aspect >= 1 ? width / 2 : width * aspect / 2
        return BrushStroke(points: [NPoint(x, from), NPoint(x, to)], radius: radius, feather: 0.8)
    }
}

private extension GradientMask {
    /// The same ramp running the other way.
    func inverted() -> GradientMask {
        var g = self
        g.invert.toggle()
        return g
    }
}
