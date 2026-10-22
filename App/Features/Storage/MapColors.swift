import Foundation
import ScanKit
import SwiftUI

/// The storage map's colour groups. Three hues plus a stripe texture for documents
/// (see `--kind-*` in design/tokens.css for why there are only three).
enum MapColorGroup: Int, CaseIterable, Sendable {
    case media, archive, model, document

    init?(_ kind: FileKind) {
        switch kind {
        case .video, .image, .audio: self = .media
        case .archive, .virtualMachine: self = .archive
        case .aiModel: self = .model
        case .document: self = .document
        case .other: return nil
        }
    }

    /// Solid fill for a file tile; nil for documents, which use stripes.
    var color: Color? {
        switch self {
        case .media: .kmKindMedia
        case .archive: .kmKindArchive
        case .model: .kmKindModel
        case .document: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .media: "Video and photos"
        case .archive: "Archives and disk images"
        case .model: "AI models"
        case .document: "Documents"
        }
    }

    /// The map Highlight that shows this group.
    var highlight: StorageMapView.HighlightMode {
        switch self {
        case .media: .video
        case .archive: .archive
        case .model: .aiModel
        case .document: .document
        }
    }
}

/// Bytes of each colour group's large files under every folder, computed once per scan.
struct KindShares: Sendable {
    /// Identifies the tree this was computed for.
    let key: String
    private var fileGroup: [NodeID: MapColorGroup] = [:]
    private var folderBytes: [NodeID: [Int64]] = [:]
    private let root: NodeID

    /// A folder takes a group's colour when that group is at least this share of it.
    static let dominantShare = 0.6

    static func key(for tree: ScanTree) -> String {
        "\(tree.scannedAt.timeIntervalSince1970)-\(tree.nodeCount)-\(tree.totalBytesOnDisk)"
    }

    init(tree: ScanTree, home: String) {
        key = Self.key(for: tree)
        root = tree.root
        for id in tree.largeFileNodes {
            let path = tree.path(of: id)
            let group = ReviewFinder.isModelStorage(path, home: home) ? .model : MapColorGroup(FileKind.of(path: path))
            guard let group else { continue }
            fileGroup[id] = group
            let bytes = tree.bytes(of: id)
            var p = tree.parent(of: id)
            while let a = p {
                folderBytes[a, default: [0, 0, 0, 0]][group.rawValue] += bytes
                p = tree.parent(of: a)
            }
        }
    }

    /// A file's own group, or the group that fills most of a folder.
    func group(of id: NodeID, in tree: ScanTree) -> MapColorGroup? {
        if let g = fileGroup[id] { return g }
        guard let shares = folderBytes[id] else { return nil }
        let total = Double(tree.bytes(of: id))
        guard total > 0 else { return nil }
        return MapColorGroup.allCases.first { Double(shares[$0.rawValue]) >= total * Self.dominantShare }
    }

    /// Bytes of a group on the whole scan.
    func total(_ group: MapColorGroup) -> Int64 { folderBytes[root]?[group.rawValue] ?? 0 }
}
