import CoreGraphics
import Foundation
@testable import ScanKit
import Testing
@testable import KeelMac

@Suite("Storage map presentation")
@MainActor
struct TreemapLayoutTests {
    private func makeTree(dense: Bool = false, extraFirst: Bool = false) -> ScanTree {
        var tree = ScanTree(rootPath: "/R", scanPath: "/R", rootName: "R", deviceID: 1, lastEventID: 1,
                            eventsUUID: "U", largeFileThreshold: 50_000_000, firmlinks: [])
        let root = tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 5_000_000_000, ownFiles: 1, ownModified: 0)
        func dir(_ parent: Int32, _ name: String, _ bytes: Int64) -> Int32 {
            tree.appendNode(parent: parent, name: name, isDirectory: true, ownBytes: bytes, ownFiles: 10, ownModified: 0)
        }
        if extraFirst { _ = dir(root, "New", 1) }
        let users = dir(root, "Users", 0)
        _ = dir(root, "Applications", 40_000_000_000)
        let me = dir(users, "me", 0)
        _ = dir(users, "Shared", 1_000_000)
        let library = dir(me, "Library", 0)
        _ = dir(me, "Movies", 200_000_000_000)
        _ = dir(library, "Caches", 150_000_000_000)
        _ = dir(library, "Mail", 100_000_000_000)
        _ = dir(root, "Empty", 0)
        if dense { for i in 0..<2000 { _ = dir(root, "Tiny-\(i)", 10_000) } }
        tree.finalize()
        return tree
    }

    @Test func twoActualLevelsWithoutCollapsedChains() throws {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(tiles.allSatisfy { $0.depth <= 2 })
        let users = try #require(tree.lookup(path: "/R/Users"))
        let me = try #require(tree.lookup(path: "/R/Users/me"))
        #expect(tiles.contains { $0.item == .node(users) && $0.depth == 1 })
        #expect(tiles.contains { $0.item == .node(me) && $0.depth == 2 })
        #expect(!tiles.contains { $0.item.node.map { tree.name(of: $0) == "Caches" } ?? false })
    }

    @Test func allBytesAccountedForAtBothLevels() {
        let tree = makeTree(dense: true)
        let projection = MapPresentation(tree: tree, root: tree.root)
        #expect(projection.entries.reduce(0) { $0 + $1.bytes } == tree.bytes(of: tree.root))
        for entry in projection.entries where !entry.children.isEmpty {
            #expect(entry.children.reduce(0) { $0 + $1.bytes } == entry.bytes)
        }
        #expect(projection.entries.count <= MapPresentation.maximumChildren + 2)
        #expect(projection.entries.contains { $0.item == .other(tree.root) })
        #expect(projection.entries.contains { $0.item == .small(tree.root) })
    }

    @Test func tinyAndZeroNodesRemainInContents() throws {
        let tree = makeTree(dense: true)
        let rows = MapContentsList.rows(tree: tree, root: tree.root, expanded: [])
        #expect(rows.filter { $0.item.node != nil }.count == tree.childCount(of: tree.root))
        let empty = try #require(tree.lookup(path: "/R/Empty"))
        let tiny = try #require(tree.lookup(path: "/R/Tiny-1999"))
        #expect(rows.contains { $0.item == .node(empty) })
        #expect(MapPresentation.matches(.other(tree.root), selection: .node(tiny), tree: tree))
        #expect(MapItem.other(tree.root).node == nil)
        #expect(MapItem.small(tree.root).node == nil)
    }

    @Test func labelsAndChildrenStayInsideTheirAllocatedBounds() throws {
        let tree = makeTree()
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: bounds)
        for tile in tiles {
            #expect(bounds.contains(tile.rect))
            #expect(tile.rect.contains(tile.labelRect))
            if tile.depth == 2 {
                let parent = try #require(tiles.first { $0.depth == 1 && $0.rect.contains(tile.rect) })
                #expect(tile.rect.minY >= parent.labelRect.maxY)
                #expect(!tile.rect.intersects(parent.labelRect))
            }
        }
    }

    @Test func hitUsesVisibleRectanglesIncludingHeaders() throws {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        for tile in tiles {
            let r = tile.hasChildren ? tile.labelRect : tile.rect
            #expect(TreemapView.hit(tiles, CGPoint(x: r.midX, y: r.midY)) == tile.item)
        }
        #expect(TreemapView.hit(tiles, CGPoint(x: -1, y: -1)) == nil)
    }

    @Test func smallContainersStopPreviewNesting() {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 120, height: 80))
        #expect(tiles.allSatisfy { $0.depth == 1 && !$0.hasChildren })
    }

    @Test func sunburstProportionsAndHitGeometryMatch() {
        let tree = makeTree(dense: true)
        let arcs = SunburstView.layout(tree: tree, root: tree.root, radius: 250)
        #expect(arcs.allSatisfy { $0.depth <= 2 })
        let first = arcs.filter { $0.depth == 1 }
        #expect(abs(first.reduce(0) { $0 + $1.end - $1.start } - 2 * .pi) < 0.000001)
        for arc in arcs {
            let a = (arc.start + arc.end) / 2 - .pi / 2
            let r = Double((arc.inner + arc.outer) / 2)
            #expect(SunburstView.hit(arcs, CGPoint(x: cos(a) * r, y: sin(a) * r), center: .zero) == arc.item)
            if arc.depth == 1 {
                let share = Double(arc.item.bytes(in: tree)) / Double(tree.bytes(of: tree.root))
                #expect(abs((arc.end - arc.start) / (2 * .pi) - share) < 0.000001)
            }
        }
        #expect(SunburstView.hit(arcs, .zero, center: .zero) == nil)
        #expect(SunburstView.hit(arcs, CGPoint(x: 300, y: 0), center: .zero) == nil)
    }

    @Test func hiddenChildSelectionHighlightsItsVisibleParent() throws {
        let tree = makeTree()
        let users = try #require(tree.lookup(path: "/R/Users"))
        let me = try #require(tree.lookup(path: "/R/Users/me"))
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 120, height: 80))
        #expect(MapPresentation.target(for: .node(me), among: tiles.map(\.item), tree: tree) == .node(users))
    }

    @Test func zeroByteFolderHasNoShapesAndNoDivisionByZero() throws {
        let tree = makeTree()
        let empty = try #require(tree.lookup(path: "/R/Empty"))
        #expect(MapPresentation(tree: tree, root: empty).entries.isEmpty)
        #expect(TreemapView.layout(tree: tree, root: empty, in: CGRect(x: 0, y: 0, width: 400, height: 300)).isEmpty)
        #expect(SunburstView.layout(tree: tree, root: empty, radius: 200).isEmpty)
    }

    @Test func locationRestoresByPathWhenNodeIndicesChange() throws {
        let old = makeTree()
        let new = makeTree(extraFirst: true)
        let location = MapLocation(focusPath: "/R/Users", selectionPath: "/R/Users/me")
        let restored = location.resolve(in: new)
        #expect(new.path(of: restored.focus) == "/R/Users")
        #expect(new.path(of: try #require(restored.selection)) == "/R/Users/me")
        #expect(restored.selection != old.lookup(path: "/R/Users/me"))
    }

    @Test func missingLocationFallsBackAndClearsSelection() {
        let tree = makeTree()
        let restored = MapLocation(focusPath: "/R/Users/me/Deleted/Child", selectionPath: "/R/Users/me/Deleted/Child/file").resolve(in: tree)
        #expect(tree.path(of: restored.focus) == "/R/Users/me")
        #expect(restored.selection == nil)
        let outside = MapLocation(focusPath: "/gone", selectionPath: "/gone/file").resolve(in: tree)
        #expect(outside.focus == tree.root && outside.selection == nil)
    }
}
