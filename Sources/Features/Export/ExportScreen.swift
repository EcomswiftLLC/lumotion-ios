import SwiftUI

/// Save, share or put in Files. Each button is gated by the rewarded ad (see `ExportCoordinator`).
struct ExportActionBar: View {
    @ObservedObject var coordinator: ExportCoordinator

    var body: some View {
        VStack(spacing: LM.Space.s) {
            Button {
                coordinator.perform(.photos)
            } label: {
                HStack(spacing: 8) {
                    if coordinator.isBusy { ProgressView().tint(LM.Palette.onGlow) }
                    Image(systemName: "square.and.arrow.down")
                    Text(coordinator.isBusy ? "Creating" : "Save to Photos")
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(coordinator.isBusy)

            HStack(spacing: LM.Space.s) {
                Button { coordinator.perform(.share) } label: {
                    Label("Share", systemImage: "square.and.arrow.up").lineLimit(1).minimumScaleFactor(0.8)
                }
                .buttonStyle(.apSecondaryWide)
                Button { coordinator.perform(.files) } label: {
                    Label("Save to Files", systemImage: "folder").lineLimit(1).minimumScaleFactor(0.8)
                }
                .buttonStyle(.apSecondaryWide)
            }
            .disabled(coordinator.isBusy)

            status
        }
        .sheet(isPresented: Binding(get: { coordinator.shareURL != nil }, set: { if !$0 { coordinator.shareURL = nil } })) {
            if let url = coordinator.shareURL {
                ShareSheet(urls: [url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: Binding(get: { coordinator.filesURL != nil }, set: { if !$0 { coordinator.filesURL = nil } })) {
            if let url = coordinator.filesURL {
                FilesExporter(url: url) { coordinator.filesURL = nil }
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch coordinator.phase {
        case .saved(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(LM.Font.label).foregroundStyle(LM.Palette.success)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let text):
            VStack(alignment: .leading, spacing: LM.Space.s) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(LM.Font.label).foregroundStyle(LM.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if coordinator.photosDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.apSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

/// The export screen: choose a format and size, see an estimate, then save or share.
struct ExportScreen: View {
    @ObservedObject var coordinator: ExportCoordinator
    /// A frame of the animation, shown above the options.
    let previewImage: UIImage?
    /// Whether the project has audio, which only video exports carry.
    var hasAudio = false
    /// Longest side of the project in pixels, so resolutions larger than the source are not offered.
    var sourceLongSide: Int = 4096

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let sideBySide = geo.size.width >= 760
                ScrollView {
                    Group {
                        if sideBySide {
                            HStack(alignment: .top, spacing: LM.Space.l) {
                                preview.frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: LM.Space.l) { controls }
                                    .frame(maxWidth: 440)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: LM.Space.l) {
                                preview
                                controls
                            }
                        }
                    }
                    .padding(.horizontal, LM.Space.m)
                    .padding(.bottom, LM.Space.xl)
                    .readableWidth(sideBySide ? 1000 : 640)
                }
            }
            .apScreen()
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        coordinator.cancel()
                        dismiss()
                    }
                    .foregroundStyle(LM.Palette.glow)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(coordinator.isBusy)
        .onChange(of: coordinator.choice) { _, _ in coordinator.clearStatus() }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous).strokeBorder(LM.Palette.line))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Preview of your animation"))
        }
    }

    @ViewBuilder
    private var controls: some View {
        optionsSection
        estimateLine
        progressSection
        ExportActionBar(coordinator: coordinator)
    }

    private var resolutions: [ExportResolution] {
        let supported = Exporter.supportedResolutions(codec: coordinator.choice.codec ?? .h264)
        let fitting = supported.filter { $0.longEdge <= max(1280, sourceLongSide) }
        return fitting.isEmpty ? supported : fitting
    }

    private var formats: [ExportChoice.Format] {
        ExportChoice.Format.allCases.filter { $0 != .hevc || coordinator.supportsHEVC }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: LM.Space.m) {
            VStack(alignment: .leading, spacing: LM.Space.s) {
                Text("Format").font(LM.Font.label).foregroundStyle(LM.Palette.mist)
                FlowChips {
                    ForEach(formats) { format in
                        LMChip(title: format.title, selected: coordinator.choice.format == format) {
                            coordinator.choice.format = format
                            if let codec = format.videoCodec, !Exporter.supportedResolutions(codec: codec).contains(coordinator.choice.resolution) {
                                coordinator.choice.resolution = Exporter.supportedResolutions(codec: codec).last ?? .p720
                            }
                        }
                    }
                }
                Text(coordinator.choice.format.detail)
                    .font(LM.Font.caption).foregroundStyle(LM.Palette.mist)
                if coordinator.choice.format == .gif && hasAudio {
                    Text("GIFs have no sound.").font(LM.Font.caption).foregroundStyle(LM.Palette.mist)
                }
                if (coordinator.choice.format == .h264 || coordinator.choice.format == .hevc) && hasAudio {
                    Text("Your audio is included.").font(LM.Font.caption).foregroundStyle(LM.Palette.mist)
                }
            }
            switch coordinator.choice.format {
            case .h264, .hevc:
                VStack(alignment: .leading, spacing: LM.Space.s) {
                    Text("Resolution").font(LM.Font.label).foregroundStyle(LM.Palette.mist)
                    FlowChips {
                        ForEach(resolutions) { resolution in
                            LMChip(title: resolution.title, selected: coordinator.choice.resolution == resolution) {
                                coordinator.choice.resolution = resolution
                            }
                        }
                    }
                }
            case .gif:
                VStack(spacing: LM.Space.m) {
                    DialSlider(
                        title: "Width",
                        value: Binding(
                            get: { Double(coordinator.choice.gif.width) },
                            set: { coordinator.choice.gif.width = Int(($0 / 10).rounded()) * 10 }
                        ),
                        range: 320...1080,
                        defaultValue: 480,
                        unit: " px"
                    )
                    DialSlider(
                        title: "Frame rate",
                        value: Binding(
                            get: { Double(coordinator.choice.gif.fps) },
                            set: { coordinator.choice.gif.fps = Int($0.rounded()) }
                        ),
                        range: 5...30,
                        defaultValue: 15,
                        unit: " fps"
                    )
                }
            case .still:
                VStack(alignment: .leading, spacing: LM.Space.m) {
                    Text("File type").font(LM.Font.label).foregroundStyle(LM.Palette.mist)
                    FlowChips {
                        ForEach(StillFormat.allCases) { still in
                            LMChip(title: still.chipTitle, selected: coordinator.choice.still == still) {
                                coordinator.choice.still = still
                            }
                        }
                    }
                    DialSlider(
                        title: "Moment in the loop",
                        value: Binding(
                            get: { coordinator.choice.stillPosition * 100 },
                            set: { coordinator.choice.stillPosition = $0 / 100 }
                        ),
                        range: 0...100,
                        defaultValue: 0,
                        unit: "%"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var estimateLine: some View {
        if let text = coordinator.estimate?(coordinator.choice) {
            Label(text, systemImage: "scalemass")
                .font(LM.Font.callout)
                .foregroundStyle(LM.Palette.mist)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if coordinator.isBusy {
            VStack(alignment: .leading, spacing: LM.Space.s) {
                ProgressView(value: coordinator.progress)
                    .tint(LM.Palette.glow)
                    .accessibilityLabel(Text("Export progress"))
                    .accessibilityValue(Text("\(Int(coordinator.progress * 100)) percent"))
                HStack {
                    Text("Creating your \(coordinator.choice.format == .still ? "image" : "animation")")
                        .font(LM.Font.callout).foregroundStyle(LM.Palette.mist)
                    Spacer()
                    Button("Cancel") { coordinator.cancel() }
                        .font(LM.Font.label)
                        .foregroundStyle(LM.Palette.glow)
                        .frame(minHeight: 44)
                }
            }
        }
    }
}

/// Chips that wrap onto further lines instead of scrolling sideways.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: LM.Space.s) { content() }
    }
}

/// A simple wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
