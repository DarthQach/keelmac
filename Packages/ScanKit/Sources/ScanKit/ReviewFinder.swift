import Foundation

/// What a large file is, decided by its extension.
public enum FileKind: String, Sendable, CaseIterable {
    case document, video, audio, image
    /// Archives and disk images.
    case archive
    case aiModel, virtualMachine, other

    public static func of(path: String) -> FileKind {
        byExtension[(path as NSString).pathExtension.lowercased()] ?? .other
    }

    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ list: String) { for e in list.split(separator: " ") { map[String(e)] = kind } }
        add(.document, "pdf doc docx ppt pptx xls xlsx key pages numbers psd psb ai indd sketch fig epub csv txt rtf")
        add(.video, "mp4 mov m4v mkv avi wmv webm mts m2ts mxf braw r3d insv lrv 360")
        add(.audio, "mp3 wav aif aiff flac m4a aac ogg caf")
        add(.image, "jpg jpeg png heic tif tiff dng cr2 cr3 nef arw raf orf rw2 exr")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst dmg iso img pkg mpkg xip sparseimage")
        add(.aiModel, "gguf ggml safetensors onnx pt pth ckpt mlmodel tflite")
        add(.virtualMachine, "vmdk vdi qcow2 vhd vhdx hdd")
        return map
    }()
}

/// Who a review item belongs to, read from where it lives.
public enum ReviewOwner: Sendable, Hashable {
    case ollama, lmStudio, huggingFace
    /// Inside `~/Library/Containers/<bundleID>` or `~/Library/Group Containers/<id>`.
    case app(bundleID: String)
    /// Inside `~/Library/Application Support/<folder>`.
    case appSupport(folder: String)
    case none
}

/// How an item is removed.
public enum ReviewRemoval: Sendable, Hashable {
    /// Move these paths to the Trash.
    case trash([String])
    /// `ollama rm <model>`, which keeps Ollama's own index valid.
    case ollamaRemove(model: String)
}

/// One deletion candidate: a large file, or a whole AI model.
public struct ReviewItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// What Reveal in Finder shows.
    public let path: String
    public let kind: FileKind
    public let bytes: Int64
    /// Tree nodes the item covers (for highlighting the map).
    public let nodes: [NodeID]
    /// Latest last-opened date over the item's files.
    public let lastOpened: Date?
    public let owner: ReviewOwner
    public let removal: ReviewRemoval

    public init(id: String, name: String, path: String, kind: FileKind, bytes: Int64, nodes: [NodeID],
                lastOpened: Date?, owner: ReviewOwner, removal: ReviewRemoval) {
        self.id = id; self.name = name; self.path = path; self.kind = kind; self.bytes = bytes
        self.nodes = nodes; self.lastOpened = lastOpened; self.owner = owner; self.removal = removal
    }
}

/// Finds large files and AI models in the user's home that are worth reviewing for deletion.
public enum ReviewFinder {
    /// Folders inside these packages are never offered: removing a file inside them breaks the package.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "imovielibrary", "fcpbundle", "tvlibrary", "logicx",
        "framework", "bundle", "xcarchive", "sparsebundle", "utm",
    ]

    /// Folders that hold one model per subfolder, `depth` levels below the root.
    struct ModelRoot { let relative: String; let depth: Int; let owner: ReviewOwner }
    static let modelRoots = [
        ModelRoot(relative: ".lmstudio/models", depth: 2, owner: .lmStudio),
        ModelRoot(relative: ".cache/lm-studio/models", depth: 2, owner: .lmStudio),
        ModelRoot(relative: ".cache/huggingface/hub", depth: 1, owner: .huggingFace),
    ]

    /// Large files and AI models under `home`, largest first.
    /// - Parameters:
    ///   - minBytes: smallest item to return. Only files ≥ `tree.largeFileThreshold` are tree nodes.
    ///   - notOpenedSince: keep only items last opened (or, when unknown, modified) before this date.
    ///   - lastOpened: last-opened lookup; `LargeFileFinder.spotlightLastOpened` in the app, a fake in tests.
    public static func find(in tree: ScanTree, home: String, minBytes: Int64, notOpenedSince: Date?,
                            lastOpened: (String) -> Date?) -> [ReviewItem] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        var items = ollamaModels(in: tree, home: home, lastOpened: lastOpened)
        var groups: [String: (owner: ReviewOwner, files: [NodeID])] = [:]
        var looseModels: [String: [NodeID]] = [:]

        for id in tree.largeFileNodes {
            let path = tree.path(of: id)
            guard let rel = relative(path, to: home), !isSkipped(rel) else { continue }
            if rel.hasPrefix(".ollama/models/") { continue }
            if let root = modelRoots.first(where: { rel.hasPrefix($0.relative + "/") }) {
                let rest = rel.dropFirst(root.relative.count + 1).split(separator: "/")
                guard rest.count > root.depth else { continue }
                let key = home + "/" + root.relative + "/" + rest.prefix(root.depth).joined(separator: "/")
                groups[key, default: (root.owner, [])].files.append(id)
                continue
            }
            let kind = FileKind.of(path: path)
            if kind == .aiModel {
                looseModels[(path as NSString).deletingLastPathComponent, default: []].append(id)
                continue
            }
            let bytes = tree.bytes(of: id)
            guard bytes >= minBytes else { continue }
            items.append(ReviewItem(id: path, name: tree.name(of: id), path: path, kind: kind, bytes: bytes, nodes: [id],
                                    lastOpened: lastOpened(path), owner: owner(ofRelative: rel), removal: .trash([path])))
        }

        // A model folder (LM Studio, Hugging Face) is removed as a whole.
        for (folder, group) in groups {
            guard let node = tree.lookup(path: folder) else { continue }
            let name = group.owner == .huggingFace ? huggingFaceName(folder) : relative(folder, to: home).map { $0.split(separator: "/").suffix(2).joined(separator: "/") } ?? folder
            items.append(ReviewItem(id: folder, name: name, path: folder, kind: .aiModel, bytes: tree.bytes(of: node),
                                    nodes: [node] + group.files, lastOpened: latest(group.files, tree, lastOpened), owner: group.owner,
                                    removal: .trash([folder])))
        }

        // Model files elsewhere: the folder when it holds little else, otherwise just the model files.
        for (folder, files) in looseModels {
            let modelBytes = files.reduce(Int64(0)) { $0 + tree.bytes(of: $1) }
            let owner = relative(folder, to: home).map(owner(ofRelative:)) ?? .none
            let opened = latest(files, tree, lastOpened)
            if let node = tree.lookup(path: folder), Double(tree.bytes(of: node)) <= Double(modelBytes) * 1.05,
               relative(folder, to: home).map(isOwnFolder) == true {
                items.append(ReviewItem(id: folder, name: tree.name(of: node), path: folder, kind: .aiModel, bytes: tree.bytes(of: node),
                                        nodes: [node] + files, lastOpened: opened, owner: owner, removal: .trash([folder])))
            } else {
                let paths = files.map { tree.path(of: $0) }
                let name = files.count == 1 ? tree.name(of: files[0]) : (folder as NSString).lastPathComponent
                items.append(ReviewItem(id: paths.sorted().joined(separator: "\n"), name: name, path: paths[0], kind: .aiModel,
                                        bytes: modelBytes, nodes: files, lastOpened: opened, owner: owner, removal: .trash(paths)))
            }
        }

        return items
            .filter { $0.bytes >= minBytes }
            .filter { item in
                guard let cutoff = notOpenedSince else { return true }
                let fallback = item.nodes.first.map { tree.info($0).modified }
                return (item.lastOpened ?? fallback ?? .distantPast) < cutoff
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
    }

    public static func find(in tree: ScanTree, home: String, minBytes: Int64, notOpenedSince: Date?) -> [ReviewItem] {
        find(in: tree, home: home, minBytes: minBytes, notOpenedSince: notOpenedSince, lastOpened: LargeFileFinder.spotlightLastOpened)
    }

    /// Whether `path` is inside Ollama, LM Studio or Hugging Face model storage, where files have no telling extension.
    public static func isModelStorage(_ path: String, home: String) -> Bool {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard let rel = relative(path, to: home) else { return false }
        return rel.hasPrefix(".ollama/models/") || modelRoots.contains { rel.hasPrefix($0.relative + "/") }
    }

    // MARK: Ollama

    struct OllamaManifest: Decodable {
        struct Layer: Decodable { let digest: String; let size: Int64 }
        let config: Layer?
        let layers: [Layer]
    }

    /// One item per `~/.ollama/models/manifests/<host>/<namespace>/<model>/<tag>`. The size counts only
    /// blobs no other model uses, since `ollama rm` keeps shared ones.
    static func ollamaModels(in tree: ScanTree, home: String, lastOpened: (String) -> Date?) -> [ReviewItem] {
        let base = home + "/.ollama/models"
        let manifests = base + "/manifests"
        guard let rels = FileManager.default.enumerator(atPath: manifests)?.allObjects as? [String] else { return [] }
        var parsed: [(name: String, path: String, layers: [OllamaManifest.Layer])] = []
        for rel in rels.sorted() {
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count == 4, !parts.contains(where: { $0.hasPrefix(".") }),
                  let data = FileManager.default.contents(atPath: manifests + "/" + rel),
                  let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data) else { continue }
            let (host, namespace, model, tag) = (parts[0], parts[1], parts[2], parts[3])
            let name = host == "registry.ollama.ai"
                ? (namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)")
                : "\(host)/\(namespace)/\(model):\(tag)"
            parsed.append((name, manifests + "/" + rel, manifest.layers + (manifest.config.map { [$0] } ?? [])))
        }
        var uses: [String: Int] = [:]
        for m in parsed { for d in Set(m.layers.map(\.digest)) { uses[d, default: 0] += 1 } }
        return parsed.map { m in
            var seen = Set<String>()
            let unique = m.layers.filter { uses[$0.digest] == 1 && seen.insert($0.digest).inserted }
            let blobPath = { (l: OllamaManifest.Layer) in base + "/blobs/" + l.digest.replacingOccurrences(of: ":", with: "-") }
            let largest = m.layers.max { $0.size < $1.size }
            return ReviewItem(id: "ollama:" + m.name, name: m.name, path: m.path, kind: .aiModel,
                              bytes: unique.reduce(0) { $0 + $1.size },
                              nodes: m.layers.compactMap { tree.lookup(path: blobPath($0)) },
                              lastOpened: largest.flatMap { lastOpened(blobPath($0)) }, owner: .ollama, removal: .ollamaRemove(model: m.name))
        }
    }

    // MARK: Paths

    static func relative(_ path: String, to home: String) -> String? {
        path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
    }

    /// The Trash, Mail, Messages, Apple's own app data and anything inside a package.
    static func isSkipped(_ rel: String) -> Bool {
        if rel.hasPrefix(".Trash/") || rel.hasPrefix("Library/Mail/") || rel.hasPrefix("Library/Messages/")
            || rel.hasPrefix("Library/Containers/com.apple.") { return true }
        if rel.hasPrefix("Library/Group Containers/"), rel.split(separator: "/").dropFirst(2).first?.contains("com.apple") == true { return true }
        // The folder right under (Group) Containers is a bundle id such as `dev.example.App`, not a package.
        let parts = rel.split(separator: "/").map(String.init)
        let containerName = parts.count > 2 && parts[0] == "Library" && (parts[1] == "Containers" || parts[1] == "Group Containers") ? 2 : -1
        return parts.dropLast().enumerated().contains { i, part in
            i != containerName && packageExtensions.contains((part as NSString).pathExtension.lowercased())
        }
    }

    static func owner(ofRelative rel: String) -> ReviewOwner {
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count > 2, parts[0] == "Library" else { return .none }
        switch parts[1] {
        case "Containers": return .app(bundleID: parts[2])
        case "Group Containers":
            let id = parts[2]
            return .app(bundleID: id.hasPrefix("group.") ? String(id.dropFirst(6)) : id)
        case "Application Support": return .appSupport(folder: parts[2])
        default: return .none
        }
    }

    /// A folder deep enough to be the model's own (not `~`, `~/Downloads` or a container's top level).
    static func isOwnFolder(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/")
        if parts.first == "Library" { return parts.count >= 4 }
        return parts.count >= 2
    }

    static func huggingFaceName(_ folder: String) -> String {
        let last = (folder as NSString).lastPathComponent
        let parts = last.components(separatedBy: "--")
        return parts.count >= 3 ? parts.dropFirst().joined(separator: "/") : last
    }

    static func latest(_ files: [NodeID], _ tree: ScanTree, _ lastOpened: (String) -> Date?) -> Date? {
        files.compactMap { lastOpened(tree.path(of: $0)) }.max()
    }
}
