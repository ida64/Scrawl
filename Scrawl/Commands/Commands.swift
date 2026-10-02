import CoreGraphics
import Foundation

struct CreateElementsCommand: SceneCommand {
    var name = "Add Element"
    let elements: [Element]

    func execute(in scene: Scene) -> Set<ElementID>? {
        let frames = elements.filter(\.isFrame)
        let others = elements.filter { !$0.isFrame }
        if !frames.isEmpty { scene.insert(frames, at: 0) }
        scene.insert(others)
        for f in frames { SceneOps.adoptContents(of: f.id, in: scene) }
        SceneOps.updateFrameMembership(Set(others.map(\.id)), in: scene)
        return Set(elements.map(\.id))
    }
}

struct DeleteElementsCommand: SceneCommand {
    var name = "Delete"
    let ids: Set<ElementID>

    func execute(in scene: Scene) -> Set<ElementID>? {
        SceneOps.delete(SceneOps.unlocked(ids, in: scene), in: scene)
        return []
    }
}

struct MoveElementsCommand: SceneCommand {
    var name = "Move"
    let ids: Set<ElementID>
    let delta: CGPoint

    func execute(in scene: Scene) -> Set<ElementID>? {
        let movable = SceneOps.expandFrames(SceneOps.unlocked(ids, in: scene), in: scene)
        SceneOps.translate(movable, by: delta, in: scene)
        SceneOps.updateFrameMembership(movable, in: scene)
        return nil
    }
}

/// Applies explicit new frames to elements (used by inspector geometry fields and tests).
struct ResizeElementsCommand: SceneCommand {
    var name = "Resize"
    let frames: [ElementID: CGRect]

    func execute(in scene: Scene) -> Set<ElementID>? {
        for (id, r) in frames where scene.element(id)?.isLocked == false {
            scene.update(id) { $0.resize(to: r) }
        }
        BindingSolver.updateConnectors(in: scene, affectedBy: Set(frames.keys))
        return nil
    }
}

struct RotateElementsCommand: SceneCommand {
    var name = "Rotate"
    let ids: Set<ElementID>
    let angle: CGFloat

    func execute(in scene: Scene) -> Set<ElementID>? {
        let targets = SceneOps.unlocked(ids, in: scene)
        guard let pivot = SceneOps.selectionBounds(targets, in: scene)?.center else { return nil }
        TransformMath.rotate(targets, by: angle, around: pivot, in: scene, originals: Dictionary(uniqueKeysWithValues: scene.elements(targets).map { ($0.id, $0) }))
        return nil
    }
}

struct ChangeStyleCommand: SceneCommand {
    var name = "Change Style"
    let ids: Set<ElementID>
    let change: (inout ElementStyle) -> Void

    func execute(in scene: Scene) -> Set<ElementID>? {
        for id in ids {
            scene.update(id) { change(&$0.style) }
        }
        SceneOps.refitText(ids, in: scene)
        BindingSolver.updateConnectors(in: scene, affectedBy: ids)
        return nil
    }
}

struct EditTextCommand: SceneCommand {
    var name = "Edit Text"
    let id: ElementID
    let text: String

    func execute(in scene: Scene) -> Set<ElementID>? {
        scene.update(id) {
            guard case var .text(t) = $0.kind else { return }
            t.text = text
            $0.kind = .text(t)
            TextLayout.fit(&$0)
        }
        BindingSolver.updateConnectors(in: scene, affectedBy: [id])
        return nil
    }
}

struct GroupElementsCommand: SceneCommand {
    var name = "Group"
    let ids: Set<ElementID>

    func execute(in scene: Scene) -> Set<ElementID>? {
        let members = SceneOps.expandToGroups(ids, in: scene)
        guard members.count > 1 else { return nil }
        let group = UUID()
        for id in members { scene.update(id) { $0.groupIDs.append(group) } }
        // Make the group contiguous in z-order at the position of its topmost member.
        let order = scene.elements.map(\.id)
        guard let top = order.lastIndex(where: members.contains) else { return members }
        let insertAt = order[..<top].filter { !members.contains($0) }.count
        var newOrder = order.filter { !members.contains($0) }
        newOrder.insert(contentsOf: order.filter(members.contains), at: insertAt)
        scene.setOrder(newOrder)
        return members
    }
}

struct UngroupElementsCommand: SceneCommand {
    var name = "Ungroup"
    let ids: Set<ElementID>

    func execute(in scene: Scene) -> Set<ElementID>? {
        let groups = Set(ids.compactMap { scene.element($0)?.outermostGroupID })
        guard !groups.isEmpty else { return nil }
        var affected = Set<ElementID>()
        for e in scene.elements {
            guard let g = e.outermostGroupID, groups.contains(g) else { continue }
            scene.update(e.id) { $0.groupIDs.removeLast() }
            affected.insert(e.id)
        }
        return affected
    }
}

struct LockElementsCommand: SceneCommand {
    let ids: Set<ElementID>
    let lock: Bool
    var name: String { lock ? "Lock" : "Unlock" }

    func execute(in scene: Scene) -> Set<ElementID>? {
        for id in ids { scene.update(id) { $0.isLocked = lock } }
        return nil
    }
}

struct RenameFrameCommand: SceneCommand {
    var name = "Rename Frame"
    let id: ElementID
    let newName: String

    func execute(in scene: Scene) -> Set<ElementID>? {
        scene.update(id) {
            if case .frame = $0.kind { $0.kind = .frame(FrameData(name: newName)) }
        }
        return nil
    }
}

// MARK: - Z-order

enum ReorderAction: CaseIterable {
    case bringForward, sendBackward, bringToFront, sendToBack

    var title: String {
        switch self {
        case .bringForward: return "Bring Forward"
        case .sendBackward: return "Send Backward"
        case .bringToFront: return "Bring to Front"
        case .sendToBack: return "Send to Back"
        }
    }
}

struct ReorderCommand: SceneCommand {
    let ids: Set<ElementID>
    let action: ReorderAction
    var name: String { action.title }

    func execute(in scene: Scene) -> Set<ElementID>? {
        let order = scene.elements.map(\.id)
        scene.setOrder(ReorderCommand.reorder(order, moving: SceneOps.expandToGroups(ids, in: scene), action))
        return nil
    }

    /// Pure z-order computation (deterministic, preserves relative order of moved elements).
    static func reorder(_ order: [ElementID], moving: Set<ElementID>, _ action: ReorderAction) -> [ElementID] {
        let moved = order.filter(moving.contains)
        let rest = order.filter { !moving.contains($0) }
        guard !moved.isEmpty, !rest.isEmpty else { return order }
        switch action {
        case .bringToFront:
            return rest + moved
        case .sendToBack:
            return moved + rest
        case .bringForward:
            // Place the block just above the first non-moving element above the topmost moved one.
            guard let top = order.lastIndex(where: moving.contains) else { return order }
            guard let next = order[(top + 1)...].first(where: { !moving.contains($0) }), let restIdx = rest.firstIndex(of: next) else { return order }
            var out = rest
            out.insert(contentsOf: moved, at: restIdx + 1)
            return out
        case .sendBackward:
            guard let bottom = order.firstIndex(where: moving.contains) else { return order }
            guard let prev = order[..<bottom].last(where: { !moving.contains($0) }), let restIdx = rest.firstIndex(of: prev) else { return order }
            var out = rest
            out.insert(contentsOf: moved, at: restIdx)
            return out
        }
    }
}

// MARK: - Alignment

enum AlignAction: CaseIterable {
    case left, centerX, right, top, centerY, bottom, distributeH, distributeV

    var title: String {
        switch self {
        case .left: return "Align Left"
        case .centerX: return "Align Center"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .centerY: return "Align Middle"
        case .bottom: return "Align Bottom"
        case .distributeH: return "Distribute Horizontally"
        case .distributeV: return "Distribute Vertically"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .centerX: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .centerY: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .distributeH: return "distribute.horizontal.center"
        case .distributeV: return "distribute.vertical.center"
        }
    }

    var minimumCount: Int { self == .distributeH || self == .distributeV ? 3 : 2 }
}

struct AlignCommand: SceneCommand {
    let ids: Set<ElementID>
    let action: AlignAction
    var name: String { action.title }

    /// Groups are aligned as single units.
    static func units(_ ids: Set<ElementID>, in scene: Scene) -> [[ElementID]] {
        var byKey: [UUID: [ElementID]] = [:]
        var keys: [UUID] = []
        for e in scene.elements(ids) {
            let k = e.outermostGroupID ?? e.id
            if byKey[k] == nil { keys.append(k) }
            byKey[k, default: []].append(e.id)
        }
        return keys.compactMap { byKey[$0] }
    }

    func execute(in scene: Scene) -> Set<ElementID>? {
        let units = AlignCommand.units(SceneOps.unlocked(ids, in: scene), in: scene)
        guard units.count >= action.minimumCount else { return nil }
        let boxes = units.compactMap { SceneOps.selectionBounds($0, in: scene) }
        guard boxes.count == units.count, let all = CGRect.union(boxes) else { return nil }
        var deltas = [CGPoint](repeating: .zero, count: units.count)
        switch action {
        case .left: for (i, b) in boxes.enumerated() { deltas[i].x = all.minX - b.minX }
        case .centerX: for (i, b) in boxes.enumerated() { deltas[i].x = all.midX - b.midX }
        case .right: for (i, b) in boxes.enumerated() { deltas[i].x = all.maxX - b.maxX }
        case .top: for (i, b) in boxes.enumerated() { deltas[i].y = all.minY - b.minY }
        case .centerY: for (i, b) in boxes.enumerated() { deltas[i].y = all.midY - b.midY }
        case .bottom: for (i, b) in boxes.enumerated() { deltas[i].y = all.maxY - b.maxY }
        case .distributeH:
            let sorted = boxes.indices.sorted { boxes[$0].midX < boxes[$1].midX }
            let total = boxes.reduce(0) { $0 + $1.width }
            let gap = (all.width - total) / CGFloat(boxes.count - 1)
            var x = all.minX
            for i in sorted { deltas[i].x = x - boxes[i].minX; x += boxes[i].width + gap }
        case .distributeV:
            let sorted = boxes.indices.sorted { boxes[$0].midY < boxes[$1].midY }
            let total = boxes.reduce(0) { $0 + $1.height }
            let gap = (all.height - total) / CGFloat(boxes.count - 1)
            var y = all.minY
            for i in sorted { deltas[i].y = y - boxes[i].minY; y += boxes[i].height + gap }
        }
        var moved = Set<ElementID>()
        for (i, unit) in units.enumerated() where deltas[i] != .zero {
            for id in unit { scene.update(id) { $0.translate(by: deltas[i]) } }
            moved.formUnion(unit)
        }
        BindingSolver.updateConnectors(in: scene, affectedBy: moved)
        SceneOps.updateFrameMembership(moved, in: scene)
        return nil
    }
}
