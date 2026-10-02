import Foundation

/// A user-level action that mutates the scene. Commands run inside a scene transaction, so each
/// one becomes exactly one undo step no matter how many elements it touches.
protocol SceneCommand {
    var name: String { get }
    /// Performs the change. Returns the selection to show afterwards (nil = leave as is).
    func execute(in scene: Scene) -> Set<ElementID>?
}

/// Runs commands and interactive edits against a scene and registers them with the undo manager.
final class CommandManager {
    let scene: Scene
    weak var undoManager: UndoManager?

    /// Bridges to the editor's selection so undo/redo can restore it.
    var getSelection: () -> Set<ElementID> = { [] }
    var setSelection: (Set<ElementID>) -> Void = { _ in }
    /// Called after any committed edit, undo or redo.
    var didChange: () -> Void = {}
    /// Lets the UI finish an active text edit before another command runs.
    var willPerformCommand: () -> Void = {}

    private var interactive: (name: String, selectionBefore: Set<ElementID>)?

    init(scene: Scene) {
        self.scene = scene
    }

    var isInteracting: Bool { interactive != nil }
    /// Increments for every interactive edit, so owners can tell whether theirs is still open.
    private(set) var interactiveSerial = 0

    // MARK: Commands

    @discardableResult
    func perform(_ command: SceneCommand) -> Bool {
        perform(command.name) { command.execute(in: $0) }
    }

    /// Runs `body` as a single undoable action.
    @discardableResult
    func perform(_ name: String, _ body: (Scene) -> Set<ElementID>?) -> Bool {
        // Finish any in-flight gesture or text edit first so it stays its own undo step.
        if interactive != nil { willPerformCommand() }
        if interactive != nil { endInteractive() }
        let before = getSelection()
        var newSelection: Set<ElementID>?
        let edit = scene.transaction { newSelection = body(scene) }
        if let newSelection { setSelection(newSelection.filter(scene.contains)) }
        guard let edit else { return false }
        register(edit, name: name, selectionBefore: before, selectionAfter: getSelection())
        didChange()
        return true
    }

    // MARK: Interactive edits (drags)

    /// Starts recording a continuous interaction such as a drag. Live mutations are applied
    /// directly to the scene and become one undo step on `endInteractive`.
    func beginInteractive(_ name: String) {
        // A still-open interaction (e.g. a coalesced color change) is committed, not lost.
        if interactive != nil { endInteractive() }
        interactiveSerial &+= 1
        interactive = (name, getSelection())
        scene.beginTransaction()
    }

    func renameInteractive(_ name: String) {
        interactive?.name = name
    }

    @discardableResult
    func endInteractive(selectionAfter: Set<ElementID>? = nil) -> Bool {
        guard let info = interactive else { return false }
        interactive = nil
        let edit = scene.commitTransaction()
        if let selectionAfter { setSelection(selectionAfter.filter(scene.contains)) }
        guard let edit else { return false }
        register(edit, name: info.name, selectionBefore: info.selectionBefore, selectionAfter: getSelection())
        didChange()
        return true
    }

    func cancelInteractive() {
        guard let info = interactive else { return }
        interactive = nil
        scene.cancelTransaction()
        setSelection(info.selectionBefore.filter(scene.contains))
        didChange()
    }

    // MARK: Undo integration

    private func register(_ edit: SceneEdit, name: String, selectionBefore: Set<ElementID>, selectionAfter: Set<ElementID>) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            target.applyFromUndo(edit.inverted(), name: name, selection: selectionBefore, inverseSelection: selectionAfter)
        }
        um.setActionName(name)
    }

    private func applyFromUndo(_ edit: SceneEdit, name: String, selection: Set<ElementID>, inverseSelection: Set<ElementID>) {
        if interactive != nil { willPerformCommand() }
        if interactive != nil { cancelInteractive() }
        scene.apply(edit)
        setSelection(selection.filter(scene.contains))
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyFromUndo(edit.inverted(), name: name, selection: inverseSelection, inverseSelection: selection)
        }
        undoManager?.setActionName(name)
        didChange()
    }
}
