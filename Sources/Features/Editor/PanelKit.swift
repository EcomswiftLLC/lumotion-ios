import SwiftUI

// Small building blocks shared by every editor panel.

/// A titled group inside a panel.
struct PanelSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LM.Space.s) {
            Text(title).font(LM.Font.label).foregroundStyle(LM.Palette.mist)
                .accessibilityAddTraits(.isHeader)
            content()
            if let detail {
                Text(detail).font(LM.Font.caption).foregroundStyle(LM.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The standard frame of a panel's content: side margins and spacing.
struct PanelBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LM.Space.m) { content() }
            .padding(.horizontal, LM.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dial for a Double. `scale` shows the stored value times `scale` (a 0...1 value shown as 0...100 with scale 100).
struct ParamDial: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var defaultValue: Double = 0
    var unit: String = ""
    var decimals: Int = 0
    var scale: Double = 1

    var body: some View {
        DialSlider(
            title: title,
            value: Binding(get: { value * scale }, set: { value = $0 / scale }),
            range: (range.lowerBound * scale)...(range.upperBound * scale),
            defaultValue: defaultValue * scale,
            unit: unit,
            decimals: decimals
        )
    }
}

/// Chips for choosing one value. Wraps onto more lines, or scrolls sideways when `scrolls` is true.
struct OptionChips<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    var scrolls = false
    let title: (T) -> String

    var body: some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LM.Space.s) { chips }
                    .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        } else {
            FlowLayout(spacing: LM.Space.s) { chips }
        }
    }

    private var chips: some View {
        ForEach(options, id: \.self) { option in
            LMChip(title: title(option), selected: selection == option) { selection = option }
        }
    }
}

/// An on/off row with a plain label.
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $isOn) {
                Text(title).font(LM.Font.body).foregroundStyle(LM.Palette.paper)
            }
            .toggleStyle(SwitchToggleStyle(tint: LM.Palette.glow))
            .frame(minHeight: 44)
            if let detail {
                Text(detail).font(LM.Font.caption).foregroundStyle(LM.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A compact text button used for panel actions (Add, Clear, Remove).
struct PanelButton: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).accessibilityHidden(true) }
                Text(title).font(LM.Font.label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? LM.Palette.onGlow : (role == .destructive ? LM.Palette.danger : LM.Palette.paper))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(prominent ? LM.Palette.glow : LM.Palette.graphite, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : LM.Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A one-line explanation or empty state inside a panel.
struct PanelNote: View {
    let text: String
    var color: Color = LM.Palette.mist
    var body: some View {
        Text(text)
            .font(LM.Font.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A layer row: a title, optional subtitle, an on/off switch, move and delete controls.
struct LayerRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String
    var selected = false
    var enabled: Binding<Bool>? = nil
    var onSelect: () -> Void
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: LM.Space.s) {
            Button(action: onSelect) {
                HStack(spacing: LM.Space.s) {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? LM.Palette.glow : LM.Palette.mist)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(LM.Font.body).foregroundStyle(LM.Palette.paper).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(LM.Font.caption).foregroundStyle(LM.Palette.mist).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let enabled {
                Toggle("Show \(title)", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: LM.Palette.glow))
            }
            if onMoveUp != nil || onMoveDown != nil {
                // Reordering and deleting share one menu so the title keeps its room in a narrow panel.
                Menu {
                    if let onMoveUp { Button { onMoveUp() } label: { Label("Move up", systemImage: "chevron.up") } }
                    if let onMoveDown { Button { onMoveDown() } label: { Label("Move down", systemImage: "chevron.down") } }
                    if let onDelete { Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(LM.Palette.paper)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("More for \(title)"))
            } else if let onDelete {
                LMIconButton(symbol: "trash", label: "Delete \(title)", tint: LM.Palette.danger, action: onDelete)
            }
        }
        .padding(.horizontal, LM.Space.s)
        .background(selected ? LM.Palette.graphite : Color.clear, in: RoundedRectangle(cornerRadius: LM.Radius.control, style: .continuous))
    }
}

extension Array {
    /// Moves the element at `index` one step towards the start (-1) or end (+1), when that is possible.
    mutating func shift(_ index: Int, by step: Int) {
        let target = index + step
        guard indices.contains(index), indices.contains(target) else { return }
        swapAt(index, target)
    }
}

extension RGBAColor {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ui = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(Double(red), Double(green), Double(blue), Double(alpha))
    }
}
