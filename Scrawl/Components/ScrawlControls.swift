import AppKit
import SwiftUI

// MARK: - Surfaces

/// Raised surface for popovers, the command palette and transient chips.
struct ElevatedSurface: ViewModifier {
    var radius: CGFloat = ScrawlTheme.Radius.panel
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(ScrawlTheme.elevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(contrast == .increased ? ScrawlTheme.primaryText.opacity(0.4) : ScrawlTheme.border, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

extension View {
    func elevatedSurface(radius: CGFloat = ScrawlTheme.Radius.panel) -> some View { modifier(ElevatedSurface(radius: radius)) }
}

/// Subtle scale-down feedback on press.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Mini icon button

/// Compact icon button for inspector rows and the status strip.
struct MiniIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var width: CGFloat = 24
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isOn ? ScrawlTheme.accent : ScrawlTheme.primaryText.opacity(isEnabled ? 0.8 : 0.3))
                .frame(width: width, height: 22)
                .background(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.small, style: .continuous)
                    .fill(isOn ? ScrawlTheme.accent.opacity(0.14) : (hovering && isEnabled ? ScrawlTheme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Segmented control (Scrawl signature)

enum SegmentLabel: Hashable {
    case icon(String)
    case text(String)
}

struct SegmentOption<Value: Hashable>: Hashable {
    let value: Value
    let label: SegmentLabel
    let help: String
}

/// Compact segmented control with a raised thumb that slides between segments.
struct ScrawlSegmented<Value: Hashable>: View {
    let options: [SegmentOption<Value>]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { o in
                Button { onSelect(o.value) } label: {
                    label(o.label, selected: o.value == selection)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background {
                            if o.value == selection {
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(ScrawlTheme.elevated)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.help)
                .accessibilityLabel(o.help)
                .accessibilityAddTraits(o.value == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ScrawlTheme.field, in: RoundedRectangle(cornerRadius: ScrawlTheme.Radius.medium, style: .continuous))
        .animation(ScrawlTheme.Motion.animation(ScrawlTheme.Motion.quick, reduceMotion: reduceMotion), value: selection)
    }

    @ViewBuilder
    private func label(_ l: SegmentLabel, selected: Bool) -> some View {
        switch l {
        case let .icon(name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? ScrawlTheme.primaryText : ScrawlTheme.secondaryText)
        case let .text(t):
            Text(t)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ScrawlTheme.primaryText : ScrawlTheme.secondaryText)
                .lineLimit(1)
        }
    }
}

// MARK: - Numeric field

/// Small numeric field. Dragging the label scrubs the value; Return or focus loss commits.
struct NumberField: View {
    let label: String
    let value: Double?
    var unit: String = ""
    var step: Double = 1
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var digits: Int = 0
    let onCommit: (Double) -> Void
    var onScrubBegan: (() -> Void)? = nil
    var onScrubEnded: (() -> Void)? = nil

    @State private var text = ""
    @State private var scrubStart: Double?
    @FocusState private var focused: Bool

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never))
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(ScrawlTheme.Font.small.weight(.medium))
                .foregroundStyle(ScrawlTheme.tertiaryText)
                .frame(minWidth: 10)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        guard let base = scrubStart ?? value else { return }
                        if scrubStart == nil { scrubStart = base; onScrubBegan?() }
                        let v = min(range.upperBound, max(range.lowerBound, (base + Double(g.translation.width) * step).rounded(toPlaces: digits)))
                        text = format(v)
                        onCommit(v)
                    }
                    .onEnded { _ in
                        scrubStart = nil
                        onScrubEnded?()
                    })
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(ScrawlTheme.Font.value)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
            if !unit.isEmpty {
                Text(unit).font(ScrawlTheme.Font.small).foregroundStyle(ScrawlTheme.tertiaryText)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: ScrawlTheme.Metrics.fieldHeight)
        .background(ScrawlTheme.field, in: RoundedRectangle(cornerRadius: ScrawlTheme.Radius.small + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.small + 1, style: .continuous)
            .strokeBorder(focused ? ScrawlTheme.accent.opacity(0.7) : .clear, lineWidth: 1))
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !focused { text = format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(format(value) + unit)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: unit, with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else { text = format(value); return }
        let clamped = min(range.upperBound, max(range.lowerBound, v))
        if clamped != value { onCommit(clamped) }
        text = format(clamped)
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}

// MARK: - Inspector layout

/// A collapsible inspector group with a quiet header.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @AppStorage private var collapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _collapsed = AppStorage(wrappedValue: false, "inspector.collapsed.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScrawlTheme.Space.s) {
            Button {
                withAnimation(ScrawlTheme.Motion.animation(reduceMotion: reduceMotion)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(ScrawlTheme.Font.sectionTitle)
                        .foregroundStyle(ScrawlTheme.secondaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(ScrawlTheme.tertiaryText)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            if !collapsed {
                VStack(alignment: .leading, spacing: ScrawlTheme.Space.s) { content }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, ScrawlTheme.Space.l)
        .padding(.vertical, ScrawlTheme.Space.m + 1)
    }
}

/// Label + controls, aligned on a shared label column.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: ScrawlTheme.Space.m) {
            Text(label)
                .font(ScrawlTheme.Font.label)
                .foregroundStyle(ScrawlTheme.secondaryText)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
            content
        }
        .frame(minHeight: ScrawlTheme.Metrics.rowHeight)
    }
}

// MARK: - Color

/// One swatch: a rounded square with a selection ring (so state never relies on color alone).
struct SwatchChip: View {
    let color: DrawingColor
    let selected: Bool
    let dark: Bool
    var size: CGFloat = 16
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if color.isClear {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ScrawlTheme.field)
                    Path { p in p.move(to: CGPoint(x: 3, y: size - 3)); p.addLine(to: CGPoint(x: size - 3, y: 3)) }
                        .stroke(Color(nsColor: .systemRed).opacity(0.75), lineWidth: 1.2)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: color.nsColor(dark: dark)))
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(ScrawlTheme.border, lineWidth: 0.75)
            }
            .frame(width: size, height: size)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? ScrawlTheme.accent : (hovering ? ScrawlTheme.border : .clear), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(Palette.name(for: color))
        .accessibilityLabel("\(Palette.name(for: color)) color")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bridges NSColorPanel's target/action into a closure.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var handler: ((NSColor) -> Void)?

    func open(with color: NSColor, showsAlpha: Bool, onChange: @escaping (NSColor) -> Void) {
        handler = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = showsAlpha
        panel.isContinuous = true
        panel.setTarget(nil)
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        handler?(sender.color)
    }
}

/// Compact color picker row: a few quick swatches, a palette popover, and the system color panel.
struct ColorRow: View {
    let current: DrawingColor
    let allowsNone: Bool
    let quick: [DrawingColor]
    let palette: [DrawingColor]
    let dark: Bool
    let onPick: (DrawingColor) -> Void
    let onCustom: (DrawingColor) -> Void
    @State private var showPalette = false

    var body: some View {
        HStack(spacing: 2) {
            if allowsNone {
                SwatchChip(color: .clear, selected: current.isClear, dark: dark) { onPick(.clear) }
            }
            ForEach(quick.prefix(allowsNone ? 4 : 5), id: \.self) { c in
                SwatchChip(color: c, selected: c == current, dark: dark) { onPick(c) }
            }
            Spacer(minLength: 2)
            MiniIconButton(symbol: "square.grid.3x3.fill", help: "Palette", width: 22) { showPalette.toggle() }
                .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                    PalettePopover(colors: palette, current: current, dark: dark) { c in
                        onPick(c)
                        showPalette = false
                    }
                }
            MiniIconButton(symbol: "eyedropper.halffull", help: "Custom color…", width: 22) {
                ColorPanelBridge.shared.open(with: current.nsColor(dark: dark), showsAlpha: true) { ns in
                    onCustom(DrawingColor(nsColor: ns))
                }
            }
        }
    }
}

private struct PalettePopover: View {
    let colors: [DrawingColor]
    let current: DrawingColor
    let dark: Bool
    let onPick: (DrawingColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette").font(ScrawlTheme.Font.sectionTitle).foregroundStyle(ScrawlTheme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 5), spacing: 4) {
                ForEach(colors, id: \.self) { c in
                    SwatchChip(color: c, selected: c == current, dark: dark) { onPick(c) }
                }
            }
        }
        .padding(12)
    }
}
