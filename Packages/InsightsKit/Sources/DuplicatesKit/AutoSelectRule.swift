import Foundation

/// Picks which copies in a group to remove. Every rule keeps exactly one file per group
/// (none are removed from a group with fewer than two files), and ties are broken by path
/// so the same group always yields the same selection.
public enum AutoSelectRule: Sendable, Hashable, Codable {
    /// Keep the most recently modified copy.
    case newest
    /// Keep the oldest modified copy.
    case oldest
    /// Keep a copy inside this folder (the newest one there if several); when none is inside it, keep the newest.
    case preferredFolder(String)

    /// The file this rule keeps, or nil for an empty group.
    public func fileToKeep(in group: DuplicateGroup) -> DuplicateFile? {
        let files = group.files
        guard !files.isEmpty else { return nil }
        switch self {
        case .newest:
            return Self.newest(of: files)
        case .oldest:
            return files.min { a, b in a.modified != b.modified ? a.modified < b.modified : a.path < b.path }
        case .preferredFolder(let folder):
            let root = Self.normalizedFolder(folder)
            let inside = files.filter { Self.isWithin($0.path, root) }
            return Self.newest(of: inside.isEmpty ? files : inside)
        }
    }

    /// Every file except the one this rule keeps, sorted by path.
    public func filesToRemove(in group: DuplicateGroup) -> [DuplicateFile] {
        guard group.files.count > 1, let keep = fileToKeep(in: group) else { return [] }
        var removedKeep = false
        var out: [DuplicateFile] = []
        for file in group.files.sorted(by: { $0.path < $1.path }) {
            if !removedKeep && file == keep { removedKeep = true; continue }
            out.append(file)
        }
        return out
    }

    private static func newest(of files: [DuplicateFile]) -> DuplicateFile? {
        // Newest date wins; on equal dates the lexicographically smallest path wins.
        files.min { a, b in a.modified != b.modified ? a.modified > b.modified : a.path < b.path }
    }

    private static func normalizedFolder(_ folder: String) -> String {
        var f = folder
        while f.count > 1 && f.hasSuffix("/") { f.removeLast() }
        return f
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }
}
