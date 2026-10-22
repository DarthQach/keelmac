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

        let tiles = TreemapView.layout(tree: tree, root: tree.root, in: CGRect(x: 0, y: 0, width: 1000, height: 700), highlight: h)
        #expect(tiles.first { $0.name.hasSuffix("Qwen") }?.role == .candidate)
        #expect(tiles.first { $0.name == "Docs" }?.role == .dimmed)
        #expect(tiles.first { $0.name == "a.safetensors" }?.role == .insideCandidate)
    }
}
