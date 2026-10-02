import SwiftUI

struct ShortcutsView: View {
    let close: () -> Void

    private let sections: [(String, [(String, String)])] = [
        ("Tools", [("Select", "V"), ("Hand", "H  ·  hold Space"), ("Rectangle", "R"), ("Ellipse", "O"), ("Diamond", "D"),
                   ("Arrow", "A"), ("Line", "L"), ("Pen", "P"), ("Text", "T"), ("Image", "I"), ("Frame", "F"), ("Eraser", "E"),
                   ("Keep tool active", "Q")]),
        ("Workspace", [("Command palette", "⌘K"), ("Layers sidebar", "⌃⌘S"), ("Inspector", "⌥⌘I"), ("Focus mode", "⇧⌘F"),
                       ("Status bar", "⌥⌘/"), ("Zoom in / out", "⌘+  ⌘−"), ("Actual size", "⌘0"), ("Fit drawing", "⌘1"),
                       ("Fit selection", "⌘2"), ("Cycle grid", "⌘'"), ("Snapping", "⇧⌘;  ·  hold ⌘ to bypass"), ("Minimap", "⌥⌘M")]),
        ("Objects", [("Duplicate", "⌘D  ·  ⌥-drag"), ("Group / Ungroup", "⌘G  ⇧⌘G"), ("Frame selection", "⌥⌘F"),
                     ("Forward / Backward", "⌘]  ⌘["), ("Front / Back", "⌥⌘]  ⌥⌘["), ("Lock / Hide", "⇧⌘L  ⇧⌘H"),
                     ("Nudge", "Arrows  ·  ⇧ for 10"), ("Precision · Ink · Soft", "⌃⌘1  2  3"), ("Copy / Paste style", "⌥⌘C  ⌥⌘V"),
                     ("Fonts", "⌘T"), ("Edit text · rename · crop", "Return  ·  double-click"), ("Select inside group", "⌘-click")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ScrawlTheme.Space.xl) {
            HStack {
                Text("Keyboard Shortcuts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(sections, id: \.0) { title, rows in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(ScrawlTheme.Font.sectionTitle).foregroundStyle(ScrawlTheme.secondaryText)
                            .padding(.bottom, 2)
                        ForEach(rows, id: \.0) { name, keys in
                            HStack(alignment: .firstTextBaseline) {
                                Text(name).font(.system(size: 12))
                                Spacer(minLength: 12)
                                Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(ScrawlTheme.secondaryText)
                            }
                        }
                    }
                    .frame(width: 236)
                }
            }
        }
        .padding(22)
    }
}
