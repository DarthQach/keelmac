import Foundation

/// `git status --porcelain=v2 --branch --show-stash --ignored`, summarized.
public struct StatusSummary: Sendable, Equatable {
    public var headSHA: String?
    public var headBranch: String?
    public var isDetached = false
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var stashCount = 0
    /// Changed (1), renamed (2) and conflicted (u) entries.
    public var changedCount = 0
    public var untrackedCount = 0
    public var ignored: [String] = []

    public var uncommittedCount: Int { changedCount + untrackedCount }
}

public struct RefList: Sendable, Equatable {
    public var branches: [BranchInfo] = []
    public var tags: [TagInfo] = []
}

/// Parsers for git's machine-readable output. Pure functions, tested with fixture strings.
public enum GitParsers {
    public static func status(_ output: String) -> StatusSummary {
        var s = StatusSummary()
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": s.headSHA = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head":
                    if parts[1] == "(detached)" { s.isDetached = true } else { s.headBranch = parts[1] }
                case "branch.upstream": s.upstream = parts[1]
                case "branch.ab":
                    for token in parts[1].split(separator: " ") {
                        if token.hasPrefix("+") { s.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { s.behind = Int(token.dropFirst()) ?? 0 }
                    }
                case "stash": s.stashCount = Int(parts[1]) ?? 0
                default: break
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                s.changedCount += 1
            } else if line.hasPrefix("? ") {
                s.untrackedCount += 1
            } else if line.hasPrefix("! ") {
                s.ignored.append(String(line.dropFirst(2)))
            }
        }
        if s.isDetached { s.headBranch = nil }
        return s
    }

    /// `git for-each-ref --format=%(refname)%09%(objectname)%09%(upstream:short)%09%(upstream:track) refs/heads refs/tags`
    public static func refs(_ output: String) -> RefList {
        var list = RefList()
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let ref = fields[0], sha = fields[1]
            if ref.hasPrefix("refs/heads/") {
                let upstream = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
                let track = fields.count > 3 ? fields[3] : ""
                let (ahead, behind, gone) = parseTrack(track)
                list.branches.append(BranchInfo(name: String(ref.dropFirst("refs/heads/".count)), sha: sha, upstream: upstream,
                                                ahead: ahead, behind: behind, upstreamGone: gone))
            } else if ref.hasPrefix("refs/tags/") {
                list.tags.append(TagInfo(name: String(ref.dropFirst("refs/tags/".count)), sha: sha))
            }
        }
        return list
    }

    /// "[ahead 1, behind 2]", "[ahead 1]", "[behind 2]", "[gone]" or "".
    static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let inner = track.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if inner == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in inner.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = n }
            if words[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }

    /// `git remote -v`: one entry per remote, from its fetch line.
    public static func remotes(_ output: String) -> [RemoteInfo] {
        var out: [RemoteInfo] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[1].hasSuffix(" (fetch)") else { continue }
            let url = String(fields[1].dropLast(" (fetch)".count))
            guard !out.contains(where: { $0.name == fields[0] }) else { continue }
            out.append(RemoteInfo(name: fields[0], url: url, ownerRepo: ownerRepo(fromURL: url)))
        }
        return out
    }

    /// "owner/name" for github.com URLs in https, ssh, scp-like and git forms; nil for anything else.
    public static func ownerRepo(fromURL url: String) -> String? {
        var rest: Substring
        let lower = url.lowercased()
        if let range = lower.range(of: "://") {
            // scheme://[user@]host[:port]/owner/name
            var afterScheme = url[range.upperBound...]
            if let at = afterScheme.firstIndex(of: "@"), afterScheme[..<at].firstIndex(of: "/") == nil {
                afterScheme = afterScheme[afterScheme.index(after: at)...]
            }
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            var host = afterScheme[..<slash].lowercased()
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            guard host == "github.com" || host == "www.github.com" else { return nil }
            rest = afterScheme[afterScheme.index(after: slash)...]
        } else if let colon = url.firstIndex(of: ":") {
            // [user@]github.com:owner/name
            var host = url[..<colon].lowercased()
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            guard host == "github.com" else { return nil }
            rest = url[url.index(after: colon)...]
        } else {
            return nil
        }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0] + "/" + parts[1]
    }

    /// `git log -1 --format=%ct`: seconds since 1970.
    public static func commitDate(_ output: String) -> Date? {
        guard let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `git ls-remote --heads --tags`: name to object id. Peeled tag lines (`^{}`) are left out.
    public static func lsRemote(_ output: String) -> (heads: [String: String], tags: [String: String]) {
        var heads: [String: String] = [:], tags: [String: String] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let (sha, ref) = (fields[0], fields[1])
            if ref.hasPrefix("refs/heads/") { heads[String(ref.dropFirst("refs/heads/".count))] = sha }
            if ref.hasPrefix("refs/tags/"), !ref.hasSuffix("^{}") { tags[String(ref.dropFirst("refs/tags/".count))] = sha }
        }
        return (heads, tags)
    }
}

/// Parsers for gh output.
public enum GitHubParsers {
    /// `gh api user --jq .login`
    public static func login(fromAPI output: String) -> String? {
        let login = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty || login.contains(" ") ? nil : login
    }

    /// `gh repo view` reports a missing repository this way (exit 1).
    public static func isRepoNotFound(_ stderr: String) -> Bool {
        stderr.contains("Could not resolve to a Repository")
    }

    /// `gh repo create` when the name is taken.
    public static func isNameTaken(_ stderr: String) -> Bool {
        stderr.contains("Name already exists on this account") || stderr.contains("name already exists")
    }

    /// The repository URL `gh repo create` prints.
    public static func repoURL(fromCreate output: String) -> URL? {
        output.split(whereSeparator: \.isWhitespace).lazy.map(String.init)
            .first { $0.hasPrefix("https://github.com/") }
            .flatMap(URL.init(string:))
    }
}
