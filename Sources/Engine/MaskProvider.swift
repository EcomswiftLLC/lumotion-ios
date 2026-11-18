import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import AVFoundation
import Vision

/// Finds the masks and depth maps the engine needs. Everything runs on the device; nothing is uploaded.
enum MaskProvider {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The main subject of a photo, found with Apple Vision (iOS 17). White is the subject. Returns nil when Vision finds
    /// no subject or is unavailable (for example on the CI simulator), so callers must handle nil.
    static func subjectMask(for image: CGImage) async -> MaskBuffer? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MaskBuffer?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: subjectMaskSync(image))
            }
        }
    }

    /// Blocking version of `subjectMask(for:)`. Call it off the main thread.
    static func subjectMaskSync(_ image: CGImage) -> MaskBuffer? {
        // Vision does not need more than about 1500 pixels, and the mask is soft anyway.
        let small = downscaled(image, maxPixel: 1536) ?? image
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            let maxSide = max(cg.width, cg.height)
            let k = min(1, 768.0 / Double(maxSide))
            return MaskBuffer.from(cg, width: max(1, Int(Double(cg.width) * k)), height: max(1, Int(Double(cg.height) * k)))
        } catch {
            return nil
        }
    }

    private static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        if longest <= maxPixel { return image }
        let k = Double(maxPixel) / Double(longest)
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        return PixelBuffer.scaled(image, width: w, height: h)?.makeCGImage()
    }

    /// Depth that a portrait photo carries (ImageIO auxiliary disparity or depth data), normalised so near is white.
    /// Nil when the file has no depth.
    static func embeddedDepth(fromImageData data: Data) -> MaskBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return depth(from: source)
    }

    /// Same, reading from a file.
    static func embeddedDepth(fromFileAt url: URL) -> MaskBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return depth(from: source)
    }

    private static func depth(from source: CGImageSource) -> MaskBuffer? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let types: [CFString] = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth]
        for type in types {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  let data = try? AVDepthData(fromDictionaryRepresentation: info) else { continue }
            var converted = data
            if data.depthDataType != kCVPixelFormatType_DisparityFloat32 {
                converted = data.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            }
            converted = converted.applyingExifOrientation(orientation)
            if let mask = maskBuffer(fromDisparity: converted.depthDataMap) { return mask }
        }
        return nil
    }

    private static func maskBuffer(fromDisparity buffer: CVPixelBuffer) -> MaskBuffer? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        let floats = base.assumingMemoryBound(to: Float32.self)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for y in 0..<h {
            for x in 0..<w {
                let v = floats[y * stride + x]
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
            }
        }
        guard hi > lo else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = floats[y * stride + x]
                let n = v.isFinite ? (v - lo) / (hi - lo) : 0
                out[y * w + x] = UInt8(min(255, max(0, n * 255)))
            }
        }
        return MaskBuffer(width: w, height: h, data: out)
    }

    /// A simple depth map: bottom of the frame near (white), top far (black).
    static func gradientDepth(width: Int, height: Int) -> MaskBuffer {
        let w = max(1, width), h = max(1, height)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = UInt8(min(255, max(0, ((Double(y) + 0.5) / Double(h)) * 255)))
            for x in 0..<w { out[y * w + x] = v }
        }
        return MaskBuffer(width: w, height: h, data: out)
    }

    /// Depth from painted strokes (each stroke's `value`) over a neutral grey. Strokes are in photo coordinates.
    static func manualDepth(strokes: [BrushStroke], width: Int, height: Int) -> MaskBuffer {
        let base = MaskBuffer(width: width, height: height, value: 128)
        return StrokeRaster.paintDepth(strokes, base: base)
    }
}
