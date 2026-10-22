import Foundation
import Testing
@testable import ScanKit

@Suite("Review finder")
struct ReviewFinderTests {
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    let recent = Date()
    let gb: Int64 = 1_000_000_000

    @Test func kindsComeFromExtensions() {
        #expect(FileKind.of(path: "/a/Report.PDF") == .document)
        #expect(FileKind.of(path: "/a/DJI_0001.MP4") == .video)
        #expect(FileKind.of(path: "/a/Entregables.zip") == .archive)
        #expect(FileKind.of(path: "/a/Xcode.xip") == .archive)
        #expect(FileKind.of(path: "/a/qwen.gguf") == .aiModel)
        #expect(FileKind.of(path: "/a/disk.qcow2") == .virtualMachine)
        #expect(FileKind.of(path: "/a/data.img") == .archive)
        #expect(FileKind.of(path: "/a/blob") == .other)
    }

    @Test func filesAreClassifiedOwnedAndFilteredByLastOpened() {
        let tree = makeTree(rootPath: "/R", [
            ("u", true, 0, 0, old),
            ("u/Documents", true, 0, 0, old),
            ("u/Documents/old.mov", false, 3 * gb, 1, old),
            ("u/Documents/fresh.zip", false, 2 * gb, 1, old),
            ("u/Library", true, 0, 0, old),
            ("u/Library/Containers", true, 0, 0, old),
            ("u/Library/Containers/dev.example.App", true, 0, 0, old),
            ("u/Library/Containers/dev.example.App/data.bin", false, gb, 1, old),
            ("u/.Trash", true, 0, 0, old),
            ("u/.Trash/gone.mov", false, 5 * gb, 1, old),
            ("u/Pictures", true, 0, 0, old),
            ("u/Pictures/Photos Library.photoslibrary", true, 0, 0, old),
            ("u/Pictures/Photos Library.photoslibrary/originals.heic", false, 4 * gb, 1, old),
            ("other", true, 0, 0, old),
            ("other/outside.mov", false, 6 * gb, 1, old),
        ])
        let opened: (String) -> Date? = { $0.hasSuffix("fresh.zip") ? self.recent : self.old }
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date())
        let items = ReviewFinder.find(in: tree, home: "/R/u", minBytes: 500_000_000, notOpenedSince: cutoff, lastOpened: opened)
        #expect(items.map(\.name) == ["old.mov", "data.bin"])
        #expect(items[0].kind == .video)
        #expect(items[0].removal == .trash(["/R/u/Documents/old.mov"]))
        #expect(items[1].owner == .app(bundleID: "dev.example.App"))

        let all = ReviewFinder.find(in: tree, home: "/R/u", minBytes: 500_000_000, notOpenedSince: nil, lastOpened: opened)
        #expect(all.map(\.name) == ["old.mov", "fresh.zip", "data.bin"])
    }

    @Test func modelFoldersBecomeOneItemEach() {
        let tree = makeTree(rootPath: "/R", [
            ("u", true, 0, 0, old),
            ("u/.lmstudio", true, 0, 0, old),
            ("u/.lmstudio/models", true, 0, 0, old),
            ("u/.lmstudio/models/lmstudio-community", true, 0, 0, old),
            ("u/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF", true, 1_000_000, 2, old),
            ("u/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/q4.gguf", false, 5 * gb, 1, old),
            ("u/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/q8.gguf", false, 8 * gb, 1, old),
            ("u/.cache", true, 0, 0, old),
            ("u/.cache/huggingface", true, 0, 0, old),
            ("u/.cache/huggingface/hub", true, 0, 0, old),
            ("u/.cache/huggingface/hub/models--mistralai--Mistral-7B", true, 0, 0, old),
            ("u/.cache/huggingface/hub/models--mistralai--Mistral-7B/blobs", true, 0, 0, old),
            ("u/.cache/huggingface/hub/models--mistralai--Mistral-7B/blobs/ab12", false, 4 * gb, 1, old),
            ("u/Library", true, 0, 0, old),
            ("u/Library/Containers", true, 0, 0, old),
            ("u/Library/Containers/dev.vicaai.FlowRunner", true, 0, 0, old),
            ("u/Library/Containers/dev.vicaai.FlowRunner/Data", true, 0, 0, old),
            ("u/Library/Containers/dev.vicaai.FlowRunner/Data/Qwen2.5-32B", true, 10_000, 3, old),
            ("u/Library/Containers/dev.vicaai.FlowRunner/Data/Qwen2.5-32B/model-1.safetensors", false, 9 * gb, 1, old),
            ("u/Library/Containers/dev.vicaai.FlowRunner/Data/Qwen2.5-32B/model-2.safetensors", false, 9 * gb, 1, old),
            ("u/Downloads", true, 0, 0, old),
            ("u/Downloads/movie.mp4", false, 20 * gb, 1, old),
            ("u/Downloads/llama.gguf", false, 2 * gb, 1, old),
        ])
        let items = ReviewFinder.find(in: tree, home: "/R/u", minBytes: 100_000_000, notOpenedSince: nil, lastOpened: { _ in self.old })
        let models = items.filter { $0.kind == .aiModel }
        #expect(models.count == 4)

        let flow = models.first { $0.owner == .app(bundleID: "dev.vicaai.FlowRunner") }
        #expect(flow?.name == "Qwen2.5-32B")
        #expect(flow?.removal == .trash(["/R/u/Library/Containers/dev.vicaai.FlowRunner/Data/Qwen2.5-32B"]))

        let lm = models.first { $0.owner == .lmStudio }
        #expect(lm?.name == "lmstudio-community/Qwen3-8B-GGUF")
        #expect(lm?.bytes == 13 * gb + 1_000_000)

        #expect(models.first { $0.owner == .huggingFace }?.name == "mistralai/Mistral-7B")

        // A model file in Downloads is offered on its own, never the whole Downloads folder.
        let loose = models.first { $0.name == "llama.gguf" }
        #expect(loose?.removal == .trash(["/R/u/Downloads/llama.gguf"]))
        #expect(loose?.bytes == 2 * gb)
    }

    @Test func ollamaModelsReadTheirManifestsAndCountSharedBlobsOnce() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        func manifest(_ rel: String, _ layers: [(String, Int64)]) throws {
            let body = layers.map { #"{"digest":"sha256:\#($0.0)","size":\#($0.1)}"# }.joined(separator: ",")
            try fx.dir(("u/.ollama/models/manifests/" + rel as NSString).deletingLastPathComponent)
            try Data(#"{"config":{"digest":"sha256:cfg","size":100},"layers":[\#(body)]}"#.utf8)
                .write(to: URL(fileURLWithPath: fx.path("u/.ollama/models/manifests/" + rel)))
        }
        try manifest("registry.ollama.ai/library/qwen3/8b", [("aaa", 5 * gb), ("shared", gb)])
        try manifest("registry.ollama.ai/library/qwen3/14b", [("bbb", 9 * gb), ("shared", gb)])
        try manifest("registry.ollama.ai/someone/tiny/latest", [("ccc", 2 * gb)])

        let tree = makeTree(rootPath: fx.root, [
            ("u", true, 0, 0, old),
            ("u/.ollama", true, 0, 0, old),
            ("u/.ollama/models", true, 0, 0, old),
            ("u/.ollama/models/blobs", true, 0, 0, old),
            ("u/.ollama/models/blobs/sha256-aaa", false, 5 * gb, 1, old),
            ("u/.ollama/models/blobs/sha256-bbb", false, 9 * gb, 1, old),
            ("u/.ollama/models/blobs/sha256-shared", false, gb, 1, old),
        ])
        let items = ReviewFinder.find(in: tree, home: fx.path("u"), minBytes: 100_000_000, notOpenedSince: nil, lastOpened: { _ in self.old })
        #expect(items.map(\.name) == ["qwen3:14b", "qwen3:8b", "someone/tiny:latest"])
        #expect(items[0].bytes == 9 * gb)  // "shared" and the config blob are used by other models too
        #expect(items[1].bytes == 5 * gb)
        #expect(items[0].removal == .ollamaRemove(model: "qwen3:14b"))
        #expect(items[0].owner == .ollama)
        #expect(items[0].nodes.count == 2)
        // Blobs are never offered as loose files.
        #expect(!items.contains { $0.name.hasPrefix("sha256-") })
    }
}
