import SwiftUI

/// Tool glyphs. Shape tools use custom 16-pt vector drawings with a 1.5-pt stroke so they match
/// the SF Symbols used for the remaining tools in weight and optical size.
struct ToolGlyph: View {
    let tool: Tool
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch tool {
            case .rectangle, .ellipse, .diamond, .arrow, .line, .pencil, .frame, .text:
                GlyphShape(tool: tool)
                    .stroke(style: SwiftUI.StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: size, height: size)
            default:
                Image(systemName: tool.symbol)
                    .font(.system(size: size * 0.86, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct GlyphShape: Shape {
    let tool: Tool

    func path(in r: CGRect) -> Path {
        let s = r.width / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        switch tool {
        case .rectangle:
            path.addRoundedRect(in: CGRect(origin: p(2, 3.5), size: CGSize(width: 12 * s, height: 9 * s)), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
        case .ellipse:
            path.addEllipse(in: CGRect(origin: p(1.75, 3), size: CGSize(width: 12.5 * s, height: 10 * s)))
        case .diamond:
            path.move(to: p(8, 1.75)); path.addLine(to: p(14.25, 8)); path.addLine(to: p(8, 14.25)); path.addLine(to: p(1.75, 8)); path.closeSubpath()
        case .arrow:
            path.move(to: p(2.5, 13.5)); path.addLine(to: p(13, 3))
            path.move(to: p(7.5, 3)); path.addLine(to: p(13, 3)); path.addLine(to: p(13, 8.5))
        case .line:
            path.move(to: p(4, 12)); path.addLine(to: p(12, 4))
            path.addEllipse(in: CGRect(origin: p(1.5, 11.5), size: CGSize(width: 3 * s, height: 3 * s)))
            path.addEllipse(in: CGRect(origin: p(11.5, 1.5), size: CGSize(width: 3 * s, height: 3 * s)))
        case .pencil:
            // Scrawl's squiggle.
            path.move(to: p(1.75, 11))
            path.addCurve(to: p(7, 9), control1: p(3, 4.5), control2: p(6, 4.5))
            path.addCurve(to: p(14.25, 5), control1: p(8, 13.5), control2: p(12.5, 13))
        case .frame:
            // An artboard: a title tab above a page.
            path.move(to: p(2, 2.5)); path.addLine(to: p(7, 2.5))
            path.addRoundedRect(in: CGRect(origin: p(2, 5.5), size: CGSize(width: 12 * s, height: 8.5 * s)), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
        case .text:
            path.move(to: p(3, 4)); path.addLine(to: p(3, 2.5)); path.addLine(to: p(13, 2.5)); path.addLine(to: p(13, 4))
            path.move(to: p(8, 2.5)); path.addLine(to: p(8, 13.5))
            path.move(to: p(6, 13.5)); path.addLine(to: p(10, 13.5))
        default:
            break
        }
        return path
    }
}

/// The vertical tool rail: tools grouped by purpose, with an accent indicator running along the
/// rail's inner edge next to the active tool.
struct ToolRail: View {
    @Bindable var editor: Editor
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let groups: [[Tool]] = [[.select, .hand], [.rectangle, .ellipse, .diamond], [.arrow, .line], [.pencil, .text, .image], [.frame, .eraser]]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { gi, group in
                if gi > 0 {
                    Rectangle()
                        .fill(ScrawlTheme.separator)
                        .frame(width: 18, height: 1)
                        .padding(.vertical, ScrawlTheme.Space.s)
                }
                VStack(spacing: 2) {
                    ForEach(group) { tool in
                        RailButton(tool: tool, selected: editor.tool == tool, ns: ns) {
                            editor.tool = tool
                            editor.focusCanvas?()
                        }
                    }
                }
            }
            Spacer(minLength: ScrawlTheme.Space.m)
            RailToggle(symbol: editor.toolLocked ? "pin.fill" : "pin",
                       help: editor.toolLocked ? "Keep tool active: on (Q)" : "Keep tool active (Q)",
                       isOn: editor.toolLocked) {
                editor.toolLocked.toggle()
                editor.focusCanvas?()
            }
            .padding(.bottom, ScrawlTheme.Space.m)
        }
        .padding(.top, ScrawlTheme.Space.m)
        .frame(width: ScrawlTheme.Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(ScrawlTheme.chrome)
        .overlay(alignment: .trailing) {
            Rectangle().fill(ScrawlTheme.separator).frame(width: 1)
        }
        .animation(ScrawlTheme.Motion.animation(ScrawlTheme.Motion.standard, reduceMotion: reduceMotion), value: editor.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }
}

private struct RailButton: View {
    let tool: Tool
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ToolGlyph(tool: tool)
                .foregroundStyle(selected ? ScrawlTheme.accent : ScrawlTheme.primaryText.opacity(hovering ? 0.95 : 0.72))
                .frame(width: ScrawlTheme.Metrics.railButton, height: ScrawlTheme.Metrics.railButton - 2)
                .background(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.medium, style: .continuous)
                    .fill(selected ? ScrawlTheme.accent.opacity(0.12) : (hovering ? ScrawlTheme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .frame(width: ScrawlTheme.Metrics.railWidth)
        .overlay(alignment: .trailing) {
            if selected {
                // The signature indicator along the rail's inner edge.
                Capsule()
                    .fill(ScrawlTheme.accent)
                    .frame(width: 3, height: 16)
                    .offset(x: 1.5)
                    .matchedGeometryEffect(id: "indicator", in: ns)
            }
        }
        .onHover { hovering = $0 }
        .help("\(tool.title)  \(String(tool.shortcut).uppercased())")
        .accessibilityLabel(tool.title)
        .accessibilityHint("Shortcut \(String(tool.shortcut).uppercased())")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct RailToggle: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? ScrawlTheme.accent : ScrawlTheme.tertiaryText)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.small).fill(hovering ? ScrawlTheme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("Keep tool active")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
