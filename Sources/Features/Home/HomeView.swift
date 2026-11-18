import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    /// Debug screenshots only: fills the screen with sample content (see DebugScreens).
    var debugFilled = false

    private enum PickerMode { case photo, video }

    @StateObject private var gallery = ProjectGallery()
    @State private var pickerShown = false
    @State private var pickerMode: PickerMode = .photo
    @State private var pickedItem: PhotosPickerItem?
    @State private var filesShown = false
    @State private var cameraShown = false
    @State private var settingsShown = false
    @State private var session: EditorSession?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var samples: [SampleLibrary.Sample] = []
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
        .fullScreenCover(isPresented: $cameraShown) {
            CameraPicker { photo in
                cameraShown = false
                if let photo { session = EditorSession(source: .photo(photo)) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $session, onDismiss: { Task { await gallery.reload() } }) { session in
            EditorView(source: session.source)
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
            if debugFilled { await DebugFixtures.fill(gallery) }
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
                    CKInlineBanner()
                }
                .padding(.horizontal, LM.Space.l)
                .padding(.top, LM.Space.l)
                .padding(.bottom, LM.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func stackedLayout(landscape: Bool) -> some View {
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
                samplesSection
                projectsSection
                CKInlineBanner()
            }
            .padding(.horizontal, LM.Space.m)
            .padding(.bottom, LM.Space.xl)
            .readableWidth(hSize == .regular ? 820 : 900)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Pieces

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
                pickerMode = .video
                pickerShown = true
            } label: {
                Label("New cinemagraph from video", systemImage: "film")
            }
            .buttonStyle(.apSecondaryWide)
            .disabled(loading)

            HStack(spacing: LM.Space.s) {
                if CameraPicker.isAvailable {
                    Button { cameraShown = true } label: {
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
                            SampleCard(sample: sample, debugFilled: debugFilled) { openSample(sample) }
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
        let found = await Task.detached(priority: .utility) { SampleLibrary.all() }.value
        samples = found
        if let first = found.first {
            let image = await Task.detached(priority: .utility) { Thumbnails.make(url: first.url, maxPixel: 1400) }.value
            heroImage = image
        }
        #if DEBUG
        if heroImage == nil && debugFilled { heroImage = DebugFixtures.gradient(seed: 0, size: CGSize(width: 900, height: 1000)) }
        if samples.isEmpty && debugFilled { samples = DebugFixtures.samples }
        #endif
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
            session = EditorSession(source: .photo(photo))
        case .video:
            guard let url = await MediaLoader.movie(from: item) else {
                errorMessage = "Try another video. If it is stored in iCloud, wait for it to finish downloading."
                return
            }
            session = EditorSession(source: .video(url))
        }
    }

    private func openFile(_ url: URL) async {
        loading = true
        defer { loading = false }
        guard let source = await MediaLoader.source(fromFile: url) else {
            errorMessage = "Lumotion can open photos and videos. Choose a JPEG, HEIC or PNG image, or an MP4 or MOV video."
            return
        }
        session = EditorSession(source: source)
    }

    private func openSample(_ sample: SampleLibrary.Sample) {
        loading = true
        Task {
            let photo = await Task.detached(priority: .userInitiated) { SampleLibrary.photo(sample) }.value
            loading = false
            if let photo { session = EditorSession(source: .photo(photo)) }
            else { errorMessage = "This sample could not be opened." }
        }
    }

    private func openProject(_ project: ProjectSummary) {
        Task {
            if let source = await ProjectBridge.open(project.id) {
                session = EditorSession(source: source)
            } else {
                errorMessage = "This project could not be opened. It may have been removed from this device."
            }
        }
    }
}

struct SampleCard: View {
    let sample: SampleLibrary.Sample
    var debugFilled = false
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LM.Palette.graphite
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                Text(sample.title)
                    .font(LM.Font.label)
                    .foregroundStyle(LM.Palette.paper)
                    .lineLimit(1)
                    .padding(10)
            }
            .frame(width: 132, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous).strokeBorder(LM.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sample photo, \(sample.title)"))
        .task {
            #if DEBUG
            if sample.url.scheme == "debug" {
                image = DebugFixtures.gradient(seed: Int(sample.url.host ?? "0") ?? 0, size: CGSize(width: 264, height: 336))
                return
            }
            #endif
            image = await Task.detached(priority: .utility) { Thumbnails.make(url: sample.url, maxPixel: 400) }.value
        }
    }
}
