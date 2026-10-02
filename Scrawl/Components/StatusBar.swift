import SwiftUI

/// Quiet workspace strip under the canvas: canvas aids on the left, selection in the middle,
/// navigation on the right.
struct StatusBar: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: ScrawlTheme.Space.xs) {
            StatusToggle(title: "Grid", symbol: editor.gridStyle == .lines ? "grid" : "circle.grid.3x3",
                         isOn: editor.gridStyle != .none, help: "Grid (⌘')") {
                editor.gridStyle = editor.gridStyle == .none ? (Preferences.shared.defaultGrid == .none ? .dots : Preferences.shared.defaultGrid) : .none
            } menu: {
                Picker("Grid", selection: $editor.gridStyle) {
                    ForEach(GridStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Menu("Spacing") {
                    ForEach([10.0, 20.0, 40.0, 80.0], id: \.self) { v in
                        Button { editor.gridSpacing = v } label: {
                            if editor.gridSpacing == v { Label("\(Int(v)) pt", systemImage: "checkmark") } else { Text("\(Int(v)) pt") }
                        }
                    }
                }
            }
            StatusToggle(title: "Snap", symbol: "dot.squareshape.split.2x2", isOn: editor.snapEnabled, help: "Snap to objects (⇧⌘;)") {
                editor.snapEnabled.toggle()
            } menu: {
                Toggle("Snap to Objects", isOn: $editor.snapEnabled)
                Toggle("Snap to Grid", isOn: Binding(get: { Preferences.shared.snapToGrid }, set: { Preferences.shared.snapToGrid = $0 }))
                Text("Hold ⌘ while dragging to bypass")
            }

            Spacer(minLength: ScrawlTheme.Space.m)
            Text(selectionText)
                .font(ScrawlTheme.Font.status)
                .foregroundStyle(ScrawlTheme.secondaryText)
                .lineLimit(1)
                .accessibilityLabel(selectionText)
            Spacer(minLength: ScrawlTheme.Space.m)

            MiniIconButton(symbol: "map", help: editor.minimapVisible ? "Hide Minimap (⌥⌘M)" : "Show Minimap (⌥⌘M)",
                           isOn: editor.minimapVisible, width: 26) { editor.minimapVisible.toggle() }
            Rectangle().fill(ScrawlTheme.separator).frame(width: 1, height: 14).padding(.horizontal, 2)
            MiniIconButton(symbol: "minus", help: "Zoom Out (⌘−)", width: 22) { editor.zoomOut() }
            ZoomMenu(editor: editor)
            MiniIconButton(symbol: "plus", help: "Zoom In (⌘+)", width: 22) { editor.zoomIn() }
        }
        .padding(.horizontal, ScrawlTheme.Space.m)
        .frame(height: ScrawlTheme.Metrics.statusBarHeight)
        .background(ScrawlTheme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(ScrawlTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private var selectionText: String {
        let s = editor.summary
        if s.isEmpty {
            let n = editor.scene.count
            return n == 0 ? "Empty canvas" : "\(n) object\(n == 1 ? "" : "s")"
        }
        if s.count == 1, let t = s.singleType, let g = s.geometry {
            var text = "\(t.displayName) · \(Int(g.width.rounded())) × \(Int(g.height.rounded()))"
            if s.allLocked { text += " · Locked" }
            return text
        }
        return "\(s.count) selected"
    }
}

private struct StatusToggle<MenuContent: View>: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let menu: MenuContent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(ScrawlTheme.Font.status)
            }
            .foregroundStyle(isOn ? ScrawlTheme.accent : ScrawlTheme.tertiaryText)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(isOn ? ScrawlTheme.accent.opacity(0.12) : (hovering ? ScrawlTheme.hover : .clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .help(help + " — right-click for options")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The zoom percentage; clicking it offers preset levels and fit commands.
private struct ZoomMenu: View {
    let editor: Editor

    var body: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { z in
                Button("\(Int(z * 100))%") { editor.zoom(to: z) }
            }
            Divider()
            Button("Fit Drawing") { editor.zoomToFit() }
            Button("Fit Selection") { editor.zoomToSelection() }.disabled(editor.summary.isEmpty)
        } label: {
            Text("\(Int((editor.zoom * 100).rounded()))%")
                .font(ScrawlTheme.Font.value.weight(.medium))
                .foregroundStyle(ScrawlTheme.primaryText.opacity(0.8))
                .frame(minWidth: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom — click for presets")
        .accessibilityLabel("Zoom \(Int((editor.zoom * 100).rounded())) percent")
    }
}
