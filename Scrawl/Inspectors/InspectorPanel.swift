import SwiftUI

/// Right-side inspector. Shows only what applies to the selection (or, with nothing selected,
/// to the active tool's new objects and to the canvas).
struct InspectorPanel: View {
    @Bindable var editor: Editor

    private var s: SelectionSummary { editor.summary }
    private var style: ElementStyle { s.style }
    private var dark: Bool { editor.isDarkCanvas }

    private var types: Set<ElementType> {
        if !s.isEmpty { return s.types }
        switch editor.tool {
        case .rectangle: return [.rectangle]
        case .ellipse: return [.ellipse]
        case .diamond: return [.diamond]
        case .arrow: return [.arrow]
        case .line: return [.line]
        case .pencil: return [.freehand]
        case .text: return [.text]
        case .frame: return [.frame]
        default: return []
        }
    }

    private var shapeTypes: Set<ElementType> { [.rectangle, .ellipse, .diamond] }
    private var showStroke: Bool { !types.isDisjoint(with: [.rectangle, .ellipse, .diamond, .line, .arrow, .freehand]) }
    private var showFill: Bool { !types.isDisjoint(with: shapeTypes) }
    private var showTextColor: Bool { types == [.text] }
    private var showAppearance: Bool { !types.isDisjoint(with: [.rectangle, .ellipse, .diamond, .line, .arrow, .freehand, .image]) }
    private var showLinear: Bool { !types.isDisjoint(with: [.line, .arrow]) }
    private var showText: Bool { types.contains(.text) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ScrawlTheme.separator)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if s.isEmpty && types.isEmpty {
                        canvasSection
                        divider
                        defaultsSection
                    } else {
                        if let id = s.frameID { frameSection(id); divider }
                        if showStroke || showFill || showTextColor { styleSection; divider }
                        if !s.isEmpty, s.geometry != nil { geometrySection; divider }
                        if showAppearance { appearanceSection; divider }
                        if showLinear { connectorSection; divider }
                        if showText { textSection; divider }
                        if s.types == [.image] { imageSection; divider }
                        if !s.isEmpty { arrangeSection }
                    }
                }
                .padding(.bottom, ScrawlTheme.Space.xl)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ScrawlTheme.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private var divider: some View {
        Rectangle().fill(ScrawlTheme.separator).frame(height: 1).padding(.horizontal, ScrawlTheme.Space.l)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: ScrawlTheme.Space.m) {
            Image(systemName: headerSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ScrawlTheme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ScrawlTheme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 0) {
                Text(headerTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(headerSubtitle).font(ScrawlTheme.Font.small).foregroundStyle(ScrawlTheme.secondaryText).lineLimit(1)
            }
            Spacer()
            if !s.isEmpty {
                MiniIconButton(symbol: s.allHidden ? "eye.slash" : "eye", help: s.allHidden ? "Show" : "Hide", isOn: s.allHidden) {
                    editor.toggleHiddenSelection()
                }
                MiniIconButton(symbol: s.allLocked ? "lock.fill" : "lock.open", help: s.allLocked ? "Unlock (⇧⌘L)" : "Lock (⇧⌘L)", isOn: s.allLocked) {
                    editor.toggleLock()
                }
            }
        }
        .padding(.horizontal, ScrawlTheme.Space.l)
        .frame(height: 46)
    }

    private var headerTitle: String {
        if s.count == 1, let e = editor.selectedElements.first { return e.displayName }
        if s.count > 1 { return "\(s.count) Objects" }
        if !types.isEmpty, let t = types.first { return "New \(t.displayName)" }
        return "Canvas"
    }

    private var headerSubtitle: String {
        if s.count == 1, let t = s.singleType {
            var parts = [t.displayName]
            if let e = editor.selectedElements.first, let f = e.frameID, let frame = editor.scene.element(f)?.frameData { parts.append("in \(frame.name)") }
            if s.hasGroup { parts.append("grouped") }
            return parts.joined(separator: " · ")
        }
        if s.count > 1 { return s.types.map(\.displayName).sorted().joined(separator: ", ") }
        if !types.isEmpty { return "Defaults for new objects" }
        return editor.document?.displayName ?? "Drawing"
    }

    private var headerSymbol: String {
        if s.count > 1 { return "square.on.square" }
        if let t = s.singleType ?? types.first { return Editor.symbol(for: t) }
        return "rectangle.dashed"
    }

    // MARK: Style

    private var strokeQuick: [DrawingColor] {
        let base = Palette.stroke
        let recents = editor.recentColors.filter { !base.contains($0) }
        return Array((recents + base).prefix(5))
    }

    private var fillQuick: [DrawingColor] {
        let base = Array(Palette.fill.dropFirst())
        let recents = editor.recentColors.filter { !base.contains($0) }
        return Array((recents + base).prefix(4))
    }

    private var styleSection: some View {
        InspectorSection("Style") {
            if showFill {
                InspectorRow("Fill") {
                    ColorRow(current: style.fillColor, allowsNone: true, quick: fillQuick, palette: Palette.fill + Palette.stroke.dropFirst(), dark: dark,
                             onPick: { c in editor.applyStyle("Fill") { $0.fillColor = c } },
                             onCustom: { c in editor.applyStyleCoalesced { $0.fillColor = c }; editor.noteRecentColor(c) })
                }
            }
            if showStroke || showTextColor {
                InspectorRow(showTextColor ? "Color" : "Stroke") {
                    ColorRow(current: style.strokeColor, allowsNone: false, quick: strokeQuick, palette: Palette.stroke, dark: dark,
                             onPick: { c in editor.applyStyle(showTextColor ? "Text Color" : "Stroke") { $0.strokeColor = c } },
                             onCustom: { c in editor.applyStyleCoalesced { $0.strokeColor = c }; editor.noteRecentColor(c) })
                }
            }
            InspectorRow("Opacity") {
                Slider(value: Binding(get: { style.opacity }, set: { v in editor.applyStyle("Opacity") { $0.opacity = (v * 100).rounded() / 100 } }),
                       in: 0.05...1) { editing in editing ? editor.beginStyleScrub() : editor.endStyleScrub() }
                    .controlSize(.mini)
                    .accessibilityLabel("Opacity")
                NumberField(label: "", value: (style.opacity * 100).rounded(), unit: "%", range: 5...100) { v in
                    editor.applyStyle("Opacity") { $0.opacity = v / 100 }
                }
                .frame(width: 58)
            }
        }
    }

    // MARK: Geometry

    @State private var lockAspect = false

    private var geometrySection: some View {
        let g = s.geometry ?? .zero
        let locked = s.allLocked
        return InspectorSection("Geometry") {
            HStack(spacing: ScrawlTheme.Space.s) {
                NumberField(label: "X", value: g.minX.rounded()) { editor.setGeometry(x: $0) }
                NumberField(label: "Y", value: g.minY.rounded()) { editor.setGeometry(y: $0) }
            }
            HStack(spacing: ScrawlTheme.Space.s) {
                NumberField(label: "W", value: g.width.rounded(), range: 1...1_000_000) { editor.setGeometry(width: $0, keepAspect: lockAspect) }
                NumberField(label: "H", value: g.height.rounded(), range: 1...1_000_000) { editor.setGeometry(height: $0, keepAspect: lockAspect) }
                MiniIconButton(symbol: lockAspect ? "link" : "link.badge.plus", help: lockAspect ? "Proportions locked" : "Lock proportions",
                               isOn: lockAspect, width: 22) { lockAspect.toggle() }
            }
            if s.count == 1, let t = s.singleType, ![.line, .arrow, .frame].contains(t) {
                HStack(spacing: ScrawlTheme.Space.s) {
                    NumberField(label: "↻", value: Double(s.rotation * 180 / .pi).rounded(), unit: "°", range: -360...360) {
                        editor.setRotation(degrees: $0)
                    }
                    MiniIconButton(symbol: "rotate.left", help: "Rotate 90° Left", width: 26) { editor.rotateSelection(by: -.pi / 2) }
                    MiniIconButton(symbol: "rotate.right", help: "Rotate 90° Right", width: 26) { editor.rotateSelection(by: .pi / 2) }
                    MiniIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal", width: 26) { editor.flip(horizontal: true) }
                }
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.55 : 1)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        InspectorSection("Appearance") {
            if !types.isDisjoint(with: [.rectangle, .ellipse, .diamond, .line, .arrow]) {
                ScrawlSegmented(options: RenderStyle.allCases.map { SegmentOption(value: $0, label: .text($0.title), help: $0.subtitle) },
                                selection: style.renderStyle) { editor.setRenderStyle($0) }
            }
            if showStroke {
                InspectorRow("Stroke") {
                    NumberField(label: "", value: style.strokeWidth, unit: "pt", step: 0.25, range: 0...64, digits: 2) { v in
                        editor.applyStyle("Stroke Width") { $0.strokeWidth = v }
                    } onScrubBegan: { editor.beginStyleScrub() } onScrubEnded: { editor.endStyleScrub() }
                    .frame(width: 66)
                    ScrawlSegmented(options: [SegmentOption(value: StrokeStyle.solid, label: .icon("line.diagonal"), help: "Solid"),
                                              SegmentOption(value: .dashed, label: .text("– –"), help: "Dashed"),
                                              SegmentOption(value: .dotted, label: .text("···"), help: "Dotted")],
                                    selection: style.strokeStyle) { v in editor.applyStyle("Stroke Pattern") { $0.strokeStyle = v } }
                }
            }
            if !types.isDisjoint(with: [.rectangle, .diamond, .image]) {
                InspectorRow("Corners") {
                    NumberField(label: "", value: style.cornerRadius, unit: "pt", range: 0...256) { v in
                        editor.applyStyle("Corner Radius") { $0.cornerRadius = v }
                    } onScrubBegan: { editor.beginStyleScrub() } onScrubEnded: { editor.endStyleScrub() }
                    .frame(width: 66)
                    Spacer()
                }
            }
            if showFill && style.renderStyle == .ink && !style.fillColor.isClear {
                InspectorRow("Texture") {
                    ScrawlSegmented(options: [SegmentOption(value: FillStyle.solid, label: .text("Solid"), help: "Solid fill"),
                                              SegmentOption(value: .hachure, label: .text("Hatch"), help: "Hatched fill"),
                                              SegmentOption(value: .crossHatch, label: .text("Cross"), help: "Cross-hatched fill")],
                                    selection: style.fillStyle) { v in editor.applyStyle("Fill Texture") { $0.fillStyle = v } }
                }
            }
        }
    }

    // MARK: Connector

    private var connectorSection: some View {
        InspectorSection("Connector") {
            InspectorRow("Route") {
                ScrawlSegmented(options: [SegmentOption(value: LineRouting.straight, label: .icon("line.diagonal"), help: "Straight"),
                                          SegmentOption(value: .curved, label: .icon("point.topleft.down.to.point.bottomright.curvepath"), help: "Curved"),
                                          SegmentOption(value: .elbow, label: .icon("arrow.turn.down.right"), help: "Elbow")],
                                selection: style.routing) { v in editor.applyStyle("Route") { $0.routing = v } }
            }
            InspectorRow("Ends") {
                ArrowheadPicker(title: "Start", value: style.startArrowhead, mirrored: true) { v in editor.applyStyle("Arrowhead") { $0.startArrowhead = v } }
                ArrowheadPicker(title: "End", value: style.endArrowhead, mirrored: false) { v in editor.applyStyle("Arrowhead") { $0.endArrowhead = v } }
                Spacer(minLength: 0)
                MiniIconButton(symbol: "arrow.left.arrow.right", help: "Swap ends", width: 22) {
                    let a = style.startArrowhead, b = style.endArrowhead
                    editor.applyStyle("Swap Arrowheads") { $0.startArrowhead = b; $0.endArrowhead = a }
                }
            }
        }
    }

    // MARK: Text

    private var textSection: some View {
        InspectorSection("Text") {
            InspectorRow("Typeface") {
                Menu {
                    ForEach(FontFamily.allCases, id: \.self) { f in
                        Button {
                            editor.applyStyle("Typeface") { $0.fontFamily = f; $0.fontName = nil }
                        } label: {
                            if style.fontName == nil && style.fontFamily == f { Label(f.displayName, systemImage: "checkmark") } else { Text(f.displayName) }
                        }
                    }
                    Divider()
                    Button("Show Fonts…") { editor.showFontPanel?() }
                } label: {
                    Text(style.typefaceName).font(ScrawlTheme.Font.label).lineLimit(1)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            InspectorRow("Size") {
                NumberField(label: "", value: style.fontSize, unit: "pt", step: 0.5, range: 4...400) { v in
                    editor.applyStyle("Font Size") { $0.fontSize = v }
                } onScrubBegan: { editor.beginStyleScrub() } onScrubEnded: { editor.endStyleScrub() }
                .frame(width: 66)
                ScrawlSegmented(options: [SegmentOption(value: FontWeightOption.regular, label: .text("Reg"), help: "Regular"),
                                          SegmentOption(value: .medium, label: .text("Med"), help: "Medium"),
                                          SegmentOption(value: .bold, label: .text("Bold"), help: "Bold")],
                                selection: style.fontWeight) { v in editor.applyStyle("Font Weight") { $0.fontWeight = v } }
            }
            InspectorRow("Align") {
                ScrawlSegmented(options: [SegmentOption(value: TextAlign.left, label: .icon("text.alignleft"), help: "Align Left"),
                                          SegmentOption(value: .center, label: .icon("text.aligncenter"), help: "Center"),
                                          SegmentOption(value: .right, label: .icon("text.alignright"), help: "Align Right")],
                                selection: style.textAlign) { v in editor.applyStyle("Text Alignment") { $0.textAlign = v } }
            }
            InspectorRow("Spacing") {
                NumberField(label: "", value: style.lineHeight, unit: "×", step: 0.01, range: 0.6...3, digits: 2) { v in
                    editor.applyStyle("Line Spacing") { $0.lineHeight = v }
                } onScrubBegan: { editor.beginStyleScrub() } onScrubEnded: { editor.endStyleScrub() }
                .frame(width: 66)
                if s.hasText {
                    Toggle("Wrap", isOn: Binding(get: { !s.textAutoWidth }, set: { editor.setTextAutoWidth(!$0) }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(ScrawlTheme.Font.label)
                        .help("Wrap text to the box width")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Frame & image

    private func frameSection(_ id: ElementID) -> some View {
        InspectorSection("Frame") {
            InspectorRow("Name") {
                FrameNameField(name: s.frameName ?? "") { editor.renameFrame(id, to: $0) }
            }
            HStack(spacing: ScrawlTheme.Space.s) {
                Button("Zoom to Frame") { editor.zoomToFrame(id) }
                Button("Export…") { editor.exportRequest = .frame(id) }
            }
            .controlSize(.small)
        }
    }

    private var imageSection: some View {
        InspectorSection("Image") {
            HStack(spacing: ScrawlTheme.Space.s) {
                if s.count == 1, let id = editor.selection.first {
                    if editor.croppingImageID == id {
                        Button("Done Cropping") { editor.endCrop() }
                    } else {
                        Button("Crop") { editor.beginCrop(id) }
                    }
                }
                Button("Reset Crop") { editor.resetCrop() }
            }
            .controlSize(.small)
        }
    }

    // MARK: Arrange

    private var arrangeSection: some View {
        InspectorSection("Arrange") {
            InspectorRow("Layer") {
                HStack(spacing: 1) {
                    MiniIconButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send to Back (⌥⌘[)", width: 28) { editor.reorder(.sendToBack) }
                    MiniIconButton(symbol: "square.2.layers.3d.bottom.filled", help: "Send Backward (⌘[)", width: 28) { editor.reorder(.sendBackward) }
                    MiniIconButton(symbol: "square.2.layers.3d.top.filled", help: "Bring Forward (⌘])", width: 28) { editor.reorder(.bringForward) }
                    MiniIconButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to Front (⌥⌘])", width: 28) { editor.reorder(.bringToFront) }
                }
                Spacer(minLength: 0)
            }
            if s.count > 1 {
                InspectorRow("Align") {
                    HStack(spacing: 0) {
                        ForEach(Array(AlignAction.allCases.prefix(6)), id: \.self) { a in
                            MiniIconButton(symbol: a.symbol, help: a.title, width: 25) { editor.align(a) }
                        }
                    }
                }
                InspectorRow("Distribute") {
                    MiniIconButton(symbol: AlignAction.distributeH.symbol, help: AlignAction.distributeH.title, width: 28) { editor.align(.distributeH) }
                        .disabled(s.count < 3)
                    MiniIconButton(symbol: AlignAction.distributeV.symbol, help: AlignAction.distributeV.title, width: 28) { editor.align(.distributeV) }
                        .disabled(s.count < 3)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: ScrawlTheme.Space.s) {
                if s.count > 1 { Button("Group") { editor.group() } }
                if s.hasGroup { Button("Ungroup") { editor.ungroup() } }
                if !s.types.contains(.frame) { Button("Frame Selection") { editor.frameSelection() } }
            }
            .controlSize(.small)
        }
    }

    // MARK: Canvas (nothing selected)

    private var canvasSection: some View {
        InspectorSection("Canvas") {
            InspectorRow("Paper") {
                HStack(spacing: 2) {
                    AutoPaperSwatch(selected: editor.scene.settings.background == nil) { editor.setCanvasBackground(nil) }
                    ForEach(Array(CanvasBackgrounds.options.compactMap { $0 }.enumerated()), id: \.offset) { _, option in
                        SwatchChip(color: option, selected: editor.scene.settings.background == option, dark: dark) {
                            editor.setCanvasBackground(option)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            InspectorRow("Grid") {
                ScrawlSegmented(options: [SegmentOption(value: GridStyle.none, label: .text("None"), help: "No grid"),
                                          SegmentOption(value: .dots, label: .text("Dots"), help: "Dot grid"),
                                          SegmentOption(value: .lines, label: .text("Lines"), help: "Square grid")],
                                selection: editor.gridStyle) { editor.gridStyle = $0 }
            }
            InspectorRow("Spacing") {
                NumberField(label: "", value: editor.gridSpacing, unit: "pt", range: 4...400) { editor.gridSpacing = $0 }
                    .frame(width: 66)
                Spacer(minLength: 0)
            }
            InspectorRow("Snapping") {
                Toggle("Objects", isOn: $editor.snapEnabled).toggleStyle(.checkbox).controlSize(.small)
                Toggle("Grid", isOn: Binding(get: { Preferences.shared.snapToGrid }, set: { Preferences.shared.snapToGrid = $0 }))
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer(minLength: 0)
            }
            .font(ScrawlTheme.Font.label)
        }
    }

    private var defaultsSection: some View {
        InspectorSection("New Objects") {
            ScrawlSegmented(options: RenderStyle.allCases.map { SegmentOption(value: $0, label: .text($0.title), help: $0.subtitle) },
                            selection: editor.currentStyle.renderStyle) { v in editor.applyStyle("Style") { $0.renderStyle = v } }
            InspectorRow("Stroke") {
                ColorRow(current: editor.currentStyle.strokeColor, allowsNone: false, quick: strokeQuick, palette: Palette.stroke, dark: dark,
                         onPick: { c in editor.applyStyle { $0.strokeColor = c } },
                         onCustom: { c in editor.applyStyle { $0.strokeColor = c }; editor.noteRecentColor(c) })
            }
            InspectorRow("Fill") {
                ColorRow(current: editor.currentStyle.fillColor, allowsNone: true, quick: fillQuick, palette: Palette.fill, dark: dark,
                         onPick: { c in editor.applyStyle { $0.fillColor = c } },
                         onCustom: { c in editor.applyStyle { $0.fillColor = c }; editor.noteRecentColor(c) })
            }
            Text("Pick a tool or select objects to edit their properties.")
                .font(ScrawlTheme.Font.small)
                .foregroundStyle(ScrawlTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Automatic" paper: warm paper / deep graphite split diagonally.
private struct AutoPaperSwatch: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(red: 0.965, green: 0.957, blue: 0.937))
                Path { p in p.move(to: CGPoint(x: 16, y: 0)); p.addLine(to: CGPoint(x: 16, y: 16)); p.addLine(to: CGPoint(x: 0, y: 16)); p.closeSubpath() }
                    .fill(Color(red: 0.09, green: 0.094, blue: 0.106))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ScrawlTheme.border, lineWidth: 0.75)
            }
            .frame(width: 16, height: 16)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? ScrawlTheme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .help("Automatic — follows Light/Dark appearance")
        .accessibilityLabel("Automatic paper")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum CanvasBackgrounds {
    /// nil = automatic (warm paper / deep graphite).
    static let options: [DrawingColor?] = [nil, DrawingColor(hex: "#ffffff"), DrawingColor(hex: "#f3efe4"), DrawingColor(hex: "#e9eef3"),
                                           DrawingColor(hex: "#1b1d22"), DrawingColor(hex: "#14202b")]
}

private struct ArrowheadPicker: View {
    let title: String
    let value: Arrowhead
    let mirrored: Bool
    let onPick: (Arrowhead) -> Void

    var body: some View {
        Menu {
            ForEach(Arrowhead.allCases, id: \.self) { a in
                Button { onPick(a) } label: { Label(Self.name(a), systemImage: Self.symbol(a)) }
            }
        } label: {
            Image(systemName: Self.symbol(value))
                .scaleEffect(x: mirrored ? -1 : 1)
                .font(ScrawlTheme.Font.label)
                .frame(width: 22)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("\(title) arrowhead: \(Self.name(value))")
        .accessibilityLabel("\(title) arrowhead: \(Self.name(value))")
    }

    static func name(_ a: Arrowhead) -> String {
        switch a {
        case .none: return "None"
        case .arrow: return "Open"
        case .triangle: return "Triangle"
        case .dot: return "Dot"
        case .bar: return "Bar"
        }
    }

    static func symbol(_ a: Arrowhead) -> String {
        switch a {
        case .none: return "minus"
        case .arrow: return "chevron.right"
        case .triangle: return "arrowtriangle.right.fill"
        case .dot: return "circle.fill"
        case .bar: return "poweron"
        }
    }
}

private struct FrameNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Frame name", text: $text)
            .textFieldStyle(.plain)
            .font(ScrawlTheme.Font.label)
            .padding(.horizontal, 6)
            .frame(height: ScrawlTheme.Metrics.fieldHeight)
            .background(ScrawlTheme.field, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onAppear { text = name }
            .onChange(of: name) { _, n in text = n }
            .onSubmit { commit(text) }
    }
}

extension Editor {
    static func symbol(for t: ElementType) -> String {
        switch t {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .diamond: return "diamond"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .image: return "photo"
        case .frame: return "square.dashed"
        }
    }

    func setCanvasBackground(_ c: DrawingColor?) {
        var s = scene.settings
        guard s.background != c else { return }
        s.background = c
        perform(SimpleCommand(name: "Canvas Background") { scene in
            scene.setSettings(s)
            return nil
        })
    }
}
