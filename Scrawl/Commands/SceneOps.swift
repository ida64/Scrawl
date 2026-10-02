import CoreGraphics
import Foundation

/// Reusable scene operations shared by commands and interactive gestures. These never register
/// undo themselves; callers wrap them in a command or an interactive transaction.
enum SceneOps {
    // MARK: Selection expansion

    /// Adds every member of the outermost groups of `ids`.
    static func expandToGroups(_ ids: Set<ElementID>, in scene: Scene) -> Set<ElementID> {
        var groups = Set<UUID>()
        for id in ids { if let g = scene.element(id)?.outermostGroupID { groups.insert(g) } }
        guard !groups.isEmpty else { return ids }
        var out = ids
        for e in scene.elements { if let g = e.outermostGroupID, groups.contains(g) { out.insert(e.id) } }
        return out
    }

    /// Adds the children of any frames in `ids` (frames carry their contents along).
    static func expandFrames(_ ids: Set<ElementID>, in scene: Scene) -> Set<ElementID> {
        let frames = ids.filter { scene.element($0)?.isFrame == true }
        guard !frames.isEmpty else { return ids }
        var out = ids
        for e in scene.elements { if let f = e.frameID, frames.contains(f) { out.insert(e.id) } }
        return out
    }

    static func unlocked(_ ids: Set<ElementID>, in scene: Scene) -> Set<ElementID> {
        ids.filter { scene.element($0)?.isLocked == false }
    }

    static func selectionBounds(_ ids: some Sequence<ElementID>, in scene: Scene) -> CGRect? {
        CGRect.union(ids.compactMap { scene.element($0)?.bounds })
    }

    // MARK: Geometry

    static func translate(_ ids: Set<ElementID>, by delta: CGPoint, in scene: Scene) {
        guard delta != .zero else { return }
        scene.batch {
            for id in ids { scene.update(id) { $0.translate(by: delta) } }
            detachConnectorsMovedWithoutTargets(ids, in: scene)
            BindingSolver.updateConnectors(in: scene, affectedBy: ids)
        }
    }

    /// A connector dragged on its own lets go of shapes that didn't move with it.
    static func detachConnectorsMovedWithoutTargets(_ moved: Set<ElementID>, in scene: Scene) {
        for id in moved {
            guard let e = scene.element(id), var d = e.linear else { continue }
            var changed = false
            if let b = d.startBinding, !moved.contains(b.elementID) { d.startBinding = nil; changed = true }
            if let b = d.endBinding, !moved.contains(b.elementID) { d.endBinding = nil; changed = true }
            if changed { scene.update(id) { $0.linear = d } }
        }
    }

    /// Assigns elements to the topmost frame containing their center (or none).
    static func updateFrameMembership(_ ids: Set<ElementID>, in scene: Scene) {
        let frames = scene.elements.filter(\.isFrame)
        scene.batch {
            for id in ids {
                guard let e = scene.element(id), !e.isFrame else { continue }
                let c = e.bounds.center
                let newID = frames.last { $0.frame.contains(c) }?.id
                if e.frameID != newID { scene.update(id) { $0.frameID = newID } }
            }
        }
    }

    /// Makes the elements fully inside `frame` its children.
    static func adoptContents(of frameID: ElementID, in scene: Scene) {
        guard let f = scene.element(frameID) else { return }
        scene.batch {
            for e in scene.elements where !e.isFrame && e.id != frameID && f.frame.contains(e.bounds) && e.frameID == nil {
                scene.update(e.id) { $0.frameID = frameID }
            }
        }
    }

    // MARK: Deletion

    static func delete(_ ids: Set<ElementID>, in scene: Scene) {
        let all = expandFrames(ids, in: scene)
        scene.batch {
            BindingSolver.detach(from: all, in: scene)
            scene.remove(all)
            // Children of deleted frames are deleted too; anything else that referenced them is freed.
            for e in scene.elements where e.frameID.map(all.contains) == true {
                scene.update(e.id) { $0.frameID = nil }
            }
        }
    }

    // MARK: Insertion

    /// Inserts copies of elements with fresh IDs, remapping groups and internal bindings.
    @discardableResult
    static func insertCopies(of source: [Element], offset: CGPoint, in scene: Scene) -> [ElementID] {
        var idMap: [ElementID: ElementID] = [:]
        var groupMap: [UUID: UUID] = [:]
        for e in source { idMap[e.id] = UUID() }
        for e in source { for g in e.groupIDs where groupMap[g] == nil { groupMap[g] = UUID() } }
        var copies: [Element] = []
        for e in source {
            var c = e
            c.id = idMap[e.id] ?? UUID()
            c.seed = SeededRandom.randomSeed()
            c.groupIDs = e.groupIDs.compactMap { groupMap[$0] }
            c.frameID = e.frameID.flatMap { idMap[$0] } ?? (e.frameID.flatMap { scene.contains($0) ? $0 : nil })
            c.translate(by: offset)
            if var d = c.linear {
                d.startBinding = d.startBinding.flatMap { b in idMap[b.elementID].map { ConnectorBinding(elementID: $0, anchor: b.anchor) } }
                d.endBinding = d.endBinding.flatMap { b in idMap[b.elementID].map { ConnectorBinding(elementID: $0, anchor: b.anchor) } }
                c.linear = d
            }
            copies.append(c)
        }
        // Frames go to the back so their contents stay visible above them.
        let frames = copies.filter(\.isFrame)
        let others = copies.filter { !$0.isFrame }
        scene.batch {
            if !frames.isEmpty { scene.insert(frames, at: 0) }
            scene.insert(others)
        }
        return copies.map(\.id)
    }

    // MARK: Text

    static func refitText(_ ids: some Sequence<ElementID>, in scene: Scene) {
        for id in ids where scene.element(id)?.isText == true {
            scene.update(id) { TextLayout.fit(&$0) }
        }
    }
}
