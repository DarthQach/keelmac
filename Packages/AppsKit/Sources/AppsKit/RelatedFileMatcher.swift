import Foundation
import SafetyKit

/// Finds the files an app keeps outside its bundle, for the uninstall preview.
///
/// Rules (conservative on purpose: anything wrong here moves someone's data to the Trash):
/// - By bundle id: an entry named exactly after it, or `<bundleid>.…` (extensions, helpers, ByHost plists).
/// - Group Containers and Application Scripts: names that contain the bundle id on dot boundaries
///   (`group.com.foo.app`), and `<teamID>.…` when the app has a team id.
/// - By name: only Application Support, Caches and Logs folders whose name *equals* one of the app's names
///   (display name, bundle name, file name), ignoring case. Never substrings: "Code" never matches "Xcode".
/// - The vendor folder in Application Support (`Google` for `com.google.Chrome`) is reported as shared
///   unless everything in it belongs to this app and no other installed app shares the vendor.
/// - launchd plists whose label is the bundle id or whose program lives inside the bundle.
/// - An entry another installed app claims more specifically (a longer bundle id, its own program) is left out;
///   one another app claims just as well (a second copy, a shared team group, a shared name) is `isShared`.
/// - Every path must pass `PathGuard` in the `.uninstall` context; /Library items come back with `needsHelper`.
public enum RelatedFileMatcher {
    public static func find(for app: InstalledApp, home: String, installed: [InstalledApp]) -> [RelatedFile] {
        find(for: app, home: home, installed: installed, systemLibrary: "/Library", pathGuard: nil)
    }

    /// - Parameters:
    ///   - systemLibrary: the /Library to search for helper-only items; nil skips it (tests).
    ///   - pathGuard: defaults to `PathGuard(home: home)`; pass the app's guard to honour the user's whitelist.
    public static func find(for app: InstalledApp, home: String, installed: [InstalledApp],
                            systemLibrary: String?, pathGuard: PathGuard?) -> [RelatedFile] {
        let guardian = pathGuard ?? PathGuard(home: home)
        let me = AppKey(app)
        let others = installed.filter { $0.path != app.path }.map(AppKey.init)
        let cache = LaunchdCache()
        let homeLibrary = (home as NSString).appendingPathComponent("Library")

        var candidates: [Candidate] = []
        for spec in LocationSpec.home {
            scan(spec, library: homeLibrary, me: me, others: others, cache: cache, into: &candidates)
        }
        vendorFolders(library: homeLibrary, me: me, others: others, into: &candidates)
        if let systemLibrary {
            for spec in LocationSpec.system {
                scan(spec, library: systemLibrary, me: me, others: others, cache: cache, into: &candidates)
            }
        }

        var seen = Set<String>()
        var out: [RelatedFile] = []
        for c in candidates where seen.insert(c.path).inserted {
            guard !PathGuard.isWithin(c.path, app.path) else { continue }
            let verdict = guardian.verdict(for: c.path, context: .uninstall)
            let needsHelper: Bool
            if verdict.allowed { needsHelper = false }
            else if verdict.reason == .needsHelper { needsHelper = true }
            else { continue }
            out.append(RelatedFile(path: c.path, bytes: FileSizer.allocatedSize(of: c.path), location: c.location,
                                   isShared: c.isShared, needsHelper: needsHelper,
                                   modified: FileSizer.modificationDate(of: c.path), reason: c.reason))
        }
        return out.sorted {
            if $0.needsHelper != $1.needsHelper { return !$0.needsHelper }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
    }

    // MARK: - Matching

    struct Candidate {
        let path: String
        let location: RelatedLocation
        let reason: MatchReason
        let isShared: Bool
    }

    enum Rule { case bundleID, groupContains, team, name, launchd }

    struct LocationSpec {
        let relative: String
        let location: RelatedLocation
        let rules: [Rule]

        static let home: [LocationSpec] = [
            .init(relative: "Application Support", location: .applicationSupport, rules: [.bundleID, .name]),
            .init(relative: "Caches", location: .caches, rules: [.bundleID, .name]),
            .init(relative: "Preferences", location: .preferences, rules: [.bundleID]),
            .init(relative: "Preferences/ByHost", location: .preferences, rules: [.bundleID]),
            .init(relative: "Containers", location: .containers, rules: [.bundleID]),
            .init(relative: "Group Containers", location: .groupContainers, rules: [.groupContains, .team]),
            .init(relative: "Saved Application State", location: .savedState, rules: [.bundleID]),
            .init(relative: "Logs", location: .logs, rules: [.bundleID, .name]),
            .init(relative: "LaunchAgents", location: .launchAgents, rules: [.bundleID, .launchd]),
            .init(relative: "Cookies", location: .cookies, rules: [.bundleID]),
            .init(relative: "HTTPStorages", location: .httpStorages, rules: [.bundleID]),
            .init(relative: "WebKit", location: .webKit, rules: [.bundleID]),
            .init(relative: "Application Scripts", location: .applicationScripts, rules: [.groupContains, .team]),
        ]

        static let system: [LocationSpec] = [
            .init(relative: "Application Support", location: .applicationSupport, rules: [.bundleID, .name]),
            .init(relative: "Caches", location: .caches, rules: [.bundleID]),
            .init(relative: "Preferences", location: .preferences, rules: [.bundleID]),
            .init(relative: "Logs", location: .logs, rules: [.bundleID, .name]),
            .init(relative: "LaunchAgents", location: .launchAgents, rules: [.bundleID, .launchd]),
            .init(relative: "LaunchDaemons", location: .launchDaemons, rules: [.bundleID, .launchd]),
            .init(relative: "PrivilegedHelperTools", location: .privilegedHelperTools, rules: [.bundleID]),
        ]
    }

    /// What we know about an app for matching.
    struct AppKey {
        let path: String
        let bundleID: String?
        let teamID: String?
        let names: Set<String>          // lowercased, generic names removed
        let vendorKey: String?
        let vendorName: String?

        init(_ app: InstalledApp) {
            path = app.path
            bundleID = app.bundleID
            teamID = app.teamID
            var n: Set<String> = [app.name, BundleReader.stem(of: app.path)]
            if let info = BundleReader.read(bundle: app.path) {
                if let d = info.displayName { n.insert(d) }
                if let b = info.bundleName { n.insert(b) }
            }
            names = Set(n.map { $0.lowercased() }.filter { $0.count >= 3 && !Identifiers.genericNames.contains($0) })
            vendorKey = app.bundleID.flatMap(Identifiers.vendorKey)
            vendorName = app.bundleID.flatMap(Identifiers.vendorName)
        }
    }

    /// How strongly an app claims an entry. Higher wins; equal claims are shared.
    struct Claim: Comparable {
        let reason: MatchReason
        let rank: Int
        let specificity: Int
        static func < (a: Claim, b: Claim) -> Bool { (a.rank, a.specificity) < (b.rank, b.specificity) }
    }

    final class LaunchdCache {
        private var plists: [String: LaunchdPlist?] = [:]
        func plist(_ path: String) -> LaunchdPlist? {
            if let hit = plists[path] { return hit }
            let parsed = LaunchdPlist.read(path)
            plists[path] = parsed
            return parsed
        }
    }

    static let knownExtensions = [".plist", ".savedState", ".binarycookies", ".log", ".db"]

    static func stem(_ name: String) -> String {
        for ext in knownExtensions where name.hasSuffix(ext) { return String(name.dropLast(ext.count)) }
        return name
    }

    static func claim(entry name: String, path: String, rules: [Rule], key: AppKey, cache: LaunchdCache) -> Claim? {
        var best: Claim?
        func offer(_ c: Claim) { if best == nil || best! < c { best = c } }
        let entryStem = stem(name)
        let lower = name.lowercased()
        for rule in rules {
            switch rule {
            case .bundleID:
                if let bid = key.bundleID, Identifiers.isOrSubID(entryStem, of: bid) || Identifiers.isOrSubID(name, of: bid) {
                    offer(Claim(reason: .bundleID, rank: 2, specificity: bid.count))
                }
            case .groupContains:
                if let bid = key.bundleID, Identifiers.containsOnBoundary(name, bid) {
                    offer(Claim(reason: .bundleID, rank: 2, specificity: bid.count))
                }
            case .team:
                if let team = key.teamID {
                    let t = team.lowercased()
                    let body = lower.hasPrefix("group.") ? String(lower.dropFirst(6)) : lower
                    if body.hasPrefix(t + ".") { offer(Claim(reason: .teamID, rank: 1, specificity: 0)) }
                }
            case .name:
                if key.names.contains(lower) { offer(Claim(reason: .name, rank: 1, specificity: 0)) }
            case .launchd:
                guard name.hasSuffix(".plist"), let job = cache.plist(path) else { continue }
                if job.mentionedPaths.contains(where: { PathGuard.isWithin($0, key.path) }) {
                    offer(Claim(reason: .program, rank: 3, specificity: key.path.count))
                } else if let bid = key.bundleID,
                          Identifiers.isOrSubID(job.label, of: bid)
                            || job.associatedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame }) {
                    offer(Claim(reason: .bundleID, rank: 2, specificity: bid.count))
                }
            }
        }
        return best
    }

    /// nil: another app owns it. Otherwise whether it is shared.
    static func sharing(mine: Claim, entry name: String, path: String, rules: [Rule], others: [AppKey],
                        cache: LaunchdCache) -> Bool? {
        var shared = false
        for other in others {
            guard let theirs = claim(entry: name, path: path, rules: rules, key: other, cache: cache) else { continue }
            if mine < theirs { return nil }
            // A weaker claim from another app only makes it shared when ours is weak too.
            if theirs == mine || !(mine.reason.isStrong) { shared = true }
        }
        return shared
    }

    static func scan(_ spec: LocationSpec, library: String, me: AppKey, others: [AppKey], cache: LaunchdCache,
                     into out: inout [Candidate]) {
        let dir = (library as NSString).appendingPathComponent(spec.relative)
        for name in FileSizer.list(dir) {
            let path = dir + "/" + name
            if spec.relative == "Preferences" && name == "ByHost" { continue }
            guard let mine = claim(entry: name, path: path, rules: spec.rules, key: me, cache: cache) else { continue }
            guard let shared = sharing(mine: mine, entry: name, path: path, rules: spec.rules, others: others, cache: cache)
            else { continue }
            out.append(Candidate(path: path, location: spec.location, reason: mine.reason, isShared: shared))
        }
    }

    /// Application Support/<Vendor>: the folder itself (shared unless it is entirely this app's) and, when shared,
    /// the folders inside it named after this app.
    static func vendorFolders(library: String, me: AppKey, others: [AppKey], into out: inout [Candidate]) {
        guard let vendor = me.vendorName?.lowercased() else { return }
        let support = (library as NSString).appendingPathComponent("Application Support")
        for name in FileSizer.list(support) where name.lowercased() == vendor {
            let folder = support + "/" + name
            guard FileSizer.isDirectory(folder), !out.contains(where: { $0.path == folder }) else { continue }
            let children = FileSizer.list(folder)
            func isMine(_ child: String, _ key: AppKey) -> Bool {
                key.names.contains(child.lowercased()) || (key.bundleID.map { Identifiers.isOrSubID(child, of: $0) } ?? false)
            }
            let mine = children.filter { isMine($0, me) }
            let vendorPeers = others.contains { other in
                (other.vendorKey != nil && other.vendorKey == me.vendorKey)
                    || (other.teamID != nil && other.teamID == me.teamID)
                    || children.contains { isMine($0, other) }
            }
            let exclusive = !vendorPeers && mine.count == children.count
            out.append(Candidate(path: folder, location: .applicationSupport, reason: .vendorFolder, isShared: !exclusive))
            guard !exclusive else { continue }
            for child in mine {
                let childShared = others.contains { isMine(child, $0) }
                out.append(Candidate(path: folder + "/" + child, location: .applicationSupport, reason: .vendorFolder,
                                     isShared: childShared))
            }
        }
    }
}
