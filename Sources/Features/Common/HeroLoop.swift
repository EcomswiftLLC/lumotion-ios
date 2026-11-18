import SwiftUI
import UIKit
import ImageIO

/// A calm, endlessly looping window used on Welcome and Home.
/// With a sample photo it is a slow push-in with a sweep of light (a camera move, which is one of the things Lumotion
/// makes). With no photo it is the aperture mark turning by exactly one blade, so the loop is seamless.
/// Reduce Motion freezes it on the first frame.
struct HeroLoopView: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 26
    /// Seconds for one full loop.
    var period: Double = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                loopFrame(size: geo.size, phase: phase)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LM.Palette.line, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func loopFrame(size: CGSize, phase: Double) -> some View {
        let angle = phase * 2 * Double.pi
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.07 + 0.035 * (0.5 - 0.5 * cos(angle)))
                    .offset(x: CGFloat(sin(angle)) * size.width * 0.012, y: CGFloat(cos(angle)) * size.height * 0.008)
                    .clipped()
                // A band of light that crosses the picture once per loop.
                LinearGradient(
                    colors: [Color.clear, LM.Palette.glow.opacity(0.20), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: size.width * 0.55)
                .offset(x: CGFloat(phase * 2 - 1) * size.width * 0.9)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            } else {
                LinearGradient(colors: [LM.Palette.graphite, LM.Palette.lens], startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [LM.Palette.glow.opacity(0.28), Color.clear],
                    center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.6
                )
                ApertureMark(lineWidth: 1.2, color: LM.Palette.glow.opacity(0.9), openness: 0.24)
                    .rotationEffect(.degrees(phase * 60))
                    .frame(width: min(size.width, size.height) * 0.62, height: min(size.width, size.height) * 0.62)
                ApertureMark(lineWidth: 0.8, color: LM.Palette.paper.opacity(0.18), openness: 0.2)
                    .rotationEffect(.degrees(-phase * 60))
                    .frame(width: min(size.width, size.height) * 0.92, height: min(size.width, size.height) * 0.92)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

enum Thumbnails {
    /// A small decoded copy of an image file, made without loading the full picture.
    static func make(url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
