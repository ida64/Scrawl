import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

enum LaunchBehavior: String, CaseIterable, Identifiable {
    case newDrawing, welcome
    var id: String { rawValue }
    var title: String { self == .newDrawing ? "Open a new drawing" : "Show the welcome window" }
}

/// App-wide user preferences backed by UserDefaults. This is deliberately the only app-level
/// shared state; everything document-related lives in each window's `Editor`.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    var launchBehavior: LaunchBehavior { didSet { save(launchBehavior.rawValue, "launchBehavior") } }
    var defaultGrid: GridStyle { didSet { save(defaultGrid.rawValue, "defaultGrid") } }
    var defaultGridSpacing: Double { didSet { save(defaultGridSpacing, "defaultGridSpacing") } }
    var snapToObjects: Bool { didSet { save(snapToObjects, "snapToObjects") } }
    var snapToGrid: Bool { didSet { save(snapToGrid, "snapToGrid") } }
    var defaultRenderStyle: RenderStyle { didSet { save(defaultRenderStyle.rawValue, "defaultRenderStyle") } }
    var defaultStrokeWidth: Double { didSet { save(defaultStrokeWidth, "defaultStrokeWidth") } }
    var defaultFontFamily: FontFamily { didSet { save(defaultFontFamily.rawValue, "defaultFontFamily") } }
    /// When false, a plain mouse wheel pans and ⌘-wheel zooms. When true, the wheel zooms.
    var scrollWheelZooms: Bool { didSet { save(scrollWheelZooms, "scrollWheelZooms") } }
    var autosave: Bool { didSet { save(autosave, "autosave") } }
    var exportScale: Double { didSet { save(exportScale, "exportScale") } }
    var exportTransparent: Bool { didSet { save(exportTransparent, "exportTransparent") } }
    var exportPadding: Double { didSet { save(exportPadding, "exportPadding") } }
    var showMinimap: Bool { didSet { save(showMinimap, "showMinimap") } }
    var lastExportFormat: ExportFormat { didSet { save(lastExportFormat.rawValue, "lastExportFormat") } }
    var recentColors: [DrawingColor] { didSet { save(recentColors.map(\.serialized), "recentColors") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "appearance": AppearanceMode.system.rawValue,
            "launchBehavior": LaunchBehavior.newDrawing.rawValue,
            "defaultGrid": GridStyle.dots.rawValue,
            "defaultGridSpacing": 20.0,
            "snapToObjects": true,
            "snapToGrid": false,
            "defaultRenderStyle": RenderStyle.precision.rawValue,
            "defaultStrokeWidth": 1.5,
            "defaultFontFamily": FontFamily.sans.rawValue,
            "scrollWheelZooms": false,
            "autosave": true,
            "exportScale": 2.0,
            "exportTransparent": false,
            "exportPadding": 24.0,
            "showMinimap": false,
        ])
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        launchBehavior = LaunchBehavior(rawValue: d.string(forKey: "launchBehavior") ?? "") ?? .newDrawing
        defaultGrid = GridStyle(rawValue: d.string(forKey: "defaultGrid") ?? "") ?? .dots
        defaultGridSpacing = d.double(forKey: "defaultGridSpacing")
        snapToObjects = d.bool(forKey: "snapToObjects")
        snapToGrid = d.bool(forKey: "snapToGrid")
        defaultRenderStyle = RenderStyle(persisted: d.string(forKey: "defaultRenderStyle") ?? "") ?? .precision
        defaultStrokeWidth = d.double(forKey: "defaultStrokeWidth")
        defaultFontFamily = FontFamily(rawValue: d.string(forKey: "defaultFontFamily") ?? "") ?? .sans
        scrollWheelZooms = d.bool(forKey: "scrollWheelZooms")
        autosave = d.bool(forKey: "autosave")
        exportScale = d.double(forKey: "exportScale")
        exportTransparent = d.bool(forKey: "exportTransparent")
        exportPadding = d.double(forKey: "exportPadding")
        showMinimap = d.bool(forKey: "showMinimap")
        lastExportFormat = ExportFormat(rawValue: d.string(forKey: "lastExportFormat") ?? "") ?? .png
        recentColors = (d.stringArray(forKey: "recentColors") ?? []).compactMap { DrawingColor.parse($0) }
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// Style applied to newly created elements in a fresh window.
    var defaultStyle: ElementStyle {
        var s = ElementStyle()
        s.renderStyle = defaultRenderStyle
        s.strokeWidth = defaultStrokeWidth
        s.fontFamily = defaultFontFamily
        return s
    }

    var defaultSettings: DrawingSettings {
        DrawingSettings(background: nil, grid: defaultGrid, gridSpacing: defaultGridSpacing)
    }
}
