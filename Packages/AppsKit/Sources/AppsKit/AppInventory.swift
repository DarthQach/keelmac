import Foundation

/// Lists application bundles in Applications folders.
public enum AppInventory {
    /// /Applications and ~/Applications. /System/Applications is never listed (those apps can't be removed).
    public static func defaultFolders(home: String) -> [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    /// Bundles in each folder and one level of subfolders (/Applications/Utilities, vendor folders), with size,
    /// team id and last-used date. Measuring runs concurrently.
    public static func scan(folders: [String]) async -> [InstalledApp] {
        await scan(folders: folders, measure: true)
    }

    /// `measure: false` skips sizes, code signatures and Spotlight (a fast first listing).
    public static func scan(folders: [String], measure: Bool) async -> [InstalledApp] {
        let paths = bundlePaths(in: folders)
        let basics = paths.compactMap { app(at: $0) }
        guard measure else { return sorted(basics) }
        let measured = await measureAll(basics)
        return sorted(measured)
    }

    /// Reads one bundle (for the drop zone and the Trash watcher). No size, team id or last use.
    public static func app(at path: String) -> InstalledApp? {
        let path = PathNormalizer.standard(path)
        guard path.hasSuffix(".app"), FileSizer.isDirectory(path) else { return nil }
        let info = BundleReader.read(bundle: path)
        let name = info?.displayName ?? info?.bundleName ?? BundleReader.stem(of: path)
        let bundleID = info?.bundleID
        let isApple = (bundleID.map(Identifiers.isApple) ?? false) || path.hasPrefix("/System/Applications/")
        return InstalledApp(name: name, path: path, bundleID: bundleID, version: info?.version, teamID: nil,
                            bytes: nil, lastUsed: nil, isApple: isApple)
    }

    /// Size, team id and last-used date for one app.
    public static func measure(_ app: InstalledApp) -> InstalledApp {
        app.with(bytes: FileSizer.allocatedSize(of: app.path),
                 teamID: CodeSignature.teamID(ofBundle: app.path),
                 lastUsed: Spotlight.lastUsed(app.path))
    }

    // MARK: - Internals

    static func bundlePaths(in folders: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ path: String) {
            // Symlinked bundles (Safari's link into the cryptex) are skipped: removing them removes nothing.
            guard !FileSizer.isSymlink(path), FileSizer.isDirectory(path) else { return }
            let real = (path as NSString).resolvingSymlinksInPath
            guard !real.hasPrefix("/System/"), seen.insert(real).inserted else { return }
            out.append(path)
        }
        for raw in folders {
            let folder = PathNormalizer.standard(raw)
            guard !folder.hasPrefix("/System/") && folder != "/System" else { continue }
            for name in FileSizer.list(folder) {
                let path = folder + "/" + name
                if name.hasSuffix(".app") { add(path); continue }
                guard !FileSizer.isSymlink(path), FileSizer.isDirectory(path), !isPackage(name) else { continue }
                for inner in FileSizer.list(path) where inner.hasSuffix(".app") { add(path + "/" + inner) }
            }
        }
        return out
    }

    private static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "bundle", "framework", "plugin", "appex", "kext", "pkg", "mpkg", "photoslibrary"].contains(ext)
    }

    static func measureAll(_ apps: [InstalledApp]) async -> [InstalledApp] {
        let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        return await withTaskGroup(of: (Int, InstalledApp).self) { group in
            var results = apps
            var next = 0
            for _ in 0..<min(width, apps.count) {
                let i = next, app = apps[i]; next += 1
                group.addTask { (i, measure(app)) }
            }
            while let (i, app) = await group.next() {
                results[i] = app
                if next < apps.count {
                    let j = next, item = apps[j]; next += 1
                    group.addTask { (j, measure(item)) }
                }
            }
            return results
        }
    }

    private static func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum PathNormalizer {
    static func standard(_ path: String) -> String {
        // Not `standardizingPath`: it rewrites /private/var to /var, and paths must stay the way callers gave them.
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
