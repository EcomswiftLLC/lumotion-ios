#if DEBUG
import SwiftUI
import UIKit

/// Store captures: the real Home, editor and export screens opened on the bundled sample photos and clips, in a project
/// state that looks like finished work. `-lmScreen shot-<name>` opens one. Nothing here draws UI of its own: every capture
/// is the real view, and every picture is a frame rendered by the real engine. DEBUG builds only.
///
/// Photos are never portraits of people (no model release): waterfall, mountain valley, ocean, lake, city, forest,
/// meadow and snow scenes only.
enum StoreScreens {
    /// Names of the store captures, in slide order. CI saves each one under exactly this name.
    static let names = [
        "home-filled", "editor-flow", "editor-video", "editor-depth", "editor-camera",
        "editor-effects", "editor-overlays", "editor-presets", "editor-looks", "export",
    ]

    /// A moment inside the loop where motion is visible (rain streaks, ripples, drifting light).
    static let midLoop = 1.2

    @MainActor @ViewBuilder
    static func view(for name: String) -> some View {
        switch name {
        case "home-filled":
            HomeView(debugFilled: true, debugStore: true)
        case "export":
            StoreExportScreen()
        default:
            if let model = editorModel(for: name) {
                EditorView(source: .photo(DebugFixtures.photo(seed: 0)), debugModel: model)
            } else {
                // Samples missing from the bundle: show the generated editor so the run still produces a picture.
                // (Not DebugScreens.view: the two opaque return types would depend on each other.)
                let tool = EditorTool(rawValue: String(name.dropFirst("editor-".count)))
                EditorView(source: .photo(DebugFixtures.photo(seed: 0)), debugModel: DebugFixtures.editorModel(tool: tool))
            }
        }
    }

    // MARK: Editor scenes

    @MainActor
    static func editorModel(for name: String) -> EditorModel? {
        switch name {
        case "editor-flow":
            // The painted water and its arrows are on the canvas, with the Flow panel open.
            return scene(photo: "waterfall", title: "Forest Waterfall", preset: "waterfall", tool: .flow, time: 0, after: { model in
                model.paintTool = .paint
                if let region = model.project.flowRegions.first { model.paintTarget = .flow(region.id) }
            })
        case "editor-video":
            return videoScene(clip: "mossy-waterfall", title: "Mossy Waterfall")
        case "editor-depth":
            return scene(photo: "mountain-valley", title: "Mountain Valley", preset: "cinematic-push-in", tool: .depth, edit: { project in
                project.parallax = ParallaxSettings(enabled: true, depthSource: .gradient, style: .orbit, strength: 0.6, edgeFill: .blur, invertDepth: false)
                project.overlays = [OverlayLayer(kind: .fog, intensity: 0.35, speed: 0.6)]
            })
        case "editor-camera":
            return scene(photo: "ocean-waves", title: "Ocean Waves", preset: "ocean-waves", tool: .camera, edit: { project in
                project.camera = CameraMotion(kind: .zoomIn, amount: 0.45, easing: .easeInOut, loops: true)
            })
        case "editor-effects":
            return scene(photo: "sunset-lake", title: "Sunset Lake", preset: "ocean-waves", tool: .effects, edit: { project in
                let lower = GradientMask(start: NPoint(0.5, 0.25), end: NPoint(0.5, 0.95), softness: 0.6, invert: false)
                project.livingEffects = [
                    LivingEffect(kind: .ripple, strength: 0.6, speed: 1, scale: 1, angle: 0, gradient: lower),
                    LivingEffect(kind: .shimmer, strength: 0.3, speed: 1, scale: 1, angle: 0, gradient: lower),
                ]
                project.camera = CameraMotion()
            })
        case "editor-overlays":
            return scene(photo: "city-rain-night", title: "Rainy Night", preset: "neon-rain", tool: .overlays, edit: { project in
                project.livingEffects = []
                project.camera = CameraMotion()
            })
        case "editor-presets":
            return scene(photo: "forest-mist", title: "Misty Forest", preset: "golden-hour-dust", tool: .presets)
        case "editor-looks":
            return scene(photo: "flowers-field", title: "Wildflower Meadow", preset: "wind-in-hair", tool: .looks, edit: { project in
                project.look = Look(filter: .gilt, intensity: 75, adjust: LookAdjust(warmth: 0.15))
            })
        default:
            return nil
        }
    }

    private static var storeFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumotionStoreShots", isDirectory: true)
    }

    /// A project made from one bundled photo, with a preset applied and then adjusted, opened on `tool`.
    @MainActor
    static func scene(
        photo: String,
        title: String,
        preset: String?,
        tool: EditorTool,
        time: Double = midLoop,
        edit: (inout Project) -> Void = { _ in },
        after: (EditorModel) -> Void = { _ in }
    ) -> EditorModel? {
        guard let image = SampleLibrary.image(named: photo, maxPixel: 2400) else { return nil }
        var project = Project.new(title: title, kind: .still, fileName: "source.jpg", pixelWidth: image.width, pixelHeight: image.height)
        if let preset { project = PresetLibrary.apply(preset, to: project) }
        edit(&project)
        let model = EditorModel(project: project, assets: SourceAssets(still: image), store: ProjectStore(rootURL: storeFolder))
        model.isPlaying = false
        model.time = time
        model.selectedFlow = project.flowRegions.first?.id
        model.selectedEffect = project.livingEffects.first?.id
        model.selectedOverlay = project.overlays.first?.id
        model.tool = tool
        after(model)
        return model
    }

    /// A cinemagraph from a bundled clip, with the moving part painted on the water and the Video panel open.
    @MainActor
    static func videoScene(clip: String, title: String) -> EditorModel? {
        guard let url = SampleLibrary.videoURL(named: clip), let info = VideoFrameStore.videoInfo(url) else { return nil }
        var project = Project.new(
            title: title,
            kind: .video,
            fileName: url.lastPathComponent,
            pixelWidth: Int(info.size.width.rounded()),
            pixelHeight: Int(info.size.height.rounded()),
            videoDuration: info.duration.isFinite ? info.duration : 0
        )
        let water = [NPoint(0.55, 0.10), NPoint(0.52, 0.30), NPoint(0.50, 0.50), NPoint(0.50, 0.70), NPoint(0.50, 0.90)]
        project.cinemagraph.maskStrokes = [BrushStroke(points: water, radius: 0.11, feather: 0.6)]
        let model = EditorModel(project: project, assets: SourceAssets(videoURL: url), store: ProjectStore(rootURL: storeFolder))
        model.isPlaying = false
        model.tool = .video
        model.paintTool = .paint
        model.paintTarget = .cinemagraph
        return model
    }

    // MARK: Home

    /// Four projects whose thumbnails are real frames rendered by the engine from bundled photos.
    static func fill(_ gallery: ProjectGallery) async {
        let specs: [(photo: String, title: String, preset: String, days: Double)] = [
            ("waterfall", "Forest Waterfall", "waterfall", 0),
            ("ocean-waves", "Ocean Waves", "ocean-waves", 1),
            ("sunset-lake", "Sunset Lake", "ocean-waves", 3),
            ("city-rain-night", "Rainy Night", "neon-rain", 8),
        ]
        let items = await Task.detached(priority: .userInitiated) { () -> [ProjectSummary] in
            specs.compactMap { spec in
                guard let image = SampleLibrary.image(named: spec.photo, maxPixel: 1600) else { return nil }
                var project = Project.new(title: spec.title, kind: .still, fileName: "source.jpg", pixelWidth: image.width, pixelHeight: image.height)
                project = PresetLibrary.apply(spec.preset, to: project)
                let engine = RenderEngine(project: project, assets: SourceAssets(still: image))
                let frame = engine.renderFrame(time: 1.2, quality: RenderQuality(longEdge: 480)).map { UIImage(cgImage: $0) }
                return ProjectSummary(
                    id: UUID(),
                    title: spec.title,
                    modified: Date().addingTimeInterval(-spec.days * 86_400),
                    duration: project.loop.clampedDuration,
                    thumbnail: frame
                )
            }
        }.value
        await gallery.setItems(items)
    }
}

/// The real export screen, opened on a real frame of a bundled photo with the engine's own size estimate.
private struct StoreExportScreen: View {
    @StateObject private var holder = Holder()

    @MainActor
    final class Holder: ObservableObject {
        let coordinator = ExportCoordinator()
        let model: EditorModel?
        let preview: UIImage?

        init() {
            let model = StoreScreens.scene(photo: "snowy-trees", title: "Snowy Pines", preset: "snow-globe", tool: .presets)
            self.model = model
            if let model {
                preview = model.engine.renderFrame(time: 1.2, quality: RenderQuality(longEdge: 1400)).map { UIImage(cgImage: $0) }
                coordinator.estimate = { [weak model] choice in model?.exportEstimate(for: choice) }
                coordinator.resolutions = { [weak model] codec in model?.availableResolutions(codec: codec) ?? [.p720] }
                coordinator.warning = { [weak model] choice in model?.exportWarning(for: choice) }
                coordinator.sourceLongSide = max(model.project.source.pixelWidth, model.project.source.pixelHeight)
            } else {
                preview = DebugFixtures.gradient(seed: 0, size: CGSize(width: 900, height: 1100))
            }
        }
    }

    var body: some View {
        ExportScreen(
            coordinator: holder.coordinator,
            previewImage: holder.preview,
            hasAudio: false,
            sourceLongSide: holder.coordinator.sourceLongSide
        )
    }
}
#endif
