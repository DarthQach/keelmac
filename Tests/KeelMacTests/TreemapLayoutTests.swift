import CoreGraphics
import Foundation
@testable import ScanKit
import Testing
@testable import KeelMac

@Suite("Treemap layout")
@MainActor
struct TreemapLayoutTests {
    /// R › Users › me › {Library › {Caches, Mail}, Movies}, plus a tiny Users/Shared and R/Applications.
    private func makeTree() -> ScanTree {
        var tree = ScanTree(rootPath: "/R", scanPath: "/R", rootName: "R", deviceID: 1, lastEventID: 1,
                            eventsUUID: "U", largeFileThreshold: 50_000_000, firmlinks: [])
        let root = tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        func dir(_ parent: Int32, _ name: String, _ bytes: Int64) -> Int32 {
            tree.appendNode(parent: parent, name: name, isDirectory: true, ownBytes: bytes, ownFiles: 10, ownModified: 0)
        }
        let users = dir(root, "Users", 0)
        _ = dir(root, "Applications", 40_000_000_000)
        let me = dir(users, "me", 0)
        _ = dir(users, "Shared", 1_000_000)
        let library = dir(me, "Library", 0)
        _ = dir(me, "Movies", 200_000_000_000)
        _ = dir(library, "Caches", 150_000_000_000)
        _ = dir(library, "Mail", 100_000_000_000)
        tree.finalize()
        return tree
    }

    private func node(named name: String, in tree: ScanTree) -> NodeID? {
        var stack = [tree.root]
        while let id = stack.popLast() {
            if tree.name(of: id) == name { return id }
            stack += tree.children(of: id)
        }
        return nil
    }

    @Test func dominantChildChainsCollapseIntoOneTile() throws {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let users = try #require(tiles.first { $0.name == "Users › me" })
        #expect(users.node == node(named: "me", in: tree))
        #expect(users.hasChildren)
        #expect(users.bytes == tree.bytes(of: try #require(node(named: "Users", in: tree))))
        #expect(!tiles.contains { $0.name == "Users" || $0.name == "me" })
    }

    @Test func bigFoldersNestBeyondTwoLevels() throws {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let caches = try #require(tiles.first { $0.name == "Caches" })
        #expect(caches.depth == 3)
        let library = try #require(tiles.first { $0.name == "Library" })
        #expect(library.rect.contains(caches.rect))
    }

    @Test func openingAChainStartShowsTheInnerFolder() throws {
        let tree = makeTree()
        let users = try #require(node(named: "Users", in: tree))
        let tiles = TreemapView.layout(tree: tree, root: users, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let names = Set(tiles.filter { $0.depth == 1 }.map(\.name))
        #expect(names.contains("Library"))
        #expect(names.contains("Movies"))
    }

    @Test func tinyRectsStopNesting() {
        let tree = makeTree()
        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        #expect(tiles.allSatisfy { $0.depth == 1 && !$0.hasChildren })
    }
}
