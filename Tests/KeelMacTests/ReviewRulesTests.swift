import CoreGraphics
import Foundation
@testable import ScanKit
import Testing
@testable import KeelMac

@Suite("Review rules")
@MainActor
struct ReviewRulesTests {
    let now = Date()
    private func days(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    private func item(owner: ReviewOwner, lastOpened: Date? = nil, nodes: [NodeID] = []) -> ReviewItem {
        ReviewItem(id: "x", name: "x", path: "/x", kind: .aiModel, bytes: 1, nodes: nodes, lastOpened: lastOpened,
                   owner: owner, removal: .trash(["/x"]))
    }

    @Test func runningOwnerLocksTheRow() {
        let app = OwnerApp(name: "FlowRunner", bundleID: "dev.vicaai.FlowRunner", isRunning: true, lastUsed: days(1))
        #expect(ReviewRules.status(for: item(owner: .app(bundleID: "dev.vicaai.FlowRunner")), owner: app, now: now) == .locked(app: "FlowRunner"))
    }

    @Test func recentUseAsksFirstAndOldUseIsFree() {
        let recent = OwnerApp(name: "FlowRunner", bundleID: "x", isRunning: false, lastUsed: days(3))
        #expect(ReviewRules.status(for: item(owner: .app(bundleID: "x")), owner: recent, now: now) == .recentlyUsed(app: "FlowRunner", date: days(3)))
        let old = OwnerApp(name: "FlowRunner", bundleID: "x", isRunning: false, lastUsed: days(90))
        #expect(ReviewRules.status(for: item(owner: .app(bundleID: "x")), owner: old, now: now) == .free)
        #expect(ReviewRules.status(for: item(owner: .none), owner: nil, now: now) == .free)
    }

    @Test func ollamaIsNeverLockedButRecentModelsAskFirst() {
        let ollama = OwnerApp(name: "Ollama", bundleID: OwnerResolver.ollamaBundleID, isRunning: true, lastUsed: days(0))
        #expect(ReviewRules.status(for: item(owner: .ollama, lastOpened: days(100)), owner: ollama, now: now) == .free)
        #expect(ReviewRules.status(for: item(owner: .ollama, lastOpened: days(2)), owner: ollama, now: now) == .recentlyUsed(app: "Ollama", date: days(2)))
    }

    @Test func groupContainerTeamPrefixIsDropped() {
        #expect(ReviewRules.bundleID(fromContainer: "ABCDE12345.com.example.app") == "com.example.app")
        #expect(ReviewRules.bundleID(fromContainer: "dev.vicaai.FlowRunner") == "dev.vicaai.FlowRunner")
    }

    @Test func highlightLightsTheCandidatesAndTheirPath() throws {
        var tree = ScanTree(rootPath: "/R", scanPath: "/R", rootName: "R", deviceID: 1, lastEventID: 1,
                            eventsUUID: "U", largeFileThreshold: 50_000_000, firmlinks: [])
        let root = tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        // Like the walker: a large file's bytes are also its folder's own bytes.
        let docs = tree.appendNode(parent: root, name: "Docs", isDirectory: true, ownBytes: 40_000_000_000, ownFiles: 1, ownModified: 0)
        let models = tree.appendNode(parent: root, name: "Models", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        let qwen = tree.appendNode(parent: models, name: "Qwen", isDirectory: true, ownBytes: 30_000_000_000, ownFiles: 1, ownModified: 0)
        _ = tree.appendNode(parent: qwen, name: "a.safetensors", isDirectory: false, ownBytes: 30_000_000_000, ownFiles: 1, ownModified: 0)
        _ = tree.appendNode(parent: docs, name: "big.pdf", isDirectory: false, ownBytes: 40_000_000_000, ownFiles: 1, ownModified: 0)
        tree.finalize()
        let qwenID = NodeID(raw: qwen), docsID = NodeID(raw: docs), modelsID = NodeID(raw: models)

        let h = MapHighlight(items: [item(owner: .none, nodes: [qwenID])], tree: tree)
        #expect(h.candidates == [qwenID])
        #expect(h.lit.contains(modelsID) && h.lit.contains(tree.root))
        #expect(!h.lit.contains(docsID))

        let projection = MapPresentation(tree: tree, root: tree.root)
        #expect(projection.entries.first { $0.item == .node(modelsID) }?.children.contains { $0.item == .node(qwenID) } == true)
        #expect(!h.lit.contains(docsID))
        let child = try #require(tree.lookup(path: "/R/Models/Qwen/a.safetensors"))
        #expect(h.isInsideCandidate(child, tree: tree))
    }
}

@Suite("Map colours")
struct MapColorTests {
    @Test func foldersTakeTheKindThatFillsThem() {
        var tree = ScanTree(rootPath: "/R", scanPath: "/R", rootName: "R", deviceID: 1, lastEventID: 1,
                            eventsUUID: "U", largeFileThreshold: 50_000_000, firmlinks: [])
        let gb: Int64 = 1_000_000_000
        let root = tree.appendNode(parent: -1, name: "", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        let home = tree.appendNode(parent: root, name: "u", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        // Like the walker: a large file's bytes are also its folder's own bytes.
        let movies = tree.appendNode(parent: home, name: "Movies", isDirectory: true, ownBytes: 9 * gb, ownFiles: 2, ownModified: 0)
        let a = tree.appendNode(parent: movies, name: "a.mov", isDirectory: false, ownBytes: 5 * gb, ownFiles: 1, ownModified: 0)
        _ = tree.appendNode(parent: movies, name: "b.mp4", isDirectory: false, ownBytes: 4 * gb, ownFiles: 1, ownModified: 0)
        let mixed = tree.appendNode(parent: home, name: "Mixed", isDirectory: true, ownBytes: 4 * gb, ownFiles: 2, ownModified: 0)
        _ = tree.appendNode(parent: mixed, name: "c.zip", isDirectory: false, ownBytes: 2 * gb, ownFiles: 1, ownModified: 0)
        _ = tree.appendNode(parent: mixed, name: "d.pdf", isDirectory: false, ownBytes: 2 * gb, ownFiles: 1, ownModified: 0)
        let ollama = tree.appendNode(parent: home, name: ".ollama", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        let models = tree.appendNode(parent: ollama, name: "models", isDirectory: true, ownBytes: 0, ownFiles: 0, ownModified: 0)
        let blobs = tree.appendNode(parent: models, name: "blobs", isDirectory: true, ownBytes: 3 * gb, ownFiles: 1, ownModified: 0)
        let blob = tree.appendNode(parent: blobs, name: "sha256-abc", isDirectory: false, ownBytes: 3 * gb, ownFiles: 1, ownModified: 0)
        tree.finalize()

        let shares = KindShares(tree: tree, home: "/R/u")
        #expect(shares.group(of: NodeID(raw: a), in: tree) == .media)
        #expect(shares.group(of: NodeID(raw: movies), in: tree) == .media)
        #expect(shares.group(of: NodeID(raw: mixed), in: tree) == nil)
        #expect(shares.group(of: NodeID(raw: blob), in: tree) == .model)
        #expect(shares.total(.media) == 9 * gb)
        #expect(shares.total(.document) == 2 * gb)
    }
}
