import Foundation
import CoreGraphics
import CoreImage

/// Applies a `Look` (filter plus adjustment dials) with Core Image. For photos this runs once on the source, not per frame.
enum LookProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private struct Recipe {
        var saturation: Double = 1
        var contrast: Double = 1
        var brightness: Double = 0
        var warmth: Double = 0
        var tint: Double = 0
        var fade: Double = 0
        var tealOrange: Double = 0
        var curve: Double = 0
        var vignette: Double = 0
    }

    /// Returns a new buffer with the look applied, or the same buffer when the look changes no colours.
    static func apply(_ look: Look, to buffer: PixelBuffer) -> PixelBuffer {
        if look.isNeutralForColor { return buffer }
        let w = buffer.width, h = buffer.height
        let bytes = Data(bytes: buffer.data, count: buffer.byteCount)
        let space = PixelFormat.colorSpace
        let input = CIImage(bitmapData: bytes, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .BGRA8, colorSpace: space)
        var image = styled(input, filter: look.filter, intensity: look.intensity)
        image = adjusted(image, look.adjust)
        let out = PixelBuffer(width: w, height: h)
        context.render(image, toBitmap: out.data, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8, colorSpace: space)
        return out
    }

    // MARK: Filter

    private static func styled(_ image: CIImage, filter: LookID, intensity: Double) -> CIImage {
        guard filter != .original, intensity > 0 else { return image }
        let result = recipe(filter, image)
        if intensity >= 99.5 { return result }
        let amount = CGFloat(min(max(intensity, 0), 100) / 100)
        let faded = result.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount),
        ])
        return faded.composited(over: image).cropped(to: image.extent)
    }

    private static func recipe(_ id: LookID, _ image: CIImage) -> CIImage {
        switch id {
        case .original: return image
        case .lumen: return run(image, Recipe(saturation: 1.10, contrast: 1.06, brightness: 0.01, curve: 0.5))
        case .ivory: return run(image, Recipe(saturation: 0.95, contrast: 0.98, brightness: 0.04, warmth: 0.18, fade: 0.1))
        case .gilt: return run(image, Recipe(saturation: 1.15, contrast: 1.05, brightness: 0.02, warmth: 0.55, curve: 0.3, vignette: 0.25))
        case .rosette: return run(image, Recipe(saturation: 1.0, contrast: 0.97, brightness: 0.03, warmth: 0.12, tint: 0.35, fade: 0.08))
        case .verdant: return run(image, Recipe(saturation: 1.28, contrast: 1.1, warmth: -0.08, tint: -0.2, curve: 0.4))
        case .cinema: return run(image, Recipe(saturation: 1.05, contrast: 1.12, tealOrange: 0.85, curve: 0.5, vignette: 0.3))
        case .nocturne: return run(image, Recipe(saturation: 0.92, contrast: 1.16, brightness: -0.05, warmth: -0.4, curve: 0.6, vignette: 0.4))
        case .parchment:
            let sepia = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
            return run(sepia, Recipe(contrast: 1.05, fade: 0.1, vignette: 0.2))
        case .matte: return run(image, Recipe(saturation: 0.9, contrast: 0.93, fade: 0.45))
        case .riviera: return run(image, Recipe(saturation: 1.2, contrast: 1.04, brightness: 0.03, warmth: 0.3, curve: 0.25))
        case .slate: return run(image, Recipe(saturation: 0.6, contrast: 1.1, warmth: -0.2, curve: 0.4))
        case .amber: return run(image, Recipe(saturation: 1.1, contrast: 1.04, warmth: 0.75, fade: 0.15))
        case .polar: return run(image, Recipe(saturation: 0.9, contrast: 1.02, brightness: 0.05, warmth: -0.55, fade: 0.08))
        case .vivid: return run(image, Recipe(saturation: 1.45, contrast: 1.1, curve: 0.35))
        case .dusk: return run(image, Recipe(saturation: 1.05, contrast: 1.08, warmth: 0.25, fade: 0.1, tealOrange: 0.5, vignette: 0.35))
        case .instant: return image.applyingFilter("CIPhotoEffectInstant")
        case .chrome: return image.applyingFilter("CIPhotoEffectChrome")
        case .noir: return image.applyingFilter("CIPhotoEffectNoir")
        case .mono: return image.applyingFilter("CIPhotoEffectMono")
        case .tonal: return image.applyingFilter("CIPhotoEffectTonal")
        case .faded: return image.applyingFilter("CIPhotoEffectFade")
        case .transfer: return image.applyingFilter("CIPhotoEffectTransfer")
        case .silver:
            let grey = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            return run(grey, Recipe(contrast: 1.12, brightness: 0.02, fade: 0.12, curve: 0.5, vignette: 0.2))
        case .ink:
            let grey = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            return run(grey, Recipe(contrast: 1.5, brightness: -0.04, curve: 0.8, vignette: 0.45))
        }
    }

    private static func run(_ input: CIImage, _ r: Recipe) -> CIImage {
        var image = input
        let extent = input.extent
        if r.saturation != 1 || r.contrast != 1 || r.brightness != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: r.saturation, kCIInputContrastKey: r.contrast, kCIInputBrightnessKey: r.brightness,
            ])
        }
        if r.warmth != 0 || r.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + r.warmth * 2200), y: CGFloat(r.tint * -60)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if r.curve > 0 {
            let c = r.curve * 0.07
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - c),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + c),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if r.tealOrange > 0 {
            let t = CGFloat(r.tealOrange)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.07 * t, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.09 * t, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.03 * t, y: 0.006 * t, z: 0.045 * t, w: 0),
            ])
        }
        if r.fade > 0 {
            let f = CGFloat(r.fade)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - 0.16 * f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.16 * f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.16 * f, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.13 * f, y: 0.13 * f, z: 0.13 * f, w: 0),
            ])
        }
        if r.vignette > 0 { image = vignette(image, amount: r.vignette) }
        return image.cropped(to: extent)
    }

    private static func vignette(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let radius = hypot(extent.width, extent.height) * 0.5 * (1.05 - 0.35 * amount)
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount * 1.1,
            "inputFalloff": 0.6,
        ]).cropped(to: extent)
    }

    // MARK: Adjust dials

    private static func adjusted(_ input: CIImage, _ a: LookAdjust) -> CIImage {
        var image = input
        let extent = input.extent
        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure * 2])
        }
        if a.contrast != 0 || a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + a.contrast * 0.6,
                kCIInputSaturationKey: max(0, 1 + a.saturation),
            ])
        }
        if a.warmth != 0 || a.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + a.warmth * 2200), y: CGFloat(a.tint * -60)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if a.shadows != 0 || a.highlights < 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": a.shadows,
                "inputHighlightAmount": 1 + min(0, a.highlights),
            ])
        }
        if a.highlights > 0 {
            let lift = a.highlights * 0.12
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: min(1, 0.75 + lift)),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if a.sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpen * 1.5])
        }
        if a.glow > 0 {
            let radius = max(extent.width, extent.height) * 0.012
            image = image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: a.glow])
        }
        if a.vignette > 0 { image = vignette(image, amount: a.vignette) }
        return image.cropped(to: extent)
    }
}
