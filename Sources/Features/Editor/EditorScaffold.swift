import SwiftUI

/// The editor's tools, in dock order.
enum EditorTool: String, CaseIterable, Identifiable, Hashable {
    case presets, flow, video, camera, depth, effects, overlays, looks, text, audio, canvas, timing, layers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presets: return "Presets"
        case .flow: return "Flow"
        case .video: return "Video"
        case .camera: return "Camera"
        case .depth: return "Depth"
        case .effects: return "Effects"
        case .overlays: return "Overlays"
        case .looks: return "Looks"
        case .text: return "Text"
        case .audio: return "Audio"
        case .canvas: return "Canvas"
        case .timing: return "Timing"
        case .layers: return "Layers"
        }
    }

    var symbol: String {
        switch self {
        case .presets: return "wand.and.stars"
        case .flow: return "wind"
        case .video: return "film"
        case .camera: return "camera.aperture"
        case .depth: return "cube.transparent"
        case .effects: return "water.waves"
        case .overlays: return "sparkles"
        case .looks: return "circle.lefthalf.filled"
        case .text: return "textformat"
        case .audio: return "music.note"
        case .canvas: return "aspectratio"
        case .timing: return "timer"
        case .layers: return "square.3.layers.3d"
        }
    }
}

/// Arranges the editor for every screen shape, so no control is ever cut off:
/// - iPad and other wide windows: preview on the left, tool panel on the right, tool dock along the bottom.
/// - iPhone in landscape: tool dock as a column on the left, preview in the middle, a scrolling panel on the right.
/// - Portrait: preview on top, a scrolling panel under it (at most 42% of the height), tool dock along the bottom.
struct EditorScaffold<TopBar: View, CanvasArea: View, Transport: View, Panel: View, Dock: View>: View {
    let hasPanel: Bool
    @ViewBuilder var topBar: () -> TopBar
    @ViewBuilder var canvas: () -> CanvasArea
    @ViewBuilder var transport: () -> Transport
    @ViewBuilder var panel: () -> Panel
    @ViewBuilder var dock: (Axis) -> Dock

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900 && geo.size.height >= 560
            let shortLandscape = !wide && geo.size.width > geo.size.height && geo.size.height < 560
            VStack(spacing: 0) {
                topBar()
                if wide {
                    HStack(spacing: 0) {
                        stage
                        Rectangle().fill(LM.Palette.line).frame(width: 1)
                        ScrollView { panel().padding(.vertical, LM.Space.m) }
                            .scrollIndicators(.hidden)
                            .frame(width: min(420, geo.size.width * 0.34))
                            .frame(maxHeight: .infinity)
                            .background(LM.Palette.carbon)
                    }
                    dock(.horizontal)
                } else if shortLandscape {
                    HStack(spacing: 0) {
                        dock(.vertical)
                        stage
                        if hasPanel {
                            ScrollView { panel().padding(.vertical, LM.Space.s) }
                                .frame(width: min(340, geo.size.width * 0.38))
                                .frame(maxHeight: .infinity)
                                .background(LM.Palette.carbon)
                        }
                    }
                } else {
                    stage
                    if hasPanel {
                        // Shrinks to its content, and scrolls once it would take more than 42% of the height.
                        ViewThatFits(in: .vertical) {
                            panel().padding(.vertical, LM.Space.s)
                            ScrollView { panel().padding(.vertical, LM.Space.s) }.scrollIndicators(.hidden)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: geo.size.height * 0.42)
                        .background(LM.Palette.carbon)
                    }
                    dock(.horizontal)
                }
            }
        }
        .apScreen()
    }

    private var stage: some View {
        VStack(spacing: 0) {
            canvas().frame(maxWidth: .infinity, maxHeight: .infinity)
            transport()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tool dock, horizontal under the preview or vertical beside it.
struct EditorDock: View {
    let tools: [EditorTool]
    let selected: EditorTool?
    let axis: Axis
    let onSelect: (EditorTool) -> Void

    var body: some View {
        Group {
            if axis == .horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { items }
                        .padding(.horizontal, LM.Space.s)
                }
                .frame(minHeight: 64)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .top) { LMHairline() }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) { items }
                        .padding(.vertical, LM.Space.xs)
                }
                .frame(width: 76)
                .overlay(alignment: .trailing) { Rectangle().fill(LM.Palette.line).frame(width: 1) }
            }
        }
        // Grows with the text size a little (up to a limit) instead of clipping the tool names.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(LM.Palette.lens)
    }

    private var items: some View {
        ForEach(tools) { tool in
            let isSelected = selected == tool
            Button {
                LMHaptics.tap()
                onSelect(tool)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: tool.symbol).font(.system(size: 19))
                    Text(tool.title)
                        .font(LM.Font.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(isSelected ? LM.Palette.glow : LM.Palette.paper.opacity(0.85))
                .frame(minWidth: 68, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tool.title))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
