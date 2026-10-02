import CoreGraphics
import Foundation

/// A reversible change to a scene, captured as before/after snapshots of touched elements.
struct SceneEdit {
    struct State {
        var before: Element?
        var after: Element?
    }

    var states: [ElementID: State] = [:]
    var orderBefore: [ElementID]?
    var orderAfter: [ElementID]?
    var settingsBefore: DrawingSettings?
    var settingsAfter: DrawingSettings?

    var isEmpty: Bool {
        states.isEmpty && orderBefore == orderAfter && settingsBefore == settingsAfter
    }

    func inverted() -> SceneEdit {
        var e = SceneEdit()
        e.states = states.mapValues { State(before: $0.after, after: $0.before) }
        e.orderBefore = orderAfter
        e.orderAfter = orderBefore
        e.settingsBefore = settingsAfter
        e.settingsAfter = settingsBefore
        return e
    }
}

/// Describes what changed in a notification so observers can update incrementally.
struct SceneChange {
    var changedIDs: Set<ElementID> = []
    var removedIDs: Set<ElementID> = []
    var structural = false
    var settings = false
    /// True when everything should be considered invalid (document load).
    var reset = false

    var isEmpty: Bool { changedIDs.isEmpty && removedIDs.isEmpty && !structural && !settings && !reset }

    mutating func merge(_ o: SceneChange) {
        changedIDs.formUnion(o.changedIDs)
        removedIDs.formUnion(o.removedIDs)
        changedIDs.subtract(o.removedIDs)
        structural = structural || o.structural
        settings = settings || o.settings
        reset = reset || o.reset
    }
}

/// Mutable in-memory model of one document's drawing. All mutation goes through this type so
/// that changes can be recorded into undoable `SceneEdit`s and observers can be notified.
final class Scene {
    private(set) var elements: [Element] = []
    private var indexByID: [ElementID: Int] = [:]
    private(set) var settings = DrawingSettings()

    /// Monotonic counter bumped on every change.
    private(set) var revision = 0
    /// Per-element counter bumped when an element's local appearance changes (not on pure moves).
    private var contentRevisions: [ElementID: Int] = [:]

    private var recorder: Recorder?
    private var recorderDepth = 0
    private var batchDepth = 0
    private var pending = SceneChange()
    private var observers: [UUID: (SceneChange) -> Void] = [:]

    init(drawing: Drawing = Drawing()) {
        load(drawing)
    }

    var drawing: Drawing { Drawing(elements: elements, settings: settings) }
    var count: Int { elements.count }

    // MARK: Lookup

    func element(_ id: ElementID) -> Element? {
        guard let i = indexByID[id] else { return nil }
        return elements[i]
    }

    func index(of id: ElementID) -> Int? { indexByID[id] }
    func contains(_ id: ElementID) -> Bool { indexByID[id] != nil }
    func contentRevision(of id: ElementID) -> Int { contentRevisions[id] ?? 0 }

    func elements(_ ids: some Sequence<ElementID>) -> [Element] {
        ids.compactMap { indexByID[$0] }.sorted().map { elements[$0] }
    }

    func children(ofFrame frameID: ElementID) -> [Element] {
        elements.filter { $0.frameID == frameID }
    }

    /// IDs of all elements that share any group in `groupID`.
    func members(ofGroup groupID: UUID) -> [ElementID] {
        elements.filter { $0.groupIDs.contains(groupID) }.map(\.id)
    }

    // MARK: Observation

    @discardableResult
    func observe(_ handler: @escaping (SceneChange) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    /// Groups mutations so observers receive a single notification.
    func batch<T>(_ body: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 { flush() }
        }
        return try body()
    }

    private func notify(_ change: SceneChange) {
        revision &+= 1
        pending.merge(change)
        if batchDepth == 0 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let c = pending
        pending = SceneChange()
        for o in observers.values { o(c) }
    }

    // MARK: Loading

    func load(_ drawing: Drawing) {
        elements = drawing.elements
        settings = drawing.settings
        rebuildIndex()
        contentRevisions = [:]
        var c = SceneChange()
        c.reset = true
        c.structural = true
        c.settings = true
        notify(c)
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: elements.enumerated().map { ($1.id, $0) })
    }

    // MARK: Transactions

    private final class Recorder {
        var before: [ElementID: Element?] = [:]
        var orderBefore: [ElementID]?
        var settingsBefore: DrawingSettings?
    }

    var isRecording: Bool { recorder != nil }

    /// Begins recording. Nested calls join the outermost transaction.
    func beginTransaction() {
        if recorderDepth == 0 { recorder = Recorder() }
        recorderDepth += 1
    }

    /// Ends recording and returns the captured edit (only for the outermost transaction).
    func commitTransaction() -> SceneEdit? {
        guard recorderDepth > 0 else { return nil }
        recorderDepth -= 1
        guard recorderDepth == 0, let rec = recorder else { return nil }
        recorder = nil
        var edit = SceneEdit()
        for (id, before) in rec.before {
            let after = element(id)
            if before != after { edit.states[id] = .init(before: before, after: after) }
        }
        if let ob = rec.orderBefore {
            let oa = elements.map(\.id)
            if ob != oa { edit.orderBefore = ob; edit.orderAfter = oa }
        }
        if let sb = rec.settingsBefore, sb != settings {
            edit.settingsBefore = sb
            edit.settingsAfter = settings
        }
        return edit.isEmpty ? nil : edit
    }

    /// Runs `body` as a transaction and returns the edit, rolling back if the body throws.
    func transaction(_ body: () throws -> Void) rethrows -> SceneEdit? {
        beginTransaction()
        do {
            try batch { try body() }
        } catch {
            if let e = commitTransaction() { apply(e.inverted()) }
            throw error
        }
        return commitTransaction()
    }

    /// Cancels the current transaction, reverting its changes.
    func cancelTransaction() {
        guard recorderDepth > 0 else { return }
        recorderDepth = 1
        if let e = commitTransaction() { apply(e.inverted()) }
    }

    private func recordBefore(_ id: ElementID) {
        guard let rec = recorder, rec.before.index(forKey: id) == nil else { return }
        rec.before[id] = element(id)
    }

    private func recordOrder() {
        guard let rec = recorder, rec.orderBefore == nil else { return }
        rec.orderBefore = elements.map(\.id)
    }

    // MARK: Mutation

    func update(_ id: ElementID, _ body: (inout Element) -> Void) {
        guard let i = indexByID[id] else { return }
        recordBefore(id)
        let old = elements[i]
        var e = old
        body(&e)
        guard e != old else { return }
        e.id = id
        elements[i] = e
        if Scene.appearanceChanged(old, e) { contentRevisions[id, default: 0] &+= 1 }
        var c = SceneChange()
        c.changedIDs = [id]
        notify(c)
    }

    func update(_ ids: some Sequence<ElementID>, _ body: (inout Element) -> Void) {
        batch {
            for id in ids { update(id, body) }
        }
    }

    /// Replaces an element wholesale (it must already exist).
    func replace(_ element: Element) {
        update(element.id) { $0 = element }
    }

    /// Inserts elements at `index` (default: on top). IDs must be unique.
    func insert(_ new: [Element], at index: Int? = nil) {
        let fresh = new.filter { indexByID[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        recordOrder()
        for e in fresh { recordBefore(e.id) }
        let at = max(0, min(index ?? elements.count, elements.count))
        elements.insert(contentsOf: fresh, at: at)
        rebuildIndex()
        var c = SceneChange()
        c.changedIDs = Set(fresh.map(\.id))
        c.structural = true
        notify(c)
    }

    func remove(_ ids: Set<ElementID>) {
        let present = ids.filter { indexByID[$0] != nil }
        guard !present.isEmpty else { return }
        recordOrder()
        for id in present { recordBefore(id) }
        elements.removeAll { present.contains($0.id) }
        rebuildIndex()
        for id in present { contentRevisions[id] = nil }
        var c = SceneChange()
        c.removedIDs = present
        c.structural = true
        notify(c)
    }

    /// Reorders elements. `order` must be a permutation of the current IDs.
    func setOrder(_ order: [ElementID]) {
        guard order.count == elements.count, order != elements.map(\.id) else { return }
        let map = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        let reordered = order.compactMap { map[$0] }
        guard reordered.count == elements.count else { return }
        recordOrder()
        elements = reordered
        rebuildIndex()
        var c = SceneChange()
        c.structural = true
        notify(c)
    }

    func setSettings(_ s: DrawingSettings) {
        guard s != settings else { return }
        if let rec = recorder, rec.settingsBefore == nil { rec.settingsBefore = settings }
        settings = s
        var c = SceneChange()
        c.settings = true
        notify(c)
    }

    // MARK: Applying edits (undo / redo)

    func apply(_ edit: SceneEdit) {
        batch {
            var c = SceneChange()
            var structural = false
            for (id, st) in edit.states {
                switch (st.after, indexByID[id]) {
                case let (after?, i?):
                    let old = elements[i]
                    elements[i] = after
                    if Scene.appearanceChanged(old, after) { contentRevisions[id, default: 0] &+= 1 }
                    c.changedIDs.insert(id)
                case (_?, nil):
                    structural = true
                    c.changedIDs.insert(id)
                case (nil, _?):
                    structural = true
                    c.removedIDs.insert(id)
                case (nil, nil):
                    break
                }
            }
            if structural || edit.orderAfter != nil {
                // Rebuild the element array from the target order.
                var map = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
                for (id, st) in edit.states {
                    if let a = st.after { map[id] = a } else { map[id] = nil }
                }
                let order = edit.orderAfter ?? elements.map(\.id)
                var result: [Element] = []
                result.reserveCapacity(map.count)
                var used = Set<ElementID>()
                for id in order { if let e = map[id], used.insert(id).inserted { result.append(e) } }
                // Anything not covered by the order goes on top (defensive).
                for e in elements where !used.contains(e.id) { if let m = map[e.id] { result.append(m); used.insert(e.id) } }
                for (id, e) in map where !used.contains(id) { result.append(e) }
                elements = result
                rebuildIndex()
                for id in c.removedIDs { contentRevisions[id] = nil }
                c.structural = true
            }
            if let s = edit.settingsAfter, s != settings {
                settings = s
                c.settings = true
            }
            notify(c)
        }
    }

    // MARK: Helpers

    /// Whether two versions of an element differ in more than position/rotation.
    static func appearanceChanged(_ a: Element, _ b: Element) -> Bool {
        if a.frame.size != b.frame.size { return true }
        var a2 = a
        a2.frame.origin = b.frame.origin
        a2.rotation = b.rotation
        a2.frameID = b.frameID
        a2.groupIDs = b.groupIDs
        a2.isLocked = b.isLocked
        a2.name = b.name
        a2.isHidden = b.isHidden
        // Bindings don't affect local geometry by themselves.
        if var la = a2.linear, let lb = b.linear {
            la.startBinding = lb.startBinding
            la.endBinding = lb.endBinding
            a2.linear = la
        }
        return a2 != b
    }
}
