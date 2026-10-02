import SwiftUI

/// Center toolbar item: the active tool, its shortcut, and a menu to switch tools.
struct ToolbarToolIndicator: View {
    @Bindable var editor: Editor

    var body: some View {
        Menu {
            ForEach(ToolRail.groups.indices, id: \.self) { gi in
                if gi > 0 { Divider() }
                ForEach(ToolRail.groups[gi]) { tool in
                    Button {
                        editor.tool = tool
                        editor.focusCanvas?()
                    } label: {
                        Text("\(tool.title)    \(String(tool.shortcut).uppercased())")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                ToolGlyph(tool: editor.tool, size: 13)
                    .foregroundStyle(ScrawlTheme.accent)
                Text(editor.tool.title)
                    .font(.system(size: 12, weight: .medium))
                Text(String(editor.tool.shortcut).uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ScrawlTheme.tertiaryText)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(ScrawlTheme.border))
                if editor.toolLocked {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(ScrawlTheme.accent)
                }
            }
            .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Current tool: \(editor.tool.title)")
    }
}

/// Optional toolbar item: Precision / Ink / Soft for the selection or new objects.
struct ToolbarStyleIndicator: View {
    @Bindable var editor: Editor

    var body: some View {
        ScrawlSegmented(options: RenderStyle.allCases.map { SegmentOption(value: $0, label: .text($0.title), help: $0.subtitle) },
                        selection: editor.summary.style.renderStyle) { editor.setRenderStyle($0) }
            .frame(width: 210)
    }
}
