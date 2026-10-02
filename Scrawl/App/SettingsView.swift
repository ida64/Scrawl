import SwiftUI

struct SettingsView: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("When Scrawl opens", selection: $prefs.launchBehavior) {
                    ForEach(LaunchBehavior.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Save changes automatically", isOn: $prefs.autosave)
                Text("Autosave applies to newly opened windows. Scrawl always writes files safely, so an interrupted save never damages your drawing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Default grid", selection: $prefs.defaultGrid) {
                    ForEach(GridStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("Grid spacing: \(Int(prefs.defaultGridSpacing)) pt", value: $prefs.defaultGridSpacing, in: 5...200, step: 5)
                Toggle("Snap to objects", isOn: $prefs.snapToObjects)
                Toggle("Snap to grid", isOn: $prefs.snapToGrid)
                Text("Hold ⌘ while dragging to temporarily disable snapping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Mouse scroll wheel", selection: $prefs.scrollWheelZooms) {
                    Text("Pans the canvas").tag(false)
                    Text("Zooms the canvas").tag(true)
                }
                Toggle("Show minimap in new windows", isOn: $prefs.showMinimap)
            }
            .tabItem { Label("Canvas", systemImage: "square.grid.3x3") }

            Form {
                Picker("Default style", selection: $prefs.defaultRenderStyle) {
                    ForEach(RenderStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Default stroke width", selection: $prefs.defaultStrokeWidth) {
                    ForEach([1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { Text("\($0.formatted()) pt").tag($0) }
                }
                Picker("Default font", selection: $prefs.defaultFontFamily) {
                    ForEach(FontFamily.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .tabItem { Label("Drawing", systemImage: "pencil.and.scribble") }

            Form {
                Picker("Default scale", selection: $prefs.exportScale) {
                    ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Transparent background", isOn: $prefs.exportTransparent)
                Stepper("Padding: \(Int(prefs.exportPadding)) pt", value: $prefs.exportPadding, in: 0...96, step: 4)
            }
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 330)
    }
}
