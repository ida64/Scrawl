import AppKit

/// NSTextView subclass that keeps its own undo stack while editing (one canvas undo step is
/// recorded when editing finishes) and commits on Escape / ⌘↩.
final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCommit?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        return ok
    }
}

/// Manages inline editing of one text element on the canvas.
final class TextEditorOverlay: NSObject, NSTextViewDelegate {
    let elementID: ElementID
    let isNew: Bool
    private unowned let canvas: CanvasView
    private let textView = CanvasTextView(frame: .zero)
    private let localUndo = UndoManager()
    private var committed = false

    private var editor: Editor { canvas.editor }

    init(canvas: CanvasView, elementID: ElementID, isNew: Bool) {
        self.canvas = canvas
        self.elementID = elementID
        self.isNew = isNew
        super.init()
    }

    func install() {
        guard let e = editor.scene.element(elementID), let t = e.textData else { return }
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.focusRingType = .none
        tv.onCommit = { [weak self] in self?.canvas.commitTextEditing() }
        tv.setAccessibilityLabel("Text")
        applyStyle(e)
        tv.string = t.text
        canvas.addSubview(tv)
        syncFrame(for: elementID)
        canvas.window?.makeFirstResponder(tv)
        if isNew { tv.setSelectedRange(NSRange(location: 0, length: 0)) } else { tv.selectAll(nil) }
    }

    private func applyStyle(_ e: Element) {
        let zoom = editor.viewport.zoom
        let attrs = TextLayout.attributes(e.style, color: e.style.strokeColor.nsColor(dark: canvas.isDark), scale: zoom)
        textView.typingAttributes = attrs
        textView.font = e.style.font(scale: zoom)
        textView.textColor = e.style.strokeColor.nsColor(dark: canvas.isDark)
        textView.alignment = e.style.nsTextAlignment
        textView.defaultParagraphStyle = TextLayout.paragraphStyle(e.style)
        textView.insertionPointColor = CanvasTheme.selection(highContrast: false).nsColor
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Positions the editor over its element (called on viewport and model changes).
    func syncFrame(for id: ElementID?) {
        guard id == elementID, let e = editor.scene.element(elementID), let t = e.textData else { return }
        let zoom = editor.viewport.zoom
        if abs((textView.font?.pointSize ?? 0) - CGFloat(e.style.fontSize) * zoom) > 0.01 || textView.alignment != e.style.nsTextAlignment {
            applyStyle(e)
        }
        let r = editor.viewport.toScreen(e.frame)
        let extra = t.autoWidth ? CGFloat(e.style.fontSize) * zoom : 0
        // Align the box for centered / right-aligned auto-width text so it grows symmetrically.
        var x = r.minX
        if t.autoWidth {
            switch e.style.textAlign {
            case .center: x -= extra / 2
            case .right: x -= extra
            case .left: break
            }
        }
        let frame = CGRect(x: x, y: r.minY, width: r.width + extra, height: max(r.height, CGFloat(e.style.fontSize) * zoom * 1.2))
        textView.frame = frame
        textView.textContainer?.containerSize = CGSize(width: t.autoWidth ? frame.width : r.width, height: .greatestFiniteMagnitude)
        if e.rotation != 0 {
            textView.frameCenterRotation = -e.rotation * 180 / .pi
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let text = textView.string
        editor.scene.update(elementID) { e in
            guard case var .text(t) = e.kind else { return }
            t.text = text
            e.kind = .text(t)
            TextLayout.fit(&e)
        }
        BindingSolver.updateConnectors(in: editor.scene, affectedBy: [elementID])
        syncFrame(for: elementID)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { localUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertTab(_:)) {
            textView.insertText("    ", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    // MARK: Commit

    func commit() {
        guard !committed else { return }
        committed = true
        textView.delegate = nil
        textView.removeFromSuperview()
        let text = editor.scene.element(elementID)?.textData?.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isNew {
                editor.commands.cancelInteractive()
            } else {
                editor.commands.renameInteractive("Delete Text")
                SceneOps.delete([elementID], in: editor.scene)
                editor.commands.endInteractive(selectionAfter: [])
            }
        } else {
            editor.commands.endInteractive(selectionAfter: [elementID])
        }
    }
}

private extension CGColor {
    var nsColor: NSColor { NSColor(cgColor: self) ?? .controlAccentColor }
}
