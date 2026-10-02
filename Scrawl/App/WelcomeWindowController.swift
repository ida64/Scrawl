import AppKit
import SwiftUI

final class WelcomeWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.title = "Welcome to Scrawl"
        window.contentView = NSHostingView(rootView: WelcomeView())
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct WelcomeView: View {
    @State private var recents: [URL] = NSDocumentController.shared.recentDocumentURLs
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("Scrawl").font(.system(size: 26, weight: .bold))
                Text("Diagram at the speed of thought.").font(.system(size: 13)).foregroundStyle(ScrawlTheme.secondaryText)
                Spacer().frame(height: 6)
                VStack(spacing: 8) {
                    WelcomeAction(title: "New Drawing", symbol: "plus.square", shortcut: "⌘N") {
                        NSDocumentController.shared.newDocument(nil)
                        closeWindow()
                    }
                    WelcomeAction(title: "Open Drawing…", symbol: "folder", shortcut: "⌘O") {
                        NSDocumentController.shared.openDocument(nil)
                    }
                    WelcomeAction(title: "Open Sample Drawing", symbol: "sparkles", shortcut: nil) {
                        NSApp.sendAction(#selector(AppDelegate.openSampleDrawing(_:)), to: nil, from: nil)
                    }
                }
                .frame(width: 230)
                Spacer()
                Toggle("Show this window when Scrawl opens", isOn: Binding(
                    get: { prefs.launchBehavior == .welcome },
                    set: { prefs.launchBehavior = $0 ? .welcome : .newDrawing }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
            .frame(width: 330)
            .background(DotField().opacity(0.9))

            Rectangle().fill(ScrawlTheme.separator).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                // Sits on the same line as the window controls.
                Text("Recent Drawings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScrawlTheme.secondaryText)
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
                    .padding(.bottom, 6)
                if recents.isEmpty {
                    Spacer()
                    Text("No recent drawings")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recents, id: \.self) { url in
                                RecentRow(url: url) { open(url) }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScrawlTheme.chrome)
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(ScrawlTheme.canvas)
        // Both columns run the full height, under the transparent titlebar.
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recents = NSDocumentController.shared.recentDocumentURLs
        }
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) } else { closeWindow() }
        }
    }

    private func closeWindow() {
        (NSApp.delegate as? AppDelegate)?.closeWelcome()
    }
}

private struct WelcomeAction: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 11).monospaced()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.medium + 1, style: .continuous).fill(hovering ? ScrawlTheme.hover : ScrawlTheme.field))
            .overlay(RoundedRectangle(cornerRadius: ScrawlTheme.Radius.medium + 1, style: .continuous).strokeBorder(ScrawlTheme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
    }
}

/// Scrawl's dot motif as a quiet background.
private struct DotField: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var y: CGFloat = step / 2
            var row = 0
            while y < size.height {
                var x: CGFloat = step / 2
                var col = 0
                while x < size.width {
                    let major = row % 5 == 0 && col % 5 == 0
                    let r: CGFloat = major ? 1.4 : 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(.primary.opacity(major ? 0.16 : 0.08)))
                    x += step
                    col += 1
                }
                y += step
                row += 1
            }
        }
        .mask(LinearGradient(colors: [.black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}
