#if DEBUG
import SwiftUI
import UIKit

/// Debug builds can open a given screen directly, with generated sample content, so CI can take screenshots of every
/// screen without tapping through the app: `xcrun simctl launch <device> com.ecomswift.lumotion -lmScreen home-filled`.
/// None of this exists in Release builds.
enum DebugScreens {
    static var requested: String? {
        guard let value = UserDefaults.standard.string(forKey: "lmScreen"), !value.isEmpty else { return nil }
        return value
    }

    @MainActor @ViewBuilder
    static func view(for screen: String) -> some View {
        switch screen {
        case "onboarding":
            OnboardingView().environmentObject(AppState())
        case "home":
            HomeView()
        case "home-filled":
            HomeView(debugFilled: true)
        case "settings":
            SettingsView()
        case "editor-video":
            // A real bundled clip, so the screenshot shows the filmstrip and the loop controls with true frames.
            if let model = DebugFixtures.videoEditorModel() {
                EditorView(source: .photo(DebugFixtures.photo(seed: 0)), debugModel: model)
            } else {
                EditorView(source: .photo(DebugFixtures.photo(seed: 0)), debugModel: DebugFixtures.editorModel(tool: .video))
            }
        case let name where name.hasPrefix("editor"):
            let tool = name == "editor" ? nil : EditorTool(rawValue: String(name.dropFirst("editor-".count)))
            EditorView(source: .photo(DebugFixtures.photo(seed: 0)), debugModel: DebugFixtures.editorModel(tool: tool))
        case "export":
            DebugExportScreen()
        default:
            HomeView(debugFilled: true)
        }
    }
}

private struct DebugExportScreen: View {
    @StateObject private var coordinator: ExportCoordinator = {
        let coordinator = ExportCoordinator()
        coordinator.estimate = { choice in
            switch choice.format {
            case .gif: return "About 6.8 MB at \(choice.gif.width) px wide."
            case .still: return "About 0.9 MB."
            default: return "About 4.2 MB."
            }
        }
        return coordinator
    }()

    var body: some View {
        ExportScreen(
            coordinator: coordinator,
            previewImage: DebugFixtures.gradient(seed: 0, size: CGSize(width: 900, height: 1100)),
            hasAudio: false
        )
    }
}

/// Generated pictures and projects for development screenshots only.
enum DebugFixtures {
    private static let skies: [[UInt32]] = [
        [0x1F2A44, 0xC76B5A, 0xF3C58A],
        [0x0F2B3D, 0x2F8F9D, 0xBDE7D8],
        [0x2B1B3D, 0xD9567A, 0xFFC38B],
        [0x1E3A2B, 0x6FA66B, 0xF4E9A8],
        [0x1A1F3A, 0x5663B8, 0xE6C9F2],
        [0x2A1E1E, 0xA85B3F, 0xF0D9A8],
    ]

    static func gradient(seed: Int, size: CGSize) -> UIImage {
        let colors = skies[abs(seed) % skies.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let skyColors = colors.map { UIColor(hex: $0).cgColor } as CFArray
            let sky = CGGradient(colorsSpace: space, colors: skyColors, locations: [0, 0.62, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.75), options: [])
            let sunColors = [UIColor(hex: 0xFFF1CF).cgColor, UIColor(hex: 0xFFD18A, alpha: 0).cgColor] as CFArray
            let sun = CGGradient(colorsSpace: space, colors: sunColors, locations: [0, 1])!
            let centre = CGPoint(x: size.width * 0.62, y: size.height * 0.55)
            cg.drawRadialGradient(sun, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size.width * 0.4, options: [])
            let ridges: [(UInt32, CGFloat, CGFloat)] = [(0x5B4A6B, 0.62, 0.07), (0x3A3552, 0.72, 0.09), (0x1D2233, 0.84, 0.10), (0x0F131C, 0.94, 0.05)]
            for (hex, base, amp) in ridges {
                cg.setFillColor(UIColor(hex: hex).cgColor)
                cg.beginPath()
                cg.move(to: CGPoint(x: 0, y: size.height))
                var x: CGFloat = 0
                while x <= size.width {
                    let wave = 0.5 + 0.5 * sin(x / (size.width * 0.13) + base * 9)
                    let y = size.height * base - size.height * amp * wave
                    cg.addLine(to: CGPoint(x: x, y: y))
                    x += 6
                }
                cg.addLine(to: CGPoint(x: size.width, y: size.height))
                cg.closePath()
                cg.fillPath()
            }
        }
    }

    static func photo(seed: Int) -> PhotoSource {
        let image = gradient(seed: seed, size: CGSize(width: 1600, height: 2000))
        return PhotoSource(image: image.cgImage!, data: image.jpegData(compressionQuality: 0.9) ?? Data(), name: "Debug photo")
    }

    static var sampleRefs: [SampleRef] {
        ["golden-hour", "harbour", "dusk", "meadow", "aurora", "embers"].map { SampleRef(name: "sample_\($0)") }
    }

    /// An editor model with a finished-looking project, opened on `tool`. Uses a throwaway store so nothing is saved.
    @MainActor
    static func editorModel(tool: EditorTool?) -> EditorModel {
        let image = gradient(seed: 0, size: CGSize(width: 1500, height: 2000))
        var project = Project.new(title: "Harbour at dusk", kind: .still, fileName: "source.jpg", pixelWidth: 1500, pixelHeight: 2000)
        let strokePoints = (0...16).map { NPoint(0.12 + Double($0) * 0.046, 0.78 + 0.03 * sin(Double($0) * 0.9)) }
        var region = FlowRegion(name: "Water")
        region.strokes = [BrushStroke(points: strokePoints, radius: 0.05, feather: 0.6)]
        region.arrows = [FlowArrow(from: NPoint(0.25, 0.8), to: NPoint(0.75, 0.82))]
        region.strength = 0.6
        project.flowRegions = [region]
        project.anchors = [BrushStroke(points: [NPoint(0.5, 0.2), NPoint(0.62, 0.28)], radius: 0.05)]
        project.livingEffects = [LivingEffect(kind: .ripple, strength: 0.4), LivingEffect(kind: .shimmer, strength: 0.3)]
        project.overlays = [OverlayLayer(kind: .fireflies, intensity: 0.5), OverlayLayer(kind: .dust, intensity: 0.3)]
        project.camera.kind = .zoomIn
        project.parallax.enabled = true
        project.look.filter = .gilt
        project.look.adjust.warmth = 0.2
        var text = TextLayer(text: "Golden hour")
        text.center = NPoint(0.5, 0.84)
        project.texts = [text]
        project.stickers = [StickerLayer(emoji: "✨")]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionDebugStore", isDirectory: true)
        let model = EditorModel(project: project, assets: SourceAssets(still: image.cgImage), store: ProjectStore(rootURL: folder))
        model.isPlaying = false
        model.selectedFlow = region.id
        model.selectedEffect = project.livingEffects.first?.id
        model.selectedOverlay = project.overlays.first?.id
        model.selectedText = text.id
        model.tool = tool
        if tool == .flow {
            model.paintTool = .arrow
            model.paintTarget = .flow(region.id)
        }
        return model
    }

    /// An editor model for a cinemagraph made from the first bundled sample clip, opened on the Video tool. Nil when the app has no clips.
    @MainActor
    static func videoEditorModel() -> EditorModel? {
        let names = SampleLibrary.availableVideoNames()
        let name = names.contains("mossy-waterfall") ? "mossy-waterfall" : names.first
        guard let name, let url = SampleLibrary.videoURL(named: name), let info = VideoFrameStore.videoInfo(url) else { return nil }
        var project = Project.new(
            title: "Mossy Waterfall",
            kind: .video,
            fileName: url.lastPathComponent,
            pixelWidth: Int(info.size.width.rounded()),
            pixelHeight: Int(info.size.height.rounded()),
            videoDuration: info.duration.isFinite ? info.duration : 0
        )
        let band = (0...8).map { NPoint(0.5, 0.15 + Double($0) * 0.09) }
        project.cinemagraph.maskStrokes = [BrushStroke(points: band, radius: 0.1, feather: 0.6)]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionDebugStore", isDirectory: true)
        let model = EditorModel(project: project, assets: SourceAssets(videoURL: url), store: ProjectStore(rootURL: folder))
        model.isPlaying = false
        model.tool = .video
        return model
    }

    @MainActor
    static func fill(_ gallery: ProjectGallery) {
        let titles = ["Harbour at dusk", "Mountain stream", "Rain on glass", "Lanterns", "Golden field", "Night market"]
        let days: [Double] = [0, 1, 2, 5, 9, 20]
        let durations: [Double] = [4, 6, 3, 8, 4, 5]
        var items: [ProjectSummary] = []
        for (index, title) in titles.enumerated() {
            items.append(ProjectSummary(
                id: UUID(),
                title: title,
                modified: Date().addingTimeInterval(-days[index] * 86_400),
                duration: durations[index],
                thumbnail: gradient(seed: index, size: CGSize(width: 320, height: 400))
            ))
        }
        gallery.setItems(items)
    }
}
#endif
