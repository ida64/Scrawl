import CoreGraphics
import Foundation

enum GridStyle: String, CaseIterable, Sendable {
    case none, dots, lines

    var displayName: String {
        switch self {
        case .none: return "No Grid"
        case .dots: return "Dot Grid"
        case .lines: return "Square Grid"
        }
    }
}

/// Document-level settings saved with the drawing.
struct DrawingSettings: Equatable, Sendable {
    /// `nil` means the theme-adaptive default canvas color.
    var background: DrawingColor?
    var grid: GridStyle = .dots
    var gridSpacing: Double = 20
}

/// The complete persistent content of a document.
struct Drawing: Equatable, Sendable {
    /// Elements in z-order, back to front.
    var elements: [Element] = []
    var settings = DrawingSettings()
}
