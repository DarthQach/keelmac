import Darwin
import Foundation
import SafetyKit

/// One match of a path pattern.
struct GlobMatch: Sendable, Hashable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let modified: Date
    /// Allocated bytes of the entry itself (files); folders are measured separately.
    let ownBytes: Int64
}

/// Expands rule patterns. `*` and `?` match within one path component (dot files included); there is
/// no `**`. Only components with wildcards are listed; fixed components are checked with lstat. Nothing
/// below a symlink is ever followed: a symlink can be a final match (removing it removes the link) but
/// never a folder the expansion walks through.
enum GlobExpander {
    struct Result: Sendable {
        var matches: [GlobMatch] = []
        var unreadable = 0
    }

    static func hasWildcard(_ s: some StringProtocol) -> Bool { s.contains("*") || s.contains("?") }

    static func expand(_ pattern: String) -> Result {
        var result = Result()
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pattern.hasPrefix("/"), !components.isEmpty else { return result }
        var prefixes = [""]   // "" = the root folder "/"
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            var next: [String] = []
            for prefix in prefixes {
                let names: [String]
                if hasWildcard(component) {
                    guard let listed = try? FileManager.default.contentsOfDirectory(atPath: prefix.isEmpty ? "/" : prefix) else {
                        result.unreadable += 1
                        continue
                    }
                    names = listed.filter { GlobMatcher.componentMatches(component, $0) }.sorted()
                } else {
                    names = [component]
                }
                for name in names {
                    let path = prefix + "/" + name
                    var st = stat()
                    guard lstat(path, &st) == 0 else { continue }
                    let type = st.st_mode & S_IFMT
                    if isLast {
                        result.matches.append(GlobMatch(
                            path: path, isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK,
                            modified: DirectorySizer.date(st.st_mtimespec),
                            ownBytes: type == S_IFDIR ? 0 : Int64(st.st_blocks) * 512))
                    } else if type == S_IFDIR {
                        next.append(path)
                    }
                    // A symlink or file in the middle of a pattern stops the expansion there.
                }
            }
            prefixes = next
            if prefixes.isEmpty && !isLast { break }
        }
        return result
    }

    /// Lowercased components, for case-insensitive matching (APFS is usually case-insensitive,
    /// so an exclusion must not miss `com.apple.iCloud…` because the pattern says `icloud`).
    static func components(_ path: String) -> [String] {
        path.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// An exclusion pattern, matched case-insensitively.
    struct Exclusion: Sendable {
        let original: [String]
        let lower: [String]
        init(_ resolved: String) {
            original = resolved.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            lower = original.map { $0.lowercased() }
        }
    }

    /// True when `path` matches the exclusion, is inside a match, or contains a match below it.
    static func isExcluded(_ path: String, by exclusion: Exclusion) -> Bool {
        let lower = components(path)
        guard overlapsExclusion(path: lower, pattern: exclusion.lower) else { return false }
        if exclusion.lower.count <= lower.count { return true }
        // The pattern goes deeper than the item: excluded only if something below it matches.
        let rest = exclusion.original[lower.count...].joined(separator: "/")
        return !expand(path + "/" + rest).matches.isEmpty
    }

    /// True when the first components agree (the path equals, lies inside, or may contain a match).
    static func overlapsExclusion(path: [String], pattern: [String]) -> Bool {
        let n = min(path.count, pattern.count)
        for i in 0..<n where !GlobMatcher.componentMatches(pattern[i], path[i]) { return false }
        return true
    }
}
