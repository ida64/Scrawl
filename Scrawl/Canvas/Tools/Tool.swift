import AppKit

enum Tool: String, CaseIterable, Identifiable {
    case select, hand, rectangle, diamond, ellipse, arrow, line, pencil, text, image, frame, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .hand: return "Hand"
        case .rectangle: return "Rectangle"
        case .diamond: return "Diamond"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .pencil: return "Pen"
        case .text: return "Text"
        case .image: return "Image"
        case .frame: return "Frame"
        case .eraser: return "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .rectangle: return "rectangle"
        case .diamond: return "diamond"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pencil: return "scribble"
        case .text: return "character.cursor.ibeam"
        case .image: return "photo"
        case .frame: return "square.dashed"
        case .eraser: return "eraser"
        }
    }

    /// Single-key shortcut (active only while the canvas has focus).
    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .hand: return "h"
        case .rectangle: return "r"
        case .diamond: return "d"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .line: return "l"
        case .pencil: return "p"
        case .text: return "t"
        case .image: return "i"
        case .frame: return "f"
        case .eraser: return "e"
        }
    }

    static let toolbarOrder: [Tool] = [.select, .hand, .rectangle, .diamond, .ellipse, .arrow, .line, .pencil, .text, .image, .frame, .eraser]

    var createsShape: Bool {
        switch self {
        case .rectangle, .diamond, .ellipse, .frame: return true
        default: return false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .select: return .arrow
        case .hand: return .openHand
        case .text: return .iBeam
        case .image: return .arrow
        case .eraser: return Cursors.eraser
        default: return .crosshair
        }
    }

    static func forKey(_ c: Character) -> Tool? {
        let lower = Character(c.lowercased())
        return allCases.first { $0.shortcut == lower }
    }
}
