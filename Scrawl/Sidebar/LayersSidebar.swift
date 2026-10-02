import SwiftUI
import UniformTypeIdentifiers

/// One row in the layers outline.
struct LayerNode: Identifiable, Hashable {
    let id: ElementID
    let name: String
    let type: ElementType
    let hidden: Bool
    let locked: Bool
    let grouped: Bool
    var children: [LayerNode]?

    static func build(_ scene: Scene, filter: String) -> [LayerNode] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func node(_ e: Element) -> LayerNode {
            LayerNode(id: e.id, name: e.displayName, type: e.type, hidden: e.isHidden, locked: e.isLocked, grouped: !e.groupIDs.isEmpty, children: nil)
        }
        func matches(_ e: Element) -> Bool { query.isEmpty || e.displayName.lowercased().contains(query) }
        var childrenByFrame: [ElementID: [LayerNode]] = [:]
        // Front-most first, like every layers panel.
        for e in scene.elements.reversed() {
            if let f = e.frameID, matches(e) { childrenByFrame[f, default: []].append(node(e)) }
        }
        var roots: [LayerNode] = []
        for e in scene.elements.reversed() where e.frameID == nil || scene.element(e.frameID!) == nil {
            if e.isFrame {
                let kids = childrenByFrame[e.id] ?? []
                guard matches(e) || !kids.isEmpty else { continue }
                var n = node(e)
                n.children = kids
                roots.append(n)
            } else if matches(e) {
                roots.append(node(e))
            }
        }
        return roots
    }
}

struct LayersSidebar: View {
    @Bindable var editor: Editor
    @State private var filter = ""
    @State private var renaming: ElementID?
    /// Frames are expanded unless the user collapses them.
    @State private var collapsed: Set<ElementID> = []

    private func expansion(_ id: ElementID) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) }, set: { open in
            if open { collapsed.remove(id) } else { collapsed.insert(id) }
        })
    }

    private var nodes: [LayerNode] {
        _ = editor.layersRevision
        return LayerNode.build(editor.scene, filter: filter)
    }

    private var selection: Binding<Set<ElementID>> {
        Binding(get: { editor.selection }, set: { ids in
            editor.tool = .select
            editor.select(ids)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ScrawlTheme.Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(ScrawlTheme.tertiaryText)
                TextField("Filter layers", text: $filter)
                    .textFieldStyle(.plain)
                    .font(ScrawlTheme.Font.label)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(ScrawlTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(ScrawlTheme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, ScrawlTheme.Space.m)
            .padding(.vertical, ScrawlTheme.Space.s)

            let items = nodes
            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "square.3.layers.3d").font(.system(size: 20, weight: .light)).foregroundStyle(ScrawlTheme.tertiaryText)
                    Text(filter.isEmpty ? "No layers yet" : "No matches").font(ScrawlTheme.Font.label).foregroundStyle(ScrawlTheme.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(items) { node in
                        if let kids = node.children {
                            DisclosureGroup(isExpanded: expansion(node.id)) {
                                ForEach(kids) { kid in
                                    LayerRow(node: kid, editor: editor, renaming: $renaming).tag(kid.id)
                                }
                            } label: {
                                LayerRow(node: node, editor: editor, renaming: $renaming)
                            }
                            .tag(node.id)
                        } else {
                            LayerRow(node: node, editor: editor, renaming: $renaming).tag(node.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            HStack(spacing: 2) {
                Text("\(editor.scene.count) object\(editor.scene.count == 1 ? "" : "s")")
                    .font(ScrawlTheme.Font.small)
                    .foregroundStyle(ScrawlTheme.tertiaryText)
                Spacer()
                MiniIconButton(symbol: "eye", help: "Show All Hidden") { editor.showAllHidden() }
                MiniIconButton(symbol: "square.dashed", help: "Frame Selection (⌥⌘F)") { editor.frameSelection() }
                    .disabled(editor.selection.isEmpty)
            }
            .padding(.horizontal, ScrawlTheme.Space.m)
            .frame(height: 28)
            .overlay(alignment: .top) { Rectangle().fill(ScrawlTheme.separator).frame(height: 1) }
        }
        .frame(minWidth: 200, idealWidth: ScrawlTheme.Metrics.sidebarWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layers")
    }
}

private struct LayerRow: View {
    let node: LayerNode
    let editor: Editor
    @Binding var renaming: ElementID?
    @State private var hovering = false
    @State private var draft = ""
    @State private var dropTarget = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Editor.symbol(for: node.type))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(node.type == .frame ? ScrawlTheme.accent : ScrawlTheme.secondaryText)
                .frame(width: 16)
            if renaming == node.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onAppear { draft = node.name; fieldFocused = true }
                    .onSubmit { commitRename() }
                    .onChange(of: fieldFocused) { _, f in if !f { commitRename() } }
            } else {
                Text(node.name)
                    .font(.system(size: 12, weight: node.type == .frame ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(node.hidden ? ScrawlTheme.tertiaryText : ScrawlTheme.primaryText)
                if node.grouped {
                    Image(systemName: "link").font(.system(size: 8.5)).foregroundStyle(ScrawlTheme.tertiaryText).help("In a group")
                }
            }
            Spacer(minLength: 4)
            if hovering || node.locked {
                rowButton(node.locked ? "lock.fill" : "lock.open", help: node.locked ? "Unlock" : "Lock", on: node.locked) {
                    editor.setLocked([node.id], locked: !node.locked)
                }
            }
            if hovering || node.hidden {
                rowButton(node.hidden ? "eye.slash" : "eye", help: node.hidden ? "Show" : "Hide", on: node.hidden) {
                    editor.setHidden([node.id], hidden: !node.hidden)
                }
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if dropTarget { Rectangle().fill(ScrawlTheme.accent).frame(height: 2).offset(y: -2) }
        }
        .onTapGesture(count: 2) { renaming = node.id }
        .contextMenu {
            Button("Rename") { renaming = node.id }
            Button(node.hidden ? "Show" : "Hide") { editor.setHidden([node.id], hidden: !node.hidden) }
            Button(node.locked ? "Unlock" : "Lock") { editor.setLocked([node.id], locked: !node.locked) }
            Divider()
            Button("Zoom to Layer") {
                editor.select([node.id])
                editor.zoomToSelection()
            }
            Divider()
            Button("Delete", role: .destructive) {
                editor.select([node.id])
                editor.deleteSelection()
            }
        }
        .onDrag { NSItemProvider(object: node.id.uuidString as NSString) }
        .onDrop(of: [.text], isTargeted: $dropTarget) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, let id = UUID(uuidString: s), id != node.id else { return }
                Task { @MainActor in editor.moveLayers([id], above: node.id) }
            }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name), \(node.type.displayName)\(node.hidden ? ", hidden" : "")\(node.locked ? ", locked" : "")")
    }

    private func rowButton(_ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(on ? ScrawlTheme.accent : ScrawlTheme.secondaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func commitRename() {
        guard renaming == node.id else { return }
        renaming = nil
        if draft != node.name { editor.rename(node.id, to: draft) }
    }
}
