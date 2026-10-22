import ScanKit
import SwiftUI

struct MapListRow: Identifiable {
    var id: MapItem { item }
    let item: MapItem
    let depth: Int
}

struct MapContentsList: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: MapItem?
    @Binding var expanded: Set<NodeID>
    let open: (NodeID) -> Void
    let goUp: () -> Void
    var colors: KindShares?

    static func rows(tree: ScanTree, root: NodeID, expanded: Set<NodeID>) -> [MapListRow] {
        var rows: [MapListRow] = []
        for node in tree.children(of: root) {
            rows.append(MapListRow(item: .node(node), depth: 0))
            if expanded.contains(node) {
                rows += tree.children(of: node).map { MapListRow(item: .node($0), depth: 1) }
                if tree.smallFilesBytes(of: node) > 0 { rows.append(MapListRow(item: .small(node), depth: 1)) }
            }
        }
        if tree.smallFilesBytes(of: root) > 0 { rows.append(MapListRow(item: .small(root), depth: 0)) }
        return rows
    }

    var body: some View {
        let grouped: Set<NodeID> = {
            if case .other(let parent) = selection { return Set(MapPresentation.omitted(in: tree, parent: parent)) }
            return []
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contents").font(.headline)
                    Text("Largest first · share of this folder").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Size").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Self.rows(tree: tree, root: root, expanded: expanded)) { row in
                        rowView(row, grouped: grouped)
                            .tag(row.item)
                            .id(row.item)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if let node = row.item.node { open(node) } })
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("storage.contents")
                .overlay {
                    if Self.rows(tree: tree, root: root, expanded: expanded).isEmpty {
                        Text("This folder is empty.").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: selection) { _, item in
                    guard let item else { return }
                    let target: MapItem
                    switch item {
                    case .other(let parent):
                        if parent != root { expanded.insert(parent) }
                        guard let first = MapPresentation.omitted(in: tree, parent: parent).first else { return }
                        target = .node(first)
                    case .small(let parent):
                        if parent != root { expanded.insert(parent) }
                        target = item
                    case .node(let node):
                        if let parent = tree.parent(of: node), parent != root { expanded.insert(parent) }
                        target = item
                    }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                }
                .onKeyPress(.return) { if let node = selection?.node { open(node) }; return .handled }
                .onKeyPress(.escape) { goUp(); return .handled }
            }
        }
        .kmTableSurface()
    }

    private func rowView(_ row: MapListRow, grouped: Set<NodeID>) -> some View {
        let item = row.item
        let node = item.node
        let directory = node.map(tree.isDirectory) ?? false
        let bytes = item.bytes(in: tree)
        let fraction = tree.bytes(of: root) > 0 ? Double(bytes) / Double(tree.bytes(of: root)) : 0
        return HStack(spacing: 8) {
            if let node, directory, row.depth == 0, tree.childCount(of: node) > 0 || tree.smallFilesBytes(of: node) > 0 {
                Button {
                    if expanded.contains(node) { expanded.remove(node) } else { expanded.insert(node) }
                } label: {
                    Image(systemName: expanded.contains(node) ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                        .frame(width: 20, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded.contains(node) ? Text("Collapse folder") : Text("Expand folder"))
                .accessibilityIdentifier("storage.disclosure.\(node.raw)")
            } else {
                Color.clear.frame(width: 20, height: 1).accessibilityHidden(true)
            }
            Image(systemName: node == nil ? "square.stack" : directory ? "folder" : "doc")
                .foregroundStyle(selection == item ? AnyShapeStyle(.primary) : AnyShapeStyle(node.flatMap { colors?.group(of: $0, in: tree)?.color } ?? Color.kmFgMuted))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.name(in: tree)).font(.body).lineLimit(1).truncationMode(.middle)
                if let node, tree.info(node).isUnreadable {
                    Label("Access required", systemImage: "lock").font(.caption).foregroundStyle(selection == item ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.kmWarningInk))
                } else if node == nil {
                    Text("Combined size only").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(bytes)).font(.body.weight(.medium))
                Text(Format.percent(fraction, digits: 1)).font(.caption).foregroundStyle(.secondary)
            }
            .tabular().fixedSize()
        }
        .foregroundStyle(.primary)
        .padding(.leading, CGFloat(row.depth) * 20)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .help(tree.path(of: item.container))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.row.\(item.key)")
        .accessibilityActions {
            if let node, directory {
                Button("Open folder") { open(node) }
                if row.depth == 0, tree.childCount(of: node) > 0 || tree.smallFilesBytes(of: node) > 0 {
                    Button(expanded.contains(node) ? "Collapse folder" : "Expand folder") {
                        if expanded.contains(node) { expanded.remove(node) } else { expanded.insert(node) }
                    }
                }
            }
        }
        .background(item.node.map(grouped.contains) == true ? Color.kmAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

}
