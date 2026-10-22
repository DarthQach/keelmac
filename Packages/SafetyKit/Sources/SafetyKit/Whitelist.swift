import Foundation

/// Paths and patterns the user never wants touched. A plain path protects itself and everything below it.
/// Patterns: `*` matches within one path component, `**` matches any number of components.
public struct Whitelist: Sendable, Codable, Equatable {
    public var patterns: [String]

    public init(_ patterns: [String] = []) { self.patterns = patterns }

    public func matches(_ path: String, home: String) -> Bool {
        let target = PathGuard.normalize(path)
        for raw in patterns {
            let pattern = Whitelist.expand(raw, home: home)
            if pattern.contains("*") {
                if GlobMatcher.matchesSelfOrAncestor(pattern: pattern, path: target) { return true }
            } else if PathGuard.isWithin(target, PathGuard.normalize(pattern)) {
                return true
            }
        }
        return false
    }

    /// True when removing `path` would also remove a whitelisted entry below it.
    /// For wildcard patterns whose fixed part lies above `path`, the folder is searched (bounded);
    /// if the search can't finish, the answer is conservatively true.
    public func isAncestorOfEntry(_ path: String, home: String, searchLimit: Int = 20_000) -> Bool {
        let target = PathGuard.normalize(path)
        for raw in patterns {
            let pattern = PathGuard.normalize(Whitelist.expand(raw, home: home))
            let literal = pattern.split(separator: "/").prefix { !$0.contains("*") }.joined(separator: "/")
            let prefix = PathGuard.normalize("/" + literal)
            if prefix != target && PathGuard.isWithin(prefix, target) { return true }
            guard pattern.contains("*"), PathGuard.isWithin(target, prefix) else { continue }
            if Whitelist.directory(target, containsMatchFor: pattern, limit: searchLimit) { return true }
        }
        return false
    }

    static func directory(_ dir: String, containsMatchFor pattern: String, limit: Int) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let e = FileManager.default.enumerator(atPath: dir) else { return true }
        var seen = 0
        while let rel = e.nextObject() as? String {
            seen += 1
            if seen > limit { return true }
            if GlobMatcher.matches(pattern: pattern, path: dir + "/" + rel) { return true }
        }
        return false
    }

    static func expand(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        return pattern
    }

    /// Checks a whitelist entry the user typed. Returns nil when it's fine.
    public static func validate(_ entry: String, home: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WhitelistProblem? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if !(trimmed.hasPrefix("/") || trimmed.hasPrefix("~")) { return .notAbsolute }
        if trimmed.contains("*") { return nil }
        if !fileExists(expand(trimmed, home: home)) { return .doesNotExist }
        return nil
    }
}

public enum WhitelistProblem: String, Sendable, Equatable {
    case empty, notAbsolute, doesNotExist
}

/// Path glob matching used by the whitelist and cleanup rules.
public enum GlobMatcher {
    /// Whole-path match: `*` within a component, `**` across components.
    public static func matches(pattern: String, path: String) -> Bool {
        let p = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let s = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return match(p[...], s[...])
    }

    /// True if the path or any of its ancestors matches the pattern.
    public static func matchesSelfOrAncestor(pattern: String, path: String) -> Bool {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let p = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while !components.isEmpty {
            if match(p[...], components[...]) { return true }
            components.removeLast()
        }
        return false
    }

    private static func match(_ p: ArraySlice<String>, _ s: ArraySlice<String>) -> Bool {
        guard let head = p.first else { return s.isEmpty }
        if head == "**" {
            let rest = p.dropFirst()
            var i = s.startIndex
            while true {
                if match(rest, s[i...]) { return true }
                if i == s.endIndex { return false }
                i = s.index(after: i)
            }
        }
        guard let first = s.first, componentMatches(head, first) else { return false }
        return match(p.dropFirst(), s.dropFirst())
    }

    /// `*` and `?` within one component, everything else literal.
    public static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == n[ni]) { pi += 1; ni += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = ni; pi += 1 }
            else if star != -1 { pi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
