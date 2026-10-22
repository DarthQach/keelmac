import AppKit
import Foundation
import SafetyKit

/// Finds Library entries named after bundle ids that no installed or running app owns.
///
/// A false positive here moves someone's data to the Trash, so every doubt keeps the entry out:
/// Apple ids, ids shared by SDKs and updaters, anything an installed app (or a bundle inside it), a running app,
/// a running process, an open file, a launchd job, LaunchServices, or the same vendor still claims, and
/// anything written to recently.
public enum OrphanFinder {
    public struct Options: Sendable {
        /// Bundle ids of running apps. Defaults to `RunningApps.bundleIDs()`.
        public var runningBundleIDs: Set<String>
        /// Paths currently open in, or executing as, the user's processes. Defaults to a libproc sweep.
        public var pathsInUse: Set<String>
        /// Whether LaunchServices knows an app with this bundle id somewhere on disk (outside the Trash).
        public var isRegisteredApp: @Sendable (String) -> Bool
        /// Folders with launchd plists whose labels and programs keep their ids owned.
        public var launchdFolders: [String]
        /// Entries modified more recently than this are skipped (something still writes them).
        public var minimumIdleDays: Double
        public var now: Date
        public var pathGuard: PathGuard?

        public init(runningBundleIDs: Set<String> = [], pathsInUse: Set<String> = [],
                    isRegisteredApp: @escaping @Sendable (String) -> Bool = { _ in false },
                    launchdFolders: [String] = [], minimumIdleDays: Double = 3, now: Date = Date(),
                    pathGuard: PathGuard? = nil) {
            self.runningBundleIDs = runningBundleIDs; self.pathsInUse = pathsInUse
            self.isRegisteredApp = isRegisteredApp; self.launchdFolders = launchdFolders
            self.minimumIdleDays = minimumIdleDays; self.now = now; self.pathGuard = pathGuard
        }

        /// The live system: running apps, open files, LaunchServices and the three launchd folders.
        public static func live(home: String) -> Options {
            Options(runningBundleIDs: RunningApps.bundleIDs(),
                    pathsInUse: ProcessPaths.inUse(under: [(home as NSString).appendingPathComponent("Library")]),
                    isRegisteredApp: { RunningApps.isRegisteredApp(bundleID: $0) },
                    launchdFolders: [(home as NSString).appendingPathComponent("Library/LaunchAgents"),
                                     "/Library/LaunchAgents", "/Library/LaunchDaemons"])
        }
    }

    public static func find(home: String, installed: [InstalledApp]) -> [LeftoverGroup] {
        find(home: home, installed: installed, options: .live(home: home))
    }

    public static func find(home: String, installed: [InstalledApp], options: Options) -> [LeftoverGroup] {
        let library = (home as NSString).appendingPathComponent("Library")
        let guardian = options.pathGuard ?? PathGuard(home: home)
        let owners = Ownership(installed: installed, options: options)

        // id (lowercased) -> (original spelling, files)
        var groups: [String: (id: String, entries: [(String, RelatedLocation)])] = [:]
        func add(_ id: String, _ path: String, _ location: RelatedLocation) {
            let key = id.lowercased()
            groups[key, default: (id, [])].entries.append((path, location))
        }

        for spec in specs {
            let dir = (library as NSString).appendingPathComponent(spec.relative)
            for name in FileSizer.list(dir) {
                let path = dir + "/" + name
                guard let id = spec.id(name, path) else { continue }
                add(id, path, spec.location)
            }
        }

        // Fold `com.foo.app.helper` into `com.foo.app` when both are candidates.
        let keys = groups.keys.sorted { $0.count < $1.count }
        for key in keys {
            guard let group = groups[key] else { continue }
            if let parent = keys.first(where: { $0 != key && $0.count < key.count && key.hasPrefix($0 + ".") && groups[$0] != nil }) {
                groups[parent]?.entries.append(contentsOf: group.entries)
                groups[key] = nil
            }
        }

        let idleCutoff = options.now.addingTimeInterval(-options.minimumIdleDays * 86_400)
        var out: [LeftoverGroup] = []
        for (_, group) in groups {
            guard !owners.isOwned(group.id) else { continue }
            // Every file in the group must be idle and unused, or the whole group stays.
            var files: [RelatedFile] = []
            var newest: Date?
            var keep = true
            for (path, location) in group.entries {
                if owners.inUse(path) { keep = false; break }
                let modified = FileSizer.modificationDate(of: path)
                if let modified, modified > idleCutoff { keep = false; break }
                guard guardian.verdict(for: path, context: .cleanup).allowed else { continue }
                if let modified, newest.map({ modified > $0 }) ?? true { newest = modified }
                files.append(RelatedFile(path: path, bytes: FileSizer.allocatedSize(of: path), location: location,
                                         isShared: false, needsHelper: false, modified: modified, reason: .bundleID))
            }
            guard keep, !files.isEmpty else { continue }
            files.sort { $0.bytes > $1.bytes }
            out.append(LeftoverGroup(id: group.id, displayName: displayName(for: group.id, files: files),
                                     files: files, lastModified: newest))
        }
        return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
    }

    // MARK: - Where to look

    struct Spec {
        let relative: String
        let location: RelatedLocation
        /// The bundle id an entry is named after, or nil when it doesn't look like one.
        let id: (String, String) -> String?
    }

    static func bundleIDFolder(_ name: String, _ path: String) -> String? {
        guard Identifiers.looksLikeBundleID(name), FileSizer.isDirectory(path) else { return nil }
        return name
    }

    static let specs: [Spec] = [
        Spec(relative: "Containers", location: .containers, id: bundleIDFolder),
        Spec(relative: "Caches", location: .caches, id: bundleIDFolder),
        Spec(relative: "Application Support", location: .applicationSupport, id: bundleIDFolder),
        Spec(relative: "HTTPStorages", location: .httpStorages, id: bundleIDFolder),
        Spec(relative: "WebKit", location: .webKit, id: bundleIDFolder),
        Spec(relative: "Saved Application State", location: .savedState, id: { name, _ in
            guard name.hasSuffix(".savedState") else { return nil }
            let id = String(name.dropLast(".savedState".count))
            return Identifiers.looksLikeBundleID(id) ? id : nil
        }),
        Spec(relative: "Preferences", location: .preferences, id: { name, path in
            guard name.hasSuffix(".plist"), !FileSizer.isDirectory(path) else { return nil }
            let id = String(name.dropLast(".plist".count))
            return Identifiers.looksLikeBundleID(id) ? id : nil
        }),
        Spec(relative: "Preferences/ByHost", location: .preferences, id: { name, path in
            guard name.hasSuffix(".plist"), !FileSizer.isDirectory(path) else { return nil }
            let id = Identifiers.strippingByHostSuffix(String(name.dropLast(".plist".count)))
            return Identifiers.looksLikeBundleID(id) ? id : nil
        }),
        Spec(relative: "Group Containers", location: .groupContainers, id: { name, path in
            guard FileSizer.isDirectory(path) else { return nil }
            if name.lowercased().hasPrefix("group.") {
                let rest = String(name.dropFirst(6))
                if Identifiers.looksLikeBundleID(rest) { return rest }
                // group.TEAMID.com.foo
                let parts = rest.split(separator: ".", maxSplits: 1)
                if parts.count == 2, Identifiers.isTeamID(parts[0]) { return name }
                return nil
            }
            let parts = name.split(separator: ".", maxSplits: 1)
            if parts.count == 2, Identifiers.isTeamID(parts[0]) { return name }
            return Identifiers.looksLikeBundleID(name) ? name : nil
        }),
    ]

    // MARK: - Ownership

    struct Ownership {
        let bundleIDs: [String]          // lowercased: installed, embedded, running, launchd labels
        let vendorKeys: Set<String>
        let teamIDs: Set<String>
        let pathsInUse: [String]
        let isRegistered: @Sendable (String) -> Bool

        init(installed: [InstalledApp], options: Options) {
            var ids = Set<String>()
            var teams = Set<String>()
            for app in installed {
                if let bid = app.bundleID { ids.insert(bid.lowercased()) }
                if let team = app.teamID { teams.insert(team.uppercased()) }
                for inner in OrphanFinder.embeddedBundleIDs(in: app.path) { ids.insert(inner.lowercased()) }
            }
            for bid in options.runningBundleIDs { ids.insert(bid.lowercased()) }
            for folder in options.launchdFolders {
                for name in FileSizer.list(folder) where name.hasSuffix(".plist") {
                    guard let job = LaunchdPlist.read(folder + "/" + name) else { continue }
                    ids.insert(job.label.lowercased())
                    for a in job.associatedBundleIDs { ids.insert(a.lowercased()) }
                }
            }
            bundleIDs = Array(ids)
            vendorKeys = Set(installed.compactMap { $0.bundleID.flatMap(Identifiers.vendorKey) })
            teamIDs = teams
            pathsInUse = Array(options.pathsInUse)
            isRegistered = options.isRegisteredApp
        }

        func isOwned(_ rawID: String) -> Bool {
            let id = rawID.lowercased()
            if Identifiers.isApple(id) || Identifiers.isSharedVendorID(id) { return true }
            // group.TEAMID.x and TEAMID.x: owned while an app of that team is installed.
            let body = id.hasPrefix("group.") ? String(id.dropFirst(6)) : id
            let teamPart = body.split(separator: ".", maxSplits: 1)
            if teamPart.count == 2, Identifiers.isTeamID(Substring(teamPart[0].uppercased())) {
                if teamIDs.contains(teamPart[0].uppercased()) { return true }
                let rest = String(teamPart[1])
                return Identifiers.looksLikeBundleID(rest) ? isOwnedBundleID(rest) : false
            }
            return isOwnedBundleID(body)
        }

        private func isOwnedBundleID(_ id: String) -> Bool {
            if Identifiers.isApple(id) || Identifiers.isSharedVendorID(id) { return true }
            for owned in bundleIDs {
                // Exact, a sub-id of an installed app (helpers, extensions), or a prefix of one (com.foo.app vs
                // com.foo.app.pro), and also `com.foo.app-helper` style login items.
                if id == owned || id.hasPrefix(owned + ".") || owned.hasPrefix(id + ".") || id.hasPrefix(owned + "-") {
                    return true
                }
            }
            if let vendor = Identifiers.vendorKey(id), vendorKeys.contains(vendor) { return true }
            return isRegistered(id)
        }

        func inUse(_ path: String) -> Bool {
            pathsInUse.contains { PathGuard.isWithin($0, path) || PathGuard.isWithin(path, $0) }
        }
    }

    /// Bundle ids of helpers, extensions and login items inside an app bundle.
    static func embeddedBundleIDs(in appPath: String) -> [String] {
        let roots = ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/Library/LaunchServices",
                     "Contents/Helpers", "Contents/XPCServices", "Contents/Library/SystemExtensions",
                     "Contents/Frameworks", "Contents/Extensions", "Contents/Library/QuickLook",
                     "Contents/Library/Spotlight", "Wrapper"]
        var ids: [String] = []
        for root in roots {
            let dir = appPath + "/" + root
            for name in FileSizer.list(dir) {
                let path = dir + "/" + name
                if root == "Contents/Library/LaunchServices", !name.contains("/") {
                    ids.append(name)   // privileged helper tools are named after their bundle id
                }
                guard FileSizer.isDirectory(path) else { continue }
                if let bid = BundleReader.read(bundle: path)?.bundleID { ids.append(bid) }
                if root == "Contents/Frameworks", name.hasSuffix(".framework") {
                    // Electron and Chromium helper apps live in Frameworks and inside the main framework.
                    for helper in FileSizer.list(path + "/Versions/A/Helpers") where helper.hasSuffix(".app") {
                        if let bid = BundleReader.read(bundle: path + "/Versions/A/Helpers/" + helper)?.bundleID { ids.append(bid) }
                    }
                }
            }
        }
        return ids
    }

    // MARK: - Names

    static let genericLastComponents: Set<String> = [
        "app", "mac", "macos", "osx", "desktop", "client", "helper", "agent", "main", "application", "macapp",
        "mas", "plist", "x",
    ]

    /// A readable name: CFBundleName-ish from a container's metadata when present, else the id's last
    /// meaningful component.
    static func displayName(for id: String, files: [RelatedFile]) -> String {
        for file in files where file.location == .containers {
            let meta = file.path + "/.com.apple.containermanagerd.metadata.plist"
            if let dict = BundleReader.plist(at: meta),
               let info = dict["MCMMetadataInfo"] as? [String: Any],
               let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String, !name.isEmpty {
                return name
            }
        }
        var parts = id.split(separator: ".").map(String.init)
        if let first = parts.first, first.lowercased() == "group" || Identifiers.isTeamID(Substring(first)) {
            parts.removeFirst()
        }
        while parts.count > 1, let last = parts.last, genericLastComponents.contains(last.lowercased()) {
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return id }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
