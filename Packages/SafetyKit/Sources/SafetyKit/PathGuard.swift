import Foundation

/// Where a removal request comes from. Each context allows a different set of roots;
/// the hard-protected set is refused in every context.
public enum PathContext: String, Sendable, Codable, CaseIterable {
    /// Cleanup rules, leftovers and duplicates: the user's home, Trash folders on volumes, /usr/local caches.
    case cleanup
    /// A file the user picked (storage map, large and old files): the user's home and app bundles in /Applications.
    case userFile
    /// App uninstall: the user's home and app bundles in /Applications and ~/Applications.
    case uninstall
    /// The privileged helper: system Library caches and logs, launchd folders, /Applications.
    case helper
}

/// Why a path was refused. Raw values are stable (they are written to the operation log).
public enum RefusalReason: String, Sendable, Codable, Equatable {
    case relativePath
    case protectedLocation
    case containerFolder
    case otherUserHome
    case whitelisted
    case containsWhitelisted
    case outsideAllowedRoots
    case needsHelper
    case notFound
    case changedSincePreview

    /// English text for logs and exports; the app localizes from the raw value.
    public var englishDescription: String {
        switch self {
        case .relativePath: "Not an absolute path"
        case .protectedLocation: "Protected location"
        case .containerFolder: "A system folder that holds other items"
        case .otherUserHome: "Belongs to another user"
        case .whitelisted: "Whitelisted"
        case .containsWhitelisted: "Contains a whitelisted item"
        case .outsideAllowedRoots: "Outside the folders KeelMac may change"
        case .needsHelper: "Needs the KeelMac helper"
        case .notFound: "No longer exists"
        case .changedSincePreview: "Changed since the preview"
        }
    }
}

public struct PathVerdict: Sendable, Equatable {
    public let allowed: Bool
    public let reason: RefusalReason?

    public static let allow = PathVerdict(allowed: true, reason: nil)
    public static func refuse(_ reason: RefusalReason) -> PathVerdict { PathVerdict(allowed: false, reason: reason) }
}

/// Decides whether a path may be moved to the Trash or deleted. Every removal in KeelMac, in the app
/// and in the helper, goes through `verdict(for:context:)` immediately before it happens.
public struct PathGuard: Sendable {
    public let home: String
    public let userName: String
    public let uid: UInt32
    public let whitelist: Whitelist

    public init(
        home: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        uid: UInt32 = getuid(),
        whitelist: Whitelist = Whitelist()
    ) {
        self.home = PathGuard.canonical(PathGuard.normalize(home))
        self.userName = userName
        self.uid = uid
        self.whitelist = whitelist
    }

    public func with(whitelist: Whitelist) -> PathGuard {
        PathGuard(home: home, userName: userName, uid: uid, whitelist: whitelist)
    }

    // MARK: - Protected sets

    /// Never touched, in any context, including everything below them.
    public static let protectedRoots: [String] = [
        "/System", "/bin", "/sbin", "/usr", "/dev", "/cores",
        "/private/etc", "/private/var/db", "/private/var/vm", "/private/var/root",
        "/private/var/protected", "/private/var/audit",
        "/Library/Apple", "/Library/Keychains", "/Library/Security",
        "/opt/homebrew/Cellar", "/Library/Developer/CommandLineTools",
    ]

    /// The part of `/usr` that isn't macOS: package managers (Intel Homebrew) live here. Only cleanup rules
    /// and the helper may touch it, and only below it (the folder itself is a container).
    public static let usrExceptions: [String] = ["/usr/local"]

    /// Protected subtrees relative to the user's home.
    public static let protectedHomeSubtrees: [String] = [
        "Library/Mobile Documents",            // iCloud Drive
        "Library/CloudStorage",                // other cloud drives
        "Library/Mail",
        "Library/Containers/com.apple.mail",
        "Library/Group Containers/group.com.apple.mail",
        "Library/Messages",
        "Library/Keychains",
        "Library/Safari",                      // history, bookmarks; Safari's cache lives in Library/Caches
        "Library/Cookies",
        "Library/Photos",
        "Library/Application Support/KeelMac", // KeelMac's own log and snapshots
        "Library/Accounts",
        "Library/IdentityServices",
        "Library/Calendars",
        "Library/Application Support/AddressBook",
        "Library/Application Support/com.apple.TCC",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Folders that hold other items: their contents may be removed, the folder itself never.
    public static let containerFolders: [String] = [
        "/", "/Applications", "/Library", "/Users", "/Users/Shared", "/Volumes", "/private", "/private/var",
        "/private/var/folders", "/private/var/log", "/private/tmp", "/opt", "/opt/homebrew", "/usr/local",
        "/Library/Caches", "/Library/Logs", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/Application Support", "/Library/Preferences",
    ]

    public static let homeContainerFolders: [String] = [
        "", "Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        "Developer", "Library", ".Trash",
        "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
        "Library/Containers", "Library/Group Containers", "Library/Saved Application State",
        "Library/LaunchAgents", "Library/Developer", "Library/Developer/Xcode", "Library/HTTPStorages",
        "Library/WebKit", "Library/Logs/DiagnosticReports", "Library/Application Support/MobileSync",
        "Library/Application Support/MobileSync/Backup", "Library/Developer/CoreSimulator",
    ]

    // MARK: - Verdict

    public func verdict(for rawPath: String, context: PathContext) -> PathVerdict {
        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else { return .refuse(.relativePath) }
        let literal = PathGuard.canonical(PathGuard.normalize(expandTilde(rawPath)))
        // Resolve symlinks in the parent so a link inside an allowed folder can't point the removal elsewhere.
        // The item itself is not resolved: trashing a symlink trashes the link, never its target.
        let resolved = PathGuard.resolveParent(of: literal)
        for candidate in Set([literal, resolved]) {
            if let reason = structuralRefusal(for: candidate, context: context) { return .refuse(reason) }
        }
        if whitelist.matches(literal, home: home) || whitelist.matches(resolved, home: home) {
            return .refuse(.whitelisted)
        }
        if whitelist.isAncestorOfEntry(literal, home: home) || whitelist.isAncestorOfEntry(resolved, home: home) {
            return .refuse(.containsWhitelisted)
        }
        return .allow
    }

    private func structuralRefusal(for path: String, context: PathContext) -> RefusalReason? {
        if PathGuard.containerFolders.contains(path) { return .containerFolder }
        if PathGuard.homeContainerFolders.contains(where: { joinHome($0) == path }) { return .containerFolder }

        let isUsrException = PathGuard.usrExceptions.contains { PathGuard.isWithin(path, $0) }
        for root in PathGuard.protectedRoots where PathGuard.isWithin(path, root) {
            if root == "/usr" && isUsrException && (context == .cleanup || context == .helper) { continue }
            return .protectedLocation
        }
        for sub in PathGuard.protectedHomeSubtrees where PathGuard.isWithin(path, joinHome(sub)) {
            return .protectedLocation
        }
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) { return .protectedLocation }

        if PathGuard.isWithin(path, "/Users") && !PathGuard.isWithin(path, home) {
            let components = path.split(separator: "/")
            if components.count >= 2 && components[1] != "Shared" { return .otherUserHome }
        }
        if !isInAllowedRoot(path, context: context) {
            return context == .helper ? .outsideAllowedRoots : (isHelperRoot(path) ? .needsHelper : .outsideAllowedRoots)
        }
        return nil
    }

    private func isInAllowedRoot(_ path: String, context: PathContext) -> Bool {
        let inHome = PathGuard.isWithin(path, home)
        switch context {
        case .cleanup:
            return inHome || isVolumeTrash(path) || PathGuard.isWithin(path, "/usr/local")
                || PathGuard.isWithin(path, "/opt/homebrew/Library/Caches")
        case .userFile:
            return inHome || isAppBundle(path, in: "/Applications") || PathGuard.isWithin(path, "/Users/Shared")
        case .uninstall:
            return inHome || isAppBundle(path, in: "/Applications")
        case .helper:
            return isHelperRoot(path) || isAppBundle(path, in: "/Applications")
        }
    }

    private func isHelperRoot(_ path: String) -> Bool {
        let roots = ["/Library/Caches", "/Library/Logs", "/private/var/log", "/Library/LaunchAgents",
                     "/Library/LaunchDaemons", "/Library/Application Support", "/Library/PrivilegedHelperTools",
                     "/Library/Preferences"]
        return roots.contains { PathGuard.isWithin(path, $0) && path != $0 }
    }

    private func isAppBundle(_ path: String, in folder: String) -> Bool {
        // An .app directly in the folder or one level of subfolder (/Applications/Utilities/X.app, vendor folders).
        guard PathGuard.isWithin(path, folder), path != folder else { return false }
        let rest = path.dropFirst(folder.count + 1).split(separator: "/")
        guard let first = rest.first else { return false }
        if rest.count == 1 { return first.hasSuffix(".app") }
        return rest.count == 2 && rest[1].hasSuffix(".app") && !first.hasSuffix(".app")
    }

    private func isVolumeTrash(_ path: String) -> Bool {
        // /Volumes/<name>/.Trashes/<uid>/...
        let parts = path.split(separator: "/")
        return parts.count >= 5 && parts[0] == "Volumes" && parts[2] == ".Trashes" && parts[3] == Substring(String(uid))
    }

    // MARK: - Helpers

    public func expandTilde(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    func joinHome(_ relative: String) -> String { relative.isEmpty ? home : home + "/" + relative }

    /// Removes `.`/`..` components and trailing slashes without touching the file system.
    public static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Resolves symlinks in every component except the last.
    public static func resolveParent(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath().path
        let joined = (resolvedParent == "/" ? "" : resolvedParent) + "/" + url.lastPathComponent
        return canonical(normalize(joined))
    }

    /// macOS spells some folders two ways (/var and /private/var). Foundation's symlink resolution strips
    /// /private, so every path is compared in its /private form.
    public static func canonical(_ path: String) -> String {
        for (short, long) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")]
        where isWithin(path, short) {
            return long + path.dropFirst(short.count)
        }
        return path
    }

    public static func isWithin(_ path: String, _ root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }
}
