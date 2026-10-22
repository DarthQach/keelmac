import Foundation
import ScanKit

/// Synthetic regions are deliberately not filesystem identities.
enum MapItem: Hashable {
    case node(NodeID)
    case other(NodeID)
    case small(NodeID)

    var node: NodeID? { if case .node(let id) = self { id } else { nil } }
    var container: NodeID {
        switch self { case .node(let id), .other(let id), .small(let id): id }
    }
    var key: String {
        switch self {
        case .node(let id): "node-\(id.raw)"
        case .other(let id): "other-\(id.raw)"
        case .small(let id): "small-\(id.raw)"
        }
    }
    func name(in tree: ScanTree) -> String {
        switch self {
        case .node(let id): tree.name(of: id)
        case .other: String(localized: "Other items")
        case .small: String(localized: "Small files")
        }
    }
    func bytes(in tree: ScanTree) -> Int64 {
        switch self {
        case .node(let id): tree.bytes(of: id)
        case .small(let id): max(0, tree.smallFilesBytes(of: id))
        case .other(let id): MapPresentation.omitted(in: tree, parent: id).reduce(0) { $0 + tree.bytes(of: $1) }
        }
    }
}

struct MapEntry: Identifiable {
    var id: MapItem { item }
    let item: MapItem
    let bytes: Int64
    let children: [MapEntry]
}

/// The same two-level projection feeds both maps. Hidden named nodes stay in the list.
struct MapPresentation {
    static let minimumShare = 0.008
    static let maximumChildren = 24
    let entries: [MapEntry]

    init(tree: ScanTree, root: NodeID) {
        entries = Self.entries(in: tree, parent: root, depth: 1)
    }

    static func visible(in tree: ScanTree, parent: NodeID) -> [NodeID] {
        let threshold = Double(tree.bytes(of: parent)) * minimumShare
        return Array(tree.children(of: parent).filter { tree.bytes(of: $0) > 0 && Double(tree.bytes(of: $0)) >= threshold }.prefix(maximumChildren))
    }

    static func omitted(in tree: ScanTree, parent: NodeID) -> [NodeID] {
        let shown = Set(visible(in: tree, parent: parent))
        return tree.children(of: parent).filter { !shown.contains($0) && tree.bytes(of: $0) > 0 }
    }

    private static func entries(in tree: ScanTree, parent: NodeID, depth: Int) -> [MapEntry] {
        var result = visible(in: tree, parent: parent).map { id in
            MapEntry(item: .node(id), bytes: tree.bytes(of: id),
                     children: depth < 2 && tree.isDirectory(id) ? entries(in: tree, parent: id, depth: depth + 1) : [])
        }
        let remaining = omitted(in: tree, parent: parent).reduce(Int64(0)) { $0 + tree.bytes(of: $1) }
        if remaining > 0 { result.append(MapEntry(item: .other(parent), bytes: remaining, children: [])) }
        let small = max(0, tree.smallFilesBytes(of: parent))
        if small > 0 { result.append(MapEntry(item: .small(parent), bytes: small, children: [])) }
        return result
    }

    /// A list selection too small for its own shape highlights its visible containing region.
    static func target(for selection: MapItem?, among items: [MapItem], tree: ScanTree) -> MapItem? {
        guard let selection else { return nil }
        let visible = Set(items)
        if visible.contains(selection) { return selection }
        var node = selection.container
        if selection.node == nil, visible.contains(.node(node)) { return .node(node) }
        while let parent = tree.parent(of: node) {
            if visible.contains(.other(parent)), omitted(in: tree, parent: parent).contains(node) { return .other(parent) }
            if visible.contains(.node(parent)) { return .node(parent) }
            node = parent
        }
        return nil
    }

    static func matches(_ region: MapItem, selection: MapItem?, tree: ScanTree) -> Bool {
        target(for: selection, among: [region], tree: tree) == region
    }

}

/// Paths survive node-index reassignment after incremental rescans.
struct MapLocation {
    var focusPath: String?
    var selectionPath: String?

    func resolve(in tree: ScanTree) -> (focus: NodeID, selection: NodeID?) {
        var path = focusPath ?? tree.rootPath
        var focus = tree.lookup(path: path).flatMap { tree.isDirectory($0) ? $0 : nil }
        while focus == nil && path != "/" && !path.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { break }
            path = parent
            focus = tree.lookup(path: path).flatMap { tree.isDirectory($0) ? $0 : nil }
        }
        let resolved = focus ?? tree.root
        let selected = selectionPath.flatMap { tree.lookup(path: $0) }
        return (resolved, selected.flatMap { id in
            id == resolved || tree.ancestors(of: id).contains(resolved) ? id : nil
        })
    }
}
