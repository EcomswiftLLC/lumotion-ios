import SwiftUI
import AVFoundation

// MARK: - Filmstrip

/// A row of frames from a video, made in the background.
@MainActor
final class FilmstripLoader: ObservableObject {
    @Published private(set) var images: [UIImage] = []
    private var loadedURL: URL?

    func load(url: URL, count: Int = 12) {
        guard loadedURL != url else { return }
        loadedURL = url
        images = []
        Task {
            let result = await Task.detached(priority: .utility) { () -> [UIImage] in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 240)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                let seconds = CMTimeGetSeconds(asset.duration)
                guard seconds.isFinite, seconds > 0 else { return [] }
                var frames: [UIImage] = []
                for index in 0..<count {
                    let at = seconds * (Double(index) + 0.5) / Double(count)
                    if let cg = try? generator.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil) {
                        frames.append(UIImage(cgImage: cg))
                    }
                }
                return frames
            }.value
            images = result
        }
    }
}

/// Filmstrip with two handles that choose the loop segment (at most `maxSegment` seconds) and a marker for the frozen frame.
struct FilmstripTrimmer: View {
    let duration: Double
    let images: [UIImage]
    @Binding var start: Double
    @Binding var end: Double
    @Binding var still: Double
    var maxSegment: Double = CinemagraphSettings.maxSegment
    var minSegment: Double = 0.5

    private let height: CGFloat = 60
    private let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                strip(width: width)
                // Dim the parts outside the segment.
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, x(start, width)))
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, width - x(end, width)))
                    .offset(x: x(end, width))
                // The segment frame
                Rectangle()
                    .strokeBorder(LM.Palette.glow, lineWidth: 2)
                    .frame(width: max(2, x(end, width) - x(start, width)), height: height)
                    .offset(x: x(start, width))
                    .allowsHitTesting(false)
                // The frozen frame marker
                Capsule().fill(Color.white)
                    .frame(width: 3, height: height + 10)
                    .offset(x: x(still, width) - 1.5)
                    .allowsHitTesting(false)
                handle(width: width, value: $start, isStart: true)
                handle(width: width, value: $end, isStart: false)
                stillHandle(width: width)
            }
            .frame(height: height + 10)
            .coordinateSpace(name: "strip")
        }
        .frame(height: height + 10)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    @ViewBuilder
    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if images.isEmpty {
                LM.Palette.graphite
            } else {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(images.count), height: height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func handle(width: CGFloat, value: Binding<Double>, isStart: Bool) -> some View {
        let label = isStart ? "Loop start" : "Loop end"
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LM.Palette.glow)
            .frame(width: handleWidth, height: height)
            .overlay(Capsule().fill(LM.Palette.onGlow.opacity(0.6)).frame(width: 2, height: 22))
            .frame(width: 44, height: height + 10)
            .contentShape(Rectangle())
            .offset(x: x(value.wrappedValue, width) - 22)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { drag in apply(time(drag.location.x, width), isStart: isStart) }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(LMFormat.seconds(value.wrappedValue)))
            .accessibilityAdjustableAction { direction in
                apply(value.wrappedValue + (direction == .increment ? 0.1 : -0.1), isStart: isStart)
            }
    }

    private func stillHandle(width: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: x(still, width) - 22, y: 14)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { drag in still = min(max(time(drag.location.x, width), 0), duration) }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Frozen frame"))
            .accessibilityValue(Text(LMFormat.seconds(still)))
            .accessibilityAdjustableAction { direction in
                still = min(max(still + (direction == .increment ? 0.1 : -0.1), 0), duration)
            }
    }

    /// Keeps the segment between `minSegment` and `maxSegment` seconds.
    private func apply(_ t: Double, isStart: Bool) {
        if isStart {
            var next = min(max(t, 0), end - minSegment)
            next = max(next, end - maxSegment)
            start = max(0, next)
        } else {
            var next = max(min(t, duration), start + minSegment)
            next = min(next, start + maxSegment)
            end = min(duration, next)
        }
    }
}

// MARK: - Video panel

struct VideoPanel: View {
    @ObservedObject var model: EditorModel
    @StateObject private var film = FilmstripLoader()

    private var settings: CinemagraphSettings { model.project.cinemagraph }

    var body: some View {
        PanelBody {
            let duration = max(model.project.source.videoDuration, 0.5)
            PanelSection(
                title: "Loop segment",
                detail: "Choose up to \(Int(CinemagraphSettings.maxSegment)) seconds to repeat. The round marker is the frame everything outside your painted area is frozen on."
            ) {
                FilmstripTrimmer(
                    duration: duration,
                    images: film.images,
                    start: segmentBinding(\.segmentStart),
                    end: segmentBinding(\.segmentEnd),
                    still: segmentBinding(\.stillTime)
                )
                HStack {
                    Text("Start \(LMFormat.seconds(settings.segmentStart))")
                    Spacer()
                    Text("Loop \(LMFormat.seconds(settings.loopLength))")
                    Spacer()
                    Text("End \(LMFormat.seconds(settings.segmentEnd))")
                }
                .font(LM.Font.caption.monospacedDigit())
                .foregroundStyle(LM.Palette.mist)
            }
            PanelSection(title: "Seamless loop") {
                ToggleRow(
                    title: "Play forward then backward",
                    isOn: segmentBinding(\.pingPong),
                    detail: "Instead of blending the end into the start."
                )
                if !settings.pingPong {
                    ParamDial(title: "Loop smoothing", value: segmentBinding(\.loopSmoothing), range: 0...1, defaultValue: 0.4, unit: "%", scale: 100)
                }
            }
            PanelSection(title: "Live area", detail: "Paint the part that keeps moving. Everything else stays frozen.") {
                BrushControls(model: model, target: .cinemagraph, paintTitle: "Paint live area")
            }
        }
        .onAppear {
            if let url = model.assets.videoURL { film.load(url: url) }
        }
    }

    /// A binding into the cinemagraph settings that also keeps the loop length in step with the segment.
    private func segmentBinding<V: Equatable>(_ keyPath: WritableKeyPath<CinemagraphSettings, V>) -> Binding<V> {
        let key = "cinemagraph-\(keyPath)"
        return Binding(
            get: { model.project.cinemagraph[keyPath: keyPath] },
            set: { newValue in
                model.mutate(key) { project in
                    project.cinemagraph[keyPath: keyPath] = newValue
                    project.loop.duration = max(1, project.cinemagraph.loopLength)
                }
            }
        )
    }
}
