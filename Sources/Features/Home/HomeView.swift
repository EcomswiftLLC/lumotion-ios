import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    /// Debug screenshots only: fills the screen with sample content (see DebugScreens).
    var debugFilled = false
    /// Debug store captures only: the projects are renders of real sample photos, and the page is scrolled to the samples.
    var debugStore = false

    private enum PickerMode { case photo, video }

    /// What the one full-screen cover shows. The camera and the editor share it, so one never gets dropped for the other.
    private enum Cover: Identifiable {
        case camera
        case editor(EditorSession)

        var id: String {
            switch self {
            case .camera: return "camera"
            case .editor(let session): return session.id.uuidString
            }
        }
    }

    @StateObject private var gallery = ProjectGallery()
    @State private var pickerShown = false
    @State private var pickerMode: PickerMode = .photo
    @State private var pickedItem: PhotosPickerItem?
    @State private var filesShown = false
    @State private var settingsShown = false
    @State private var clipSheetShown = false
    @State private var afterClipSheet: (() -> Void)?
    @State private var cover: Cover?
    /// An editor to open as soon as the camera has finished closing.
    @State private var pendingSession: EditorSession?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var samples: [SampleRef] = []
    @State private var clips: [VideoSampleRef] = []
    @State private var heroImage: UIImage?
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""
    @State private var deleting: ProjectSummary?
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= 900 && geo.size.height >= 560
            let landscape = geo.size.width > geo.size.height
            Group {
                if split {
                    splitLayout(width: geo.size.width)
                } else {
                    stackedLayout(landscape: landscape)
                }
            }
        }
        .apScreen()
        .photosPicker(
            isPresented: $pickerShown,
            selection: $pickedItem,
            matching: pickerMode == .photo ? .images : .videos
        )
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            let mode = pickerMode
            Task { await open(item, mode: mode) }
        }
        .fileImporter(isPresented: $filesShown, allowedContentTypes: [.image, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task { await openFile(url) }
        }
        .fullScreenCover(item: $cover, onDismiss: coverDismissed) { item in
            switch item {
            case .camera:
                CameraPicker { photo in
                    if let photo { pendingSession = EditorSession(source: .photo(photo)) }
                    cover = nil
                }
                .ignoresSafeArea()
            case .editor(let session):
                EditorView(source: session.source)
            }
        }
        .sheet(isPresented: $clipSheetShown, onDismiss: {
            let next = afterClipSheet
            afterClipSheet = nil
            next?()
        }) {
            ClipStartSheet(
                clips: clips,
                onChoosePhotos: {
                    afterClipSheet = { pickerMode = .video; pickerShown = true }
                    clipSheetShown = false
                },
                onChooseClip: { clip in
                    afterClipSheet = { openClip(clip) }
                    clipSheetShown = false
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $settingsShown) { SettingsView() }
        .alert("Could not open it", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let project = renaming { Task { await gallery.rename(project.id, to: renameText) } }
            }
        }
        .confirmationDialog(
            "Delete this project?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                if let project = deleting { Task { await gallery.delete(project.id) } }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The project and its edits are removed from this device. Exported files you saved are not affected.")
        }
        .task {
            await ProjectBridge.attach(to: gallery)
            #if DEBUG
            if debugFilled && debugStore { await StoreScreens.fill(gallery) }
            else if debugFilled { await DebugFixtures.fill(gallery) }
            #endif
            if !debugFilled { await gallery.reload() }
            await loadSamples()
        }
    }

    // MARK: Layouts

    /// iPad landscape and other wide windows: the welcome and actions stay on the left, the work on the right.
    private func splitLayout(width: CGFloat) -> some View {
        let left = min(460, max(380, width * 0.38))
        return HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LM.Space.l) {
                    topBar
                    HeroLoopView(image: heroImage)
                        .aspectRatio(4.0 / 4.6, contentMode: .fit)
                    headline
                    actions
                }
                .padding(.horizontal, LM.Space.l)
                .padding(.bottom, LM.Space.xl)
            }
            .scrollIndicators(.hidden)
            .frame(width: left)
            Rectangle().fill(LM.Palette.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: LM.Space.xl) {
                    samplesSection
                    projectsSection
                    banner
                }
                .padding(.horizontal, LM.Space.l)
                .padding(.top, LM.Space.l)
                .padding(.bottom, LM.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func stackedLayout(landscape: Bool) -> some View {
        ScrollViewReader { proxy in
            stackedContent(landscape: landscape)
                .task {
                    #if DEBUG
                    // Store captures show the samples and projects, as if the person had scrolled down to them.
                    if debugStore {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(nil) { proxy.scrollTo("home-samples", anchor: .top) }
                    }
                    #endif
                }
        }
    }

    private func stackedContent(landscape: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LM.Space.xl) {
                topBar
                if landscape {
                    HStack(alignment: .center, spacing: LM.Space.l) {
                        HeroLoopView(image: heroImage)
                            .frame(maxWidth: .infinity)
                            .frame(height: 240)
                        VStack(alignment: .leading, spacing: LM.Space.m) {
                            headline
                            actions
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HeroLoopView(image: heroImage)
                        .frame(height: hSize == .regular ? 360 : 280)
                    VStack(alignment: .leading, spacing: LM.Space.m) {
                        headline
                        actions
                    }
                }
                VStack(alignment: .leading, spacing: LM.Space.xl) { samplesSection }
                    .padding(.top, LM.Space.s)
                    .id("home-samples")
                projectsSection
                banner
            }
            .padding(.horizontal, LM.Space.m)
            .padding(.bottom, LM.Space.xl)
            .readableWidth(hSize == .regular ? 820 : 900)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Pieces

    /// The Home banner ad. Left out until there is a project, so a first visit shows only Lumotion.
    @ViewBuilder
    private var banner: some View {
        if !gallery.items.isEmpty { CKInlineBanner() }
    }

    private func coverDismissed() {
        if let next = pendingSession {
            pendingSession = nil
            // Presenting in the same moment the camera closes can be dropped, so wait one turn.
            DispatchQueue.main.async { cover = .editor(next) }
        } else {
            Task { await gallery.reload() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            ApertureMark(lineWidth: 1.5)
                .frame(width: 26, height: 26)
            Text("Lumotion")
                .font(LM.Font.title(21))
                .foregroundStyle(LM.Palette.paper)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { settingsShown = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(LM.Palette.paper)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.top, LM.Space.s)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: LM.Space.s) {
            Text("Make a still photo move.")
                .apDisplay(38)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Paint the flow, add depth, rain or sparkles, then export a seamless loop. Everything stays on your device.")
                .font(LM.Font.body)
                .foregroundStyle(LM.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: LM.Space.s) {
            Button {
                pickerMode = .photo
                pickerShown = true
            } label: {
                HStack(spacing: 10) {
                    if loading { ProgressView().tint(LM.Palette.onGlow) }
                    Image(systemName: "photo.badge.plus").accessibilityHidden(true)
                    Text(loading ? "Opening" : "New from photo")
                }
            }
            .accessibilityLabel(Text(loading ? "Opening" : "New from photo"))
            .buttonStyle(.apPrimaryWide)
            .disabled(loading)

            Button {
                if clips.isEmpty {
                    pickerMode = .video
                    pickerShown = true
                } else {
                    clipSheetShown = true
                }
            } label: {
                Label("New cinemagraph from video", systemImage: "film")
            }
            .buttonStyle(.apSecondaryWide)
            .disabled(loading)

            HStack(spacing: LM.Space.s) {
                if CameraPicker.isAvailable {
                    Button { cover = .camera } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .buttonStyle(.apSecondaryWide)
                }
                Button { filesShown = true } label: {
                    Label("Files", systemImage: "folder")
                }
                .buttonStyle(.apSecondaryWide)
            }
            .disabled(loading)
        }
    }

    @ViewBuilder
    private var samplesSection: some View {
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: LM.Space.s) {
                LMSectionTitle(text: "Try a sample")
                Text("Start from one of ours to see what Lumotion does.")
                    .font(LM.Font.callout)
                    .foregroundStyle(LM.Palette.mist)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LM.Space.s) {
                        ForEach(samples) { sample in
                            SampleCard(
                                title: sample.title,
                                label: "Sample photo, \(sample.title)",
                                load: { Samples.image(sample, maxPixel: 400).map { UIImage(cgImage: $0) } }
                            ) { openSample(sample) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: LM.Space.s) {
                LMSectionTitle(text: "Try a sample clip")
                Text("A short video where you choose what keeps moving.")
                    .font(LM.Font.callout)
                    .foregroundStyle(LM.Palette.mist)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LM.Space.s) {
                        ForEach(clips) { clip in
                            SampleCard(
                                title: clip.title,
                                label: "Sample clip, \(clip.title). \(clip.blurb)",
                                isVideo: true,
                                load: { SampleCatalog.thumbnail(for: clip) }
                            ) { openClip(clip) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: LM.Space.s) {
            LMSectionTitle(text: "Your projects")
            if gallery.items.isEmpty {
                VStack(spacing: LM.Space.s) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(LM.Palette.glow)
                        .accessibilityHidden(true)
                    Text("Nothing here yet").font(LM.Font.headline).foregroundStyle(LM.Palette.paper)
                    Text("Choose a photo to begin. Your work is saved as you go and appears here.")
                        .font(LM.Font.callout)
                        .foregroundStyle(LM.Palette.mist)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LM.Space.xl)
                .padding(.horizontal, LM.Space.m)
                .overlay(
                    RoundedRectangle(cornerRadius: LM.Radius.panel, style: .continuous)
                        .strokeBorder(LM.Palette.paper.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: hSize == .regular ? 190 : 150), spacing: LM.Space.m)],
                    alignment: .leading,
                    spacing: LM.Space.l
                ) {
                    ForEach(gallery.items) { project in
                        Button { openProject(project) } label: { ProjectCard(project: project) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { renameText = project.title; renaming = project } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button { Task { await gallery.duplicate(project.id) } } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                Button(role: .destructive) { deleting = project } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .accessibilityAction(named: Text("Rename")) { renameText = project.title; renaming = project }
                            .accessibilityAction(named: Text("Duplicate")) { Task { await gallery.duplicate(project.id) } }
                            .accessibilityAction(named: Text("Delete")) { deleting = project }
                    }
                }
            }
        }
    }

    // MARK: Opening things

    private func loadSamples() async {
        let found = await Task.detached(priority: .utility) { Samples.refs() }.value
        samples = found
        clips = await Task.detached(priority: .utility) { SampleCatalog.videos() }.value
        if let first = found.first {
            let image = await Task.detached(priority: .utility) { Samples.image(first, maxPixel: 1400).map { UIImage(cgImage: $0) } }.value
            heroImage = image
        }
    }

    private func open(_ item: PhotosPickerItem, mode: PickerMode) async {
        loading = true
        defer {
            loading = false
            pickedItem = nil
        }
        switch mode {
        case .photo:
            guard let photo = await MediaLoader.photo(from: item) else {
                errorMessage = "Try another photo. If it is stored in iCloud, wait for it to finish downloading."
                return
            }
            cover = .editor(EditorSession(source: .photo(photo)))
        case .video:
            guard let url = await MediaLoader.movie(from: item) else {
                errorMessage = "Try another video. If it is stored in iCloud, wait for it to finish downloading."
                return
            }
            cover = .editor(EditorSession(source: .video(url)))
        }
    }

    private func openFile(_ url: URL) async {
        loading = true
        defer { loading = false }
        guard let source = await MediaLoader.source(fromFile: url) else {
            errorMessage = "Lumotion can open photos and videos. Choose a JPEG, HEIC or PNG image, or an MP4 or MOV video."
            return
        }
        cover = .editor(EditorSession(source: source))
    }

    private func openSample(_ sample: SampleRef) {
        loading = true
        Task {
            let photo = await Task.detached(priority: .userInitiated) { Samples.photo(sample) }.value
            loading = false
            if let photo { cover = .editor(EditorSession(source: .photo(photo))) }
            else { errorMessage = "This sample could not be opened." }
        }
    }

    /// Opens a bundled sample clip as a new cinemagraph (the project store copies it, so the bundle is never changed).
    private func openClip(_ clip: VideoSampleRef) {
        guard let url = SampleLibrary.videoURL(named: clip.name) else {
            errorMessage = "This sample clip could not be opened."
            return
        }
        cover = .editor(EditorSession(source: .video(url)))
    }

    private func openProject(_ project: ProjectSummary) {
        Task {
            if let source = await ProjectBridge.open(project.id) {
                cover = .editor(EditorSession(source: source))
            } else {
                errorMessage = "This project could not be opened. It may have been removed from this device."
            }
        }
    }
}

/// A tile for a bundled sample photo or clip. `load` makes the picture off the main thread.
struct SampleCard: View {
    let title: String
    let label: String
    var isVideo = false
    let load: @Sendable () -> UIImage?
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LM.Palette.graphite
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 132, height: 168)
                        .clipped()
                }
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                Text(title)
                    .font(LM.Font.label)
                    .foregroundStyle(LM.Palette.paper)
                    .lineLimit(1)
                    .padding(10)
            }
            .frame(width: 132, height: 168)
            .overlay(alignment: .topTrailing) {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LM.Palette.paper)
                        .frame(width: 26, height: 26)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous).strokeBorder(LM.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .task {
            let make = load
            image = await Task.detached(priority: .utility) { make() }.value
        }
    }
}

/// Start sheet for a cinemagraph: pick a video from Photos, or begin with one of the bundled sample clips.
struct ClipStartSheet: View {
    let clips: [VideoSampleRef]
    let onChoosePhotos: () -> Void
    let onChooseClip: (VideoSampleRef) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LM.Space.l) {
                    LMHeader(title: "New cinemagraph", subtitle: "Keep one part of a video moving while the rest holds still.")
                    Button(action: onChoosePhotos) {
                        Label("Choose a video from Photos", systemImage: "film")
                    }
                    .buttonStyle(.apPrimaryWide)
                    if !clips.isEmpty {
                        VStack(alignment: .leading, spacing: LM.Space.s) {
                            LMSectionTitle(text: "Or try a sample clip")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: LM.Space.m)], alignment: .leading, spacing: LM.Space.m) {
                                ForEach(clips) { clip in
                                    SampleCard(
                                        title: clip.title,
                                        label: "Sample clip, \(clip.title). \(clip.blurb)",
                                        isVideo: true,
                                        load: { SampleCatalog.thumbnail(for: clip) }
                                    ) { onChooseClip(clip) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LM.Space.m)
                .padding(.bottom, LM.Space.xl)
                .readableWidth()
            }
            .apScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(LM.Palette.glow)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
