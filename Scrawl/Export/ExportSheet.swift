import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    let editor: Editor
    let scope: ExportScope
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = Preferences.shared.lastExportFormat
    @State private var scale: Double = Preferences.shared.exportScale
    @State private var transparent = Preferences.shared.exportTransparent
    @State private var darkTheme = false
    @State private var padding: Double = Preferences.shared.exportPadding
    @State private var preview: NSImage?
    @State private var sizeText = ""

    private var title: String {
        switch scope {
        case .drawing: return "Export Drawing"
        case .selection: return "Export Selection"
        case let .frame(id): return "Export “\(editor.scene.element(id)?.frameData?.name ?? "Frame")”"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 18) {
                previewPane
                    .frame(width: 300, height: 220)
                Form {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if format.isRaster {
                        Picker("Scale", selection: $scale) {
                            ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Transparent background", isOn: $transparent)
                        .disabled(format == .jpeg)
                    Toggle("Dark theme", isOn: $darkTheme)
                    if case .frame = scope {} else {
                        HStack {
                            Text("Padding")
                            Slider(value: $padding, in: 0...96, step: 4)
                            Text("\(Int(padding))").monospacedDigit().frame(width: 24, alignment: .trailing)
                        }
                    }
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.columns)
                .frame(width: 260)
            }
            HStack {
                Button("Copy to Clipboard") { copyToClipboard() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            darkTheme = editor.isDarkCanvas
            render()
        }
        .onChange(of: format) { _, _ in render() }
        .onChange(of: scale) { _, _ in render() }
        .onChange(of: transparent) { _, _ in render() }
        .onChange(of: darkTheme) { _, _ in render() }
        .onChange(of: padding) { _, _ in render() }
    }

    private var previewPane: some View {
        ZStack {
            Checkerboard().clipShape(RoundedRectangle(cornerRadius: 8))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                Text("Nothing to export").foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityLabel("Export preview")
    }

    private var options: ExportOptions {
        var o = ExportOptions()
        o.scale = format.isRaster ? scale : 1
        o.transparentBackground = transparent && format != .jpeg
        o.dark = darkTheme
        o.padding = padding
        o.background = editor.scene.settings.background
        return o
    }

    private func render() {
        let (elements, clip) = ExportService.content(for: scope, scene: editor.scene)
        var o = options
        guard let bounds = ExportService.contentBounds(elements, clip: clip, padding: o.padding) else {
            preview = nil
            sizeText = ""
            return
        }
        let px = CGSize(width: (bounds.width * o.scale).rounded(), height: (bounds.height * o.scale).rounded())
        sizeText = format.isRaster ? "\(Int(px.width)) × \(Int(px.height)) px" : "\(Int(bounds.width)) × \(Int(bounds.height)) pt · vector"
        o.scale = min(2, 600 / max(bounds.width, bounds.height, 1))
        if let img = ExportService.renderImage(elements, clip: clip, scene: editor.scene, assets: editor.assets, options: o, opaque: format == .jpeg) {
            preview = NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
        }
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch format {
        case .svg:
            if let d = ExportService.export(scope, format: .svg, scene: editor.scene, assets: editor.assets, options: options),
               let s = String(data: d, encoding: .utf8) {
                pb.setString(s, forType: .string)
                pb.setData(d, forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
            }
        case .pdf:
            if let d = ExportService.export(scope, format: .pdf, scene: editor.scene, assets: editor.assets, options: options) { pb.setData(d, forType: .pdf) }
        case .png, .jpeg:
            if let d = ExportService.export(scope, format: .png, scene: editor.scene, assets: editor.assets, options: options) { pb.setData(d, forType: .png) }
        }
        dismiss()
        editor.showToast("Copied \(format.title)", symbol: "doc.on.doc")
    }

    private func save() {
        let fmt = format
        let opts = options
        let scope = scope
        let editor = editor
        Preferences.shared.exportScale = scale
        Preferences.shared.lastExportFormat = fmt
        Preferences.shared.exportTransparent = transparent
        Preferences.shared.exportPadding = padding
        let base = editor.document?.displayName ?? "Drawing"
        var name = base
        if case let .frame(id) = scope, let f = editor.scene.element(id)?.frameData { name = "\(base) – \(f.name)" }
        dismiss()
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [fmt.utType]
            panel.nameFieldStringValue = "\(name).\(fmt.fileExtension)"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                guard let data = ExportService.export(scope, format: fmt, scene: editor.scene, assets: editor.assets, options: opts) else {
                    editor.showToast("Nothing to export", symbol: "exclamationmark.triangle")
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    editor.showToast("Exported \(fmt.title)", symbol: "checkmark.circle")
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}
