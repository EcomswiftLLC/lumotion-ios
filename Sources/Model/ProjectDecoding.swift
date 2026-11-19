import Foundation
import CoreGraphics

// MARK: - Lenient project decoding
//
// A project file written by a newer build may carry keys, enum cases or values this build does not know, and a file from an
// older build lacks keys that were added later. Every model type below therefore decodes each field on its own: a missing
// or unreadable field takes the type's default, an unknown element of an array is skipped, and only the few fields that
// identify a thing (a source file name, an effect kind, the text of a text layer) are required. Encoding is unchanged
// (synthesised), so the JSON shape does not change.

/// A coding key made from any string, so one helper serves every type.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Decodes one array element and turns a failure into nil instead of an error.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer where K == DynamicKey {
    /// The value for `key`, or `fallback` when it is missing or cannot be read.
    func get<T: Decodable>(_ key: String, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: DynamicKey(key))) ?? fallback
    }

    /// The optional value for `key`; nil when missing or unreadable.
    func opt<T: Decodable>(_ key: String) -> T? {
        (try? decodeIfPresent(T.self, forKey: DynamicKey(key))) ?? nil
    }

    /// The required value for `key`; throws when it is missing or unreadable.
    func need<T: Decodable>(_ key: String) throws -> T {
        try decode(T.self, forKey: DynamicKey(key))
    }

    /// An array that skips the elements it cannot read.
    func list<T: Decodable>(_ key: String, as type: T.Type = T.self) -> [T] {
        let boxes = (try? decodeIfPresent([Lossy<T>].self, forKey: DynamicKey(key))) ?? nil
        return (boxes ?? []).compactMap { $0.value }
    }
}

extension BrushStroke {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let points: [NPoint] = c.list("points")
        self.init(id: c.get("id", UUID()), points: points)
        radius = c.get("radius", radius)
        feather = c.get("feather", feather)
        erase = c.get("erase", erase)
        value = c.get("value", value)
    }
}

extension SourceSpec {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(kind: try c.need("kind"), fileName: try c.need("fileName"), pixelWidth: try c.need("pixelWidth"),
                  pixelHeight: try c.need("pixelHeight"), videoDuration: c.get("videoDuration", 0))
    }
}

extension CanvasSpec {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        aspect = c.get("aspect", aspect)
        fit = c.get("fit", fit)
        centerX = c.get("centerX", centerX)
        centerY = c.get("centerY", centerY)
        zoom = c.get("zoom", zoom)
        background = c.get("background", background)
        backgroundColor = c.get("backgroundColor", backgroundColor)
    }
}

extension LoopSpec {
    /// Loops are validated on decode: fps is one of 24, 30, 60 (else 30), the duration is 1...15 seconds and the speed
    /// is positive (0.25...4), so a damaged or hand-edited file cannot ask the engine for an impossible loop.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let d: Double = c.get("duration", duration)
        duration = d.isFinite ? min(max(d, LoopSpec.durationRange.lowerBound), LoopSpec.durationRange.upperBound) : 4
        let f: Int = c.get("fps", fps)
        fps = LoopSpec.allowedFPS.contains(f) ? f : 30
        mode = c.get("mode", mode)
        reverse = c.get("reverse", reverse)
        let s: Double = c.get("speed", speed)
        speed = s.isFinite && s > 0 ? min(max(s, 0.25), 4) : 1
    }
}

extension FlowArrow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(from: try c.need("from"), to: try c.need("to"))
    }
}

extension FlowRegion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(id: c.get("id", UUID()))
        name = c.get("name", name)
        enabled = c.get("enabled", enabled)
        strokes = c.list("strokes")
        arrows = c.list("arrows")
        speed = c.get("speed", speed)
        strength = c.get("strength", strength)
        softness = c.get("softness", softness)
    }
}

extension CameraFraming {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        zoom = c.get("zoom", zoom)
        offsetX = c.get("offsetX", offsetX)
        offsetY = c.get("offsetY", offsetY)
        rotation = c.get("rotation", rotation)
    }
}

extension CameraMotion {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        kind = c.get("kind", kind)
        direction = c.get("direction", direction)
        amount = c.get("amount", amount)
        easing = c.get("easing", easing)
        loops = c.get("loops", loops)
        start = c.get("start", start)
        end = c.get("end", end)
    }
}

extension ParallaxSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        enabled = c.get("enabled", enabled)
        depthSource = c.get("depthSource", depthSource)
        style = c.get("style", style)
        strength = c.get("strength", strength)
        edgeFill = c.get("edgeFill", edgeFill)
        invertDepth = c.get("invertDepth", invertDepth)
        depthStrokes = c.list("depthStrokes")
    }
}

extension GradientMask {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        start = c.get("start", start)
        end = c.get("end", end)
        softness = c.get("softness", softness)
        invert = c.get("invert", invert)
    }
}

extension LivingEffect {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        // An effect kind this build does not know cannot be drawn: the whole effect is dropped by the lossy array.
        self.init(id: c.get("id", UUID()), kind: try c.need("kind"))
        enabled = c.get("enabled", enabled)
        strength = c.get("strength", strength)
        speed = c.get("speed", speed)
        scale = c.get("scale", scale)
        angle = c.get("angle", angle)
        center = c.get("center", center)
        gradient = c.opt("gradient")
        brush = c.list("brush")
    }
}

extension OverlayLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let kind: OverlayKind = try c.need("kind")
        self.init(id: c.get("id", UUID()), kind: kind)
        enabled = c.get("enabled", enabled)
        intensity = c.get("intensity", intensity)
        speed = c.get("speed", speed)
        size = c.get("size", size)
        tint = c.opt("tint")
        direction = c.get("direction", OverlayLayer.naturalDirection(kind))
        depthBlur = c.get("depthBlur", depthBlur)
        placement = c.get("placement", placement)
        seed = c.get("seed", seed)
    }
}

extension LookAdjust {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        exposure = c.get("exposure", exposure)
        contrast = c.get("contrast", contrast)
        saturation = c.get("saturation", saturation)
        warmth = c.get("warmth", warmth)
        tint = c.get("tint", tint)
        highlights = c.get("highlights", highlights)
        shadows = c.get("shadows", shadows)
        sharpen = c.get("sharpen", sharpen)
        vignette = c.get("vignette", vignette)
        grain = c.get("grain", grain)
        glow = c.get("glow", glow)
    }
}

extension Flicker {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        amount = c.get("amount", amount)
        speed = c.get("speed", speed)
    }
}

extension Look {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        filter = c.get("filter", filter)
        intensity = c.get("intensity", intensity)
        adjust = c.get("adjust", adjust)
        animatedGrain = c.get("animatedGrain", animatedGrain)
        flicker = c.get("flicker", flicker)
    }
}

extension LayerAnimation {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        kind = c.get("kind", kind)
        duration = c.get("duration", duration)
    }
}

extension TextLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(id: c.get("id", UUID()), text: try c.need("text"))
        design = c.get("design", design)
        weight = c.get("weight", weight)
        size = c.get("size", size)
        color = c.get("color", color)
        shadow = c.get("shadow", shadow)
        outline = c.opt("outline")
        center = c.get("center", center)
        rotation = c.get("rotation", rotation)
        scale = c.get("scale", scale)
        entrance = c.get("entrance", entrance)
        self.exit = c.get("exit", self.exit)
        idle = c.get("idle", idle)
        startTime = c.get("startTime", startTime)
        endTime = c.opt("endTime")
        enabled = c.get("enabled", enabled)
    }
}

extension StickerLayer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.init(id: c.get("id", UUID()), emoji: try c.need("emoji"))
        size = c.get("size", size)
        center = c.get("center", center)
        rotation = c.get("rotation", rotation)
        scale = c.get("scale", scale)
        entrance = c.get("entrance", entrance)
        self.exit = c.get("exit", self.exit)
        idle = c.get("idle", idle)
        startTime = c.get("startTime", startTime)
        endTime = c.opt("endTime")
        enabled = c.get("enabled", enabled)
    }
}

extension AudioTrackSpec {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let name: String = try c.need("fileName")
        self.init(fileName: name, displayName: c.get("displayName", name))
        trimStart = c.get("trimStart", trimStart)
        trimEnd = c.opt("trimEnd")
        volume = c.get("volume", volume)
        fadeIn = c.get("fadeIn", fadeIn)
        fadeOut = c.get("fadeOut", fadeOut)
        loops = c.get("loops", loops)
        muted = c.get("muted", muted)
    }
}

extension CinemagraphSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        segmentStart = c.get("segmentStart", segmentStart)
        segmentEnd = c.get("segmentEnd", segmentEnd)
        stillTime = c.get("stillTime", stillTime)
        loopSmoothing = c.get("loopSmoothing", loopSmoothing)
        maskStrokes = c.list("maskStrokes")
        pingPong = c.get("pingPong", pingPong)
        stabilize = c.get("stabilize", stabilize)
    }
}
