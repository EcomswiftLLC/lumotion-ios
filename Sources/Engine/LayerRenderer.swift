import Foundation
import CoreGraphics
import UIKit

/// Draws text and emoji stickers over a finished frame, with their entrance, exit and idle animations.
enum LayerRenderer {
    /// What an animation does to a layer at some progress.
    struct AnimationState {
        var alpha: Double = 1
        var offsetX: Double = 0   // share of frame width
        var offsetY: Double = 0   // share of frame height
        var scale: Double = 1
        var reveal: Double = 1    // share of characters shown (typewriter)
    }

    /// Progress 0 (hidden) ... 1 (shown) turned into a transform.
    static func state(for kind: LayerAnimationKind, progress: Double) -> AnimationState {
        let t = min(max(progress, 0), 1)
        let e = t * t * (3 - 2 * t)
        var s = AnimationState()
        switch kind {
        case .none:
            break
        case .fade:
            s.alpha = e
        case .slideUp:
            s.alpha = e; s.offsetY = (1 - e) * 0.08
        case .slideDown:
            s.alpha = e; s.offsetY = -(1 - e) * 0.08
        case .slideLeft:
            s.alpha = e; s.offsetX = (1 - e) * 0.12
        case .slideRight:
            s.alpha = e; s.offsetX = -(1 - e) * 0.12
        case .pop:
            // Ease out with a little overshoot.
            let c1 = 1.70158, c3 = c1 + 1
            let back = 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
            s.scale = max(0, back)
            s.alpha = min(1, t * 3)
        case .typewriter:
            s.reveal = t
            s.alpha = t > 0 ? 1 : 0
        case .float:
            s.alpha = e; s.offsetY = (1 - e) * 0.04
        }
        return s
    }

    private struct Common {
        var enabled: Bool
        var center: NPoint
        var rotation: Double
        var scale: Double
        var entrance: LayerAnimation
        var exit: LayerAnimation
        var idle: LayerIdle
        var start: Double
        var end: Double?
    }

    /// Draws all enabled layers for the time `time` (seconds, wrapped into the loop) into `buffer`.
    static func draw(texts: [TextLayer], stickers: [StickerLayer], loop: LoopSpec, time: Double, into buffer: PixelBuffer) {
        let visibleTexts = texts.filter { $0.enabled && !$0.text.isEmpty }
        let visibleStickers = stickers.filter { $0.enabled && !$0.emoji.isEmpty }
        if visibleTexts.isEmpty && visibleStickers.isEmpty { return }
        let duration = loop.clampedDuration
        var tt = time.truncatingRemainder(dividingBy: duration)
        if tt < 0 { tt += duration }
        let phase = tt / duration
        let w = buffer.width, h = buffer.height

        buffer.withContext { ctx in
            ctx.topLeftOrigin(height: h)
            ctx.interpolationQuality = .high
            for t in visibleTexts {
                let common = Common(enabled: true, center: t.center, rotation: t.rotation, scale: t.scale, entrance: t.entrance, exit: t.exit,
                                    idle: t.idle, start: t.startTime, end: t.endTime)
                guard let anim = animation(common, time: tt, phase: phase, duration: duration) else { continue }
                let pixelSize = max(6, t.size * Double(h))
                let n = t.text.count
                let revealCount = anim.state.reveal >= 1 ? n : Int((anim.state.reveal * Double(n)).rounded(.down))
                if revealCount <= 0 { continue }
                guard let image = textImage(t, pointSize: pixelSize, revealCount: revealCount) else { continue }
                place(image, common: common, anim: anim, ctx: ctx, w: Double(w), h: Double(h))
            }
            for s in visibleStickers {
                let common = Common(enabled: true, center: s.center, rotation: s.rotation, scale: s.scale, entrance: s.entrance, exit: s.exit,
                                    idle: s.idle, start: s.startTime, end: s.endTime)
                guard let anim = animation(common, time: tt, phase: phase, duration: duration) else { continue }
                guard let image = emojiImage(s.emoji, pointSize: max(6, s.size * Double(h))) else { continue }
                place(image, common: common, anim: anim, ctx: ctx, w: Double(w), h: Double(h))
            }
        }
    }

    private struct Animated {
        var state: AnimationState
        var idleOffsetY: Double
        var idleScale: Double
        var idleRotation: Double
    }

    private static func animation(_ c: Common, time tt: Double, phase: Double, duration: Double) -> Animated? {
        let end = c.end ?? duration
        if tt < c.start || tt >= end { return nil }
        var combined = AnimationState()
        if c.entrance.kind != .none {
            let p = (tt - c.start) / max(0.05, c.entrance.duration)
            combined = state(for: c.entrance.kind, progress: p)
        }
        if c.exit.kind != .none {
            let p = (end - tt) / max(0.05, c.exit.duration)
            if p < 1 {
                let ex = state(for: c.exit.kind, progress: p)
                combined.alpha *= ex.alpha
                combined.offsetX += ex.offsetX
                combined.offsetY += ex.offsetY
                combined.scale *= ex.scale
                combined.reveal = min(combined.reveal, ex.kindReveal(c.exit.kind))
            }
        }
        var a = Animated(state: combined, idleOffsetY: 0, idleScale: 1, idleRotation: 0)
        let turn = 2 * Double.pi * phase
        switch c.idle {
        case .none: break
        case .float: a.idleOffsetY = sin(turn) * 0.012
        case .pulse: a.idleScale = 1 + 0.05 * sin(turn)
        case .sway: a.idleRotation = sin(turn) * 3
        }
        return a
    }

    private static func place(_ image: CGImage, common c: Common, anim: Animated, ctx: CGContext, w: Double, h: Double) {
        if anim.state.alpha <= 0.001 || anim.state.scale <= 0.001 { return }
        let cx = (c.center.x + anim.state.offsetX) * w
        let cy = (c.center.y + anim.state.offsetY + anim.idleOffsetY) * h
        let scale = c.scale * anim.state.scale * anim.idleScale
        let iw = Double(image.width) * scale
        let ih = Double(image.height) * scale
        ctx.saveGState()
        ctx.setAlpha(CGFloat(min(1, anim.state.alpha)))
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: CGFloat((c.rotation + anim.idleRotation) * Double.pi / 180))
        ctx.drawImageTopLeft(image, in: CGRect(x: -iw / 2, y: -ih / 2, width: iw, height: ih))
        ctx.restoreGState()
    }

    // MARK: Bitmaps

    private static let cacheLock = NSLock()
    private static var cache: [Int: CGImage] = [:]
    private static var cacheOrder: [Int] = []

    private static func cached(_ key: Int, make: () -> CGImage?) -> CGImage? {
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let made = make() else { return nil }
        cacheLock.lock()
        cache[key] = made
        cacheOrder.append(key)
        if cacheOrder.count > 96 { let old = cacheOrder.removeFirst(); cache.removeValue(forKey: old) }
        cacheLock.unlock()
        return made
    }

    private static func font(design: TextDesign, weight: TextWeight, size: CGFloat) -> UIFont {
        let w: UIFont.Weight
        switch weight {
        case .light: w = .light
        case .regular: w = .regular
        case .semibold: w = .semibold
        case .bold: w = .bold
        case .heavy: w = .heavy
        }
        let base = UIFont.systemFont(ofSize: size, weight: w)
        var descriptorDesign: UIFontDescriptor.SystemDesign?
        switch design {
        case .standard: descriptorDesign = nil
        case .serif: descriptorDesign = .serif
        case .rounded: descriptorDesign = .rounded
        case .monospaced: descriptorDesign = .monospaced
        }
        if let d = descriptorDesign, let descriptor = base.fontDescriptor.withDesign(d) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private static func uiColor(_ c: RGBAColor) -> UIColor {
        UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    private static func textImage(_ t: TextLayer, pointSize: Double, revealCount: Int) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(t.text); hasher.combine(t.design); hasher.combine(t.weight); hasher.combine(Int(pointSize.rounded()))
        hasher.combine(t.color); hasher.combine(t.outline); hasher.combine(t.shadow); hasher.combine(revealCount)
        let key = hasher.finalize()
        return cached(key) {
            let size = CGFloat(pointSize)
            let uiFont = font(design: t.design, weight: t.weight, size: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let full = NSMutableAttributedString(string: t.text)
            let range = NSRange(location: 0, length: full.length)
            full.addAttributes([.font: uiFont, .paragraphStyle: paragraph, .foregroundColor: uiColor(t.color)], range: range)
            if let outline = t.outline {
                full.addAttributes([.strokeColor: uiColor(outline), .strokeWidth: -5.0], range: range)
            }
            let shadow = NSShadow()
            if t.shadow {
                shadow.shadowColor = UIColor(white: 0, alpha: 0.55)
                shadow.shadowBlurRadius = size * 0.12
                shadow.shadowOffset = CGSize(width: 0, height: size * 0.04)
                full.addAttribute(.shadow, value: shadow, range: range)
            }
            if revealCount < t.text.count {
                // Hide the characters that have not been typed yet; layout stays the same.
                let shown = String(t.text.prefix(revealCount))
                let hidden = NSRange(location: (shown as NSString).length, length: full.length - (shown as NSString).length)
                if hidden.length > 0 {
                    full.addAttributes([.foregroundColor: UIColor.clear, .strokeColor: UIColor.clear], range: hidden)
                    full.removeAttribute(.shadow, range: hidden)
                }
            }
            let bounds = full.boundingRect(with: CGSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let pad = size * 0.4
            let canvas = CGSize(width: ceil(bounds.width + pad * 2), height: ceil(bounds.height + pad * 2))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
            let image = renderer.image { _ in
                full.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            return image.cgImage
        }
    }

    private static func emojiImage(_ emoji: String, pointSize: Double) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(emoji); hasher.combine(Int(pointSize.rounded())); hasher.combine("emoji")
        let key = hasher.finalize()
        return cached(key) {
            let size = CGFloat(pointSize)
            let font = UIFont.systemFont(ofSize: size)
            let string = NSAttributedString(string: emoji, attributes: [.font: font])
            let bounds = string.boundingRect(with: CGSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin], context: nil)
            let canvas = CGSize(width: max(1, ceil(bounds.width + size * 0.2)), height: max(1, ceil(bounds.height + size * 0.2)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
            let image = renderer.image { _ in
                string.draw(at: CGPoint(x: size * 0.1, y: size * 0.1))
            }
            return image.cgImage
        }
    }
}

private extension LayerRenderer.AnimationState {
    /// The typewriter reveal an exit animation leaves, 1 for every other kind.
    func kindReveal(_ kind: LayerAnimationKind) -> Double { kind == .typewriter ? reveal : 1 }
}
