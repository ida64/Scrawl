import CoreGraphics
import Foundation

/// Uniform-grid spatial hash over element render bounds. Supports incremental updates so that
/// dragging a few elements in a 10k-element scene only touches those elements' cells.
final class SpatialIndex {
    struct Cell: Hashable { let x: Int; let y: Int }

    let cellSize: CGFloat
    private var cells: [Cell: Set<ElementID>] = [:]
    private var elementCells: [ElementID: [Cell]] = [:]
    private var bounds: [ElementID: CGRect] = [:]
    /// Elements spanning too many cells are kept in a flat list instead.
    private var large: Set<ElementID> = []
    private let maxCellsPerElement = 64

    init(cellSize: CGFloat = 512) {
        self.cellSize = cellSize
    }

    var count: Int { bounds.count }

    func removeAll() {
        cells.removeAll(keepingCapacity: true)
        elementCells.removeAll(keepingCapacity: true)
        bounds.removeAll(keepingCapacity: true)
        large.removeAll()
    }

    func rebuild(_ elements: [Element]) {
        removeAll()
        for e in elements { insert(e.id, e.renderBounds) }
    }

    func bounds(of id: ElementID) -> CGRect? { bounds[id] }

    private func cellRange(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        guard r.isFiniteRect, !r.isNull else { return nil }
        let x0 = Int((r.minX / cellSize).rounded(.down)), x1 = Int((r.maxX / cellSize).rounded(.down))
        let y0 = Int((r.minY / cellSize).rounded(.down)), y1 = Int((r.maxY / cellSize).rounded(.down))
        guard x0 <= x1, y0 <= y1 else { return nil }
        return (x0...x1, y0...y1)
    }

    func insert(_ id: ElementID, _ r: CGRect) {
        remove(id)
        bounds[id] = r
        guard let (xs, ys) = cellRange(r) else { large.insert(id); return }
        if xs.count * ys.count > maxCellsPerElement {
            large.insert(id)
            return
        }
        var list: [Cell] = []
        list.reserveCapacity(xs.count * ys.count)
        for x in xs { for y in ys {
            let c = Cell(x: x, y: y)
            cells[c, default: []].insert(id)
            list.append(c)
        } }
        elementCells[id] = list
    }

    func remove(_ id: ElementID) {
        guard bounds.removeValue(forKey: id) != nil else { return }
        if large.remove(id) != nil { return }
        for c in elementCells.removeValue(forKey: id) ?? [] {
            cells[c]?.remove(id)
            if cells[c]?.isEmpty == true { cells[c] = nil }
        }
    }

    /// IDs whose render bounds intersect `rect` (unordered).
    func query(_ rect: CGRect) -> Set<ElementID> {
        var result = Set<ElementID>()
        guard let (xs, ys) = cellRange(rect) else { return result }
        if xs.count * ys.count > cells.count * 2 {
            // Huge query (zoomed far out): a linear scan is cheaper than visiting empty cells.
            for (id, b) in bounds where b.intersects(rect) { result.insert(id) }
            return result
        }
        for x in xs { for y in ys {
            if let ids = cells[Cell(x: x, y: y)] {
                for id in ids where !result.contains(id) {
                    if let b = bounds[id], b.intersects(rect) { result.insert(id) }
                }
            }
        } }
        for id in large { if let b = bounds[id], b.intersects(rect) { result.insert(id) } }
        return result
    }
}
