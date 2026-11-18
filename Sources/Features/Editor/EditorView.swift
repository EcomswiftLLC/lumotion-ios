import SwiftUI

/// Interim editor frame used until the engine API is connected. It shows the chosen photo in the real editor layout.
struct EditorView: View {
    let source: EditorSource

    @Environment(\.dismiss) private var dismiss
    @State private var tool: EditorTool?
    @State private var exportShown = false
    @StateObject private var exporter = ExportCoordinator()

    private var image: UIImage? {
        if case .photo(let photo) = source { return UIImage(cgImage: photo.image) }
        return nil
    }

    private var tools: [EditorTool] {
        if case .video = source { return EditorTool.allCases }
        return EditorTool.allCases.filter { $0 != .video }
    }

    var body: some View {
        EditorScaffold(
            hasPanel: tool != nil,
            topBar: { topBar },
            canvas: { canvasView },
            transport: { EmptyView() },
            panel: { panelView },
            dock: { axis in
                EditorDock(tools: tools, selected: tool, axis: axis) { picked in
                    tool = tool == picked ? nil : picked
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $exportShown) {
            ExportScreen(coordinator: exporter, previewImage: image)
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            LMIconButton(symbol: "xmark", label: "Close editor") { dismiss() }
            Spacer()
            LMIconButton(symbol: "arrow.uturn.backward", label: "Undo", disabled: true) {}
            LMIconButton(symbol: "arrow.uturn.forward", label: "Redo", disabled: true) {}
            Spacer()
            Button {
                tool = nil
                exportShown = true
            } label: {
                Text("Export")
                    .font(LM.Font.headline)
                    .foregroundStyle(LM.Palette.onGlow)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(LM.Palette.glow, in: Capsule())
            }
        }
        .padding(.horizontal, LM.Space.m)
        .frame(height: 52)
    }

    @ViewBuilder
    private var canvasView: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(LM.Space.m)
                .accessibilityLabel(Text("Your photo"))
        } else {
            Image(systemName: "film")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LM.Palette.mist)
                .accessibilityLabel(Text("Your video"))
        }
    }

    @ViewBuilder
    private var panelView: some View {
        if let tool {
            Text(tool.title)
                .font(LM.Font.title(20))
                .foregroundStyle(LM.Palette.paper)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LM.Space.m)
        } else {
            Text("Choose a tool to start.")
                .font(LM.Font.callout)
                .foregroundStyle(LM.Palette.mist)
                .padding(.horizontal, LM.Space.m)
        }
    }
}
