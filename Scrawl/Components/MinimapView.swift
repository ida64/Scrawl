import AppKit
import SwiftUI

/// Compact overview of the whole drawing with the current viewport. Click or drag to navigate.
final class MinimapView: NSView {
    private let editor: Editor
    private var sceneToken: UUID?
    private var viewportToken: UUID?
    private var redrawScheduled = false

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        sceneToken = editor.scene.observe { [weak self] _ in self?.scheduleRedraw() }
        viewportToken = editor.observeViewport { [weak self] in self?.needsDisplay = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Minimap. Click to move the view.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            if let t = sceneToken { editor.scene.removeObserver(t) }
            if let t = viewportToken { editor.removeViewportObserver(t) }
        }
    }

    override var isFlipped: Bool { true }

    /// Scene changes during drags can arrive at 120 Hz; the minimap only needs ~20 Hz.
    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.redrawScheduled = false
            self?.needsDisplay = true
        }
    }

    /// World rect shown in the minimap: content plus the current viewport.
    private var worldRect: CGRect {
        let visible = editor.viewport.visibleWorldRect(viewSize: editor.viewSize)
        let content = CGRect.union(editor.scene.elements.map(\.bounds)) ?? visible
        return content.union(visible).expanded(by: 40)
    }

    /// Mapping is frozen while dragging so the map doesn't shift under the pointer.
    private var frozenMapping: (scale: CGFloat, offset: CGPoint, world: CGRect)?

    private func mapping() -> (scale: CGFloat, offset: CGPoint, world: CGRect) {
        if let f = frozenMapping { return f }
        let w = worldRect
        let pad: CGFloat = 8
        let scale = min((bounds.width - pad * 2) / max(w.width, 1), (bounds.height - pad * 2) / max(w.height, 1))
        let offset = CGPoint(x: (bounds.width - w.width * scale) / 2, y: (bounds.height - w.height * scale) / 2)
        return (scale, offset, w)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (scale, offset, w) = mapping()
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - w.minX) * scale, y: offset.y + (r.minY - w.minY) * scale, width: max(1, r.width * scale), height: max(1, r.height * scale))
        }
        let dark = editor.isDarkCanvas
        let ink = DrawingColor.ink.cgColor(dark: dark)
        // Very large scenes are sampled to keep the minimap cheap.
        let elements = editor.scene.elements
        let stride = max(1, elements.count / 4000)
        var i = 0
        while i < elements.count {
            let e = elements[i]
            let r = map(e.bounds)
            if e.isFrame {
                ctx.setStrokeColor(ink.copy(alpha: 0.45) ?? ink)
                ctx.setLineWidth(1)
                ctx.stroke(r)
            } else {
                let c: CGColor = e.style.fillColor.isClear ? e.style.strokeColor.cgColor(dark: dark) : e.style.fillColor.cgColor(dark: dark)
                ctx.setFillColor(c.copy(alpha: min(0.7, c.alpha)) ?? c)
                ctx.fill(r)
            }
            i += stride
        }
        let vr = map(editor.viewport.visibleWorldRect(viewSize: editor.viewSize))
        let accent = CanvasTheme.selection(highContrast: false)
        ctx.setFillColor(accent.copy(alpha: 0.12) ?? accent)
        ctx.fill(vr)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.stroke(vr.insetBy(dx: 0.75, dy: 0.75))
    }

    override func mouseDown(with event: NSEvent) {
        frozenMapping = mapping()
        navigate(event)
    }

    override func mouseDragged(with event: NSEvent) { navigate(event) }

    override func mouseUp(with event: NSEvent) {
        frozenMapping = nil
        needsDisplay = true
    }

    private func navigate(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (scale, offset, w) = mapping()
        let world = CGPoint(x: w.minX + (p.x - offset.x) / scale, y: w.minY + (p.y - offset.y) / scale)
        var v = editor.viewport
        v.center(on: world, viewSize: editor.viewSize)
        editor.viewport = v
    }
}

struct MinimapRepresentable: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> MinimapView { MinimapView(editor: editor) }
    func updateNSView(_ nsView: MinimapView, context: Context) { nsView.needsDisplay = true }
}
