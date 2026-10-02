import SwiftUI

/// Hosts the AppKit canvas inside SwiftUI.
struct CanvasRepresentable: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

/// The center pane: tool rail, canvas and status strip. Only transient UI (palette, toasts,
/// minimap) ever floats over the canvas.
struct WorkspaceView: View {
    @Bindable var editor: Editor
    let canvas: CanvasView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !editor.focusMode {
                    ToolRail(editor: editor)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ZStack(alignment: .top) {
                    CanvasRepresentable(canvas: canvas)
                        .accessibilityLabel("Drawing canvas")

                    if let toast = editor.toast {
                        ToastView(toast: toast)
                            .padding(.top, ScrawlTheme.Space.l)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                            .allowsHitTesting(false)
                    }

                    if !editor.hasContent && editor.editingTextID == nil && !editor.focusMode {
                        EmptyCanvasHint()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if editor.minimapVisible && !editor.focusMode {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                MinimapRepresentable(editor: editor)
                                    .frame(width: 190, height: 128)
                                    .clipShape(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.medium, style: .continuous))
                                    .elevatedSurface(radius: ScrawlTheme.Radius.medium)
                            }
                        }
                        .padding(ScrawlTheme.Space.l)
                        .transition(.opacity)
                    }

                    if editor.focusMode {
                        FocusModeBadge { editor.toggleFocusMode() }
                            .padding(.top, ScrawlTheme.Space.l)
                            .transition(.opacity)
                    }

                    if editor.commandPaletteVisible {
                        Color.black.opacity(0.08)
                            .onTapGesture { editor.commandPaletteVisible = false }
                        CommandPaletteView(editor: editor, canvas: canvas)
                            .padding(.top, 64)
                            .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                    }

                    if editor.performanceHUD {
                        HStack { Spacer(); PerformanceHUD(editor: editor, canvas: canvas) }
                            .padding(ScrawlTheme.Space.l)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
            }
            if editor.statusBarVisible && !editor.focusMode {
                StatusBar(editor: editor)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ScrawlTheme.Motion.animation(reduceMotion: reduceMotion), value: editor.focusMode)
        .animation(ScrawlTheme.Motion.animation(ScrawlTheme.Motion.quick, reduceMotion: reduceMotion), value: editor.commandPaletteVisible)
        .animation(ScrawlTheme.Motion.animation(reduceMotion: reduceMotion), value: editor.toast)
        .animation(ScrawlTheme.Motion.animation(ScrawlTheme.Motion.quick, reduceMotion: reduceMotion), value: editor.minimapVisible)
        .sheet(item: $editor.exportRequest) { scope in
            ExportSheet(editor: editor, scope: scope)
        }
        .sheet(isPresented: $editor.shortcutsVisible) {
            ShortcutsView { editor.shortcutsVisible = false }
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 6) {
            if let s = toast.symbol {
                Image(systemName: s).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ScrawlTheme.accent)
            }
            Text(toast.message).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .elevatedSurface(radius: 7)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Empty-state mark: Scrawl's three-dot motif and a few quiet hints.
struct EmptyCanvasHint: View {
    var body: some View {
        VStack(spacing: ScrawlTheme.Space.l) {
            HStack(spacing: 7) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i == 1 ? ScrawlTheme.accent : ScrawlTheme.tertiaryText)
                        .frame(width: 6, height: 6)
                }
            }
            VStack(spacing: ScrawlTheme.Space.xs) {
                hint("R", "rectangle")
                hint("A", "arrow")
                hint("T", "text")
                hint("⌘K", "every command")
            }
        }
        .opacity(0.9)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(ScrawlTheme.secondaryText)
                .frame(minWidth: 24, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ScrawlTheme.border))
            Text(what)
                .font(.system(size: 12))
                .foregroundStyle(ScrawlTheme.tertiaryText)
                .frame(width: 100, alignment: .leading)
        }
    }
}

private struct FocusModeBadge: View {
    let exit: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: exit) {
            HStack(spacing: 5) {
                Image(systemName: "eye").font(.system(size: 10, weight: .semibold))
                Text("Focus — Esc to exit").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ScrawlTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .elevatedSurface(radius: 12)
            .opacity(hovering ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PerformanceHUD: View {
    let editor: Editor
    let canvas: CanvasView
    @State private var text = ""

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium).monospaced())
            .padding(6)
            .elevatedSurface(radius: 6)
            .task {
                while !Task.isCancelled {
                    text = String(format: "%d elements · %.1f ms/frame", editor.scene.count, canvas.lastRenderDuration * 1000)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}
