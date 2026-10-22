import Foundation
import Testing
@testable import SafetyKit

private let home = "/Users/carlos"
private let guardian = PathGuard(home: home, userName: "carlos", uid: 501)

@Suite("PathGuard")
struct PathGuardTests {
    @Test("Protected system roots are refused in every context", arguments: PathContext.allCases)
    func protectedRoots(context: PathContext) {
        for path in ["/System/Library/Caches/x", "/usr/bin/true", "/bin/ls", "/sbin/mount", "/private/var/db/x",
                     "/private/var/vm/swapfile0", "/Library/Apple/System", "/dev/null", "/private/etc/hosts"] {
            #expect(guardian.verdict(for: path, context: context) == .refuse(.protectedLocation), "\(path) in \(context)")
        }
    }

    @Test("Protected user data is refused in every context", arguments: PathContext.allCases)
    func protectedUserData(context: PathContext) {
        for rel in ["Library/Mobile Documents/com~apple~CloudDocs/a.txt", "Library/Mail/V10/x", "Library/Messages/chat.db",
                    "Library/Keychains/login.keychain-db", "Library/Safari/History.db", "Library/Cookies/Cookies.binarycookies",
                    "Pictures/Photos Library.photoslibrary/database", "Pictures/Old.photoslibrary",
                    "Library/Application Support/KeelMac/KeelMac.store", "Library/CloudStorage/Dropbox/a"] {
            #expect(guardian.verdict(for: "\(home)/\(rel)", context: context).allowed == false, "\(rel) in \(context)")
        }
    }

    @Test("Container folders themselves are never removed", arguments: PathContext.allCases)
    func containers(context: PathContext) {
        for path in ["/", "/Applications", "/Users", home, "\(home)/Library", "\(home)/Library/Caches", "\(home)/Documents",
                     "\(home)/Downloads", "\(home)/.Trash", "/Library/Caches", "/usr/local"] {
            #expect(guardian.verdict(for: path, context: context).allowed == false, "\(path) in \(context)")
        }
    }

    @Test("Other users' homes are refused, Shared is not a home")
    func otherUsers() {
        for context in PathContext.allCases {
            #expect(guardian.verdict(for: "/Users/maria/Library/Caches/x", context: context) == .refuse(.otherUserHome))
        }
        #expect(guardian.verdict(for: "/Users/Shared/file.zip", context: .userFile).allowed)
    }

    @Test("Normal home items are allowed for cleanup")
    func allowed() {
        #expect(guardian.verdict(for: "\(home)/Library/Caches/com.spotify.client", context: .cleanup).allowed)
        #expect(guardian.verdict(for: "~/Library/Developer/Xcode/DerivedData/App-abc", context: .cleanup).allowed)
        #expect(guardian.verdict(for: "/Volumes/Backup/.Trashes/501/old.zip", context: .cleanup).allowed)
        #expect(guardian.verdict(for: "/Volumes/Backup/.Trashes/502/old.zip", context: .cleanup).allowed == false)
    }

    @Test(".. and . can't escape into protected places")
    func dotDot() {
        #expect(guardian.verdict(for: "\(home)/Library/Caches/../../../../System/Library", context: .cleanup) == .refuse(.protectedLocation))
        #expect(guardian.verdict(for: "\(home)/Library/Caches/./../Mail/x", context: .cleanup) == .refuse(.protectedLocation))
        #expect(guardian.verdict(for: "Library/Caches/x", context: .cleanup) == .refuse(.relativePath))
    }

    @Test("Paths outside the home need the helper or are refused")
    func outside() {
        #expect(guardian.verdict(for: "/Library/Caches/com.apple.iconservices.store", context: .cleanup) == .refuse(.needsHelper))
        #expect(guardian.verdict(for: "/Library/Caches/com.vendor.cache", context: .helper).allowed)
        #expect(guardian.verdict(for: "/opt/whatever/file", context: .cleanup) == .refuse(.outsideAllowedRoots))
        #expect(guardian.verdict(for: "\(home)/Library/Caches/x", context: .helper) == .refuse(.outsideAllowedRoots))
    }

    @Test("App bundles: allowed for uninstall and user files, never for cleanup")
    func appBundles() {
        #expect(guardian.verdict(for: "/Applications/Zoom.app", context: .uninstall).allowed)
        #expect(guardian.verdict(for: "/Applications/Adobe Acrobat/Acrobat.app", context: .uninstall).allowed)
        #expect(guardian.verdict(for: "/Applications/Install macOS Sonoma.app", context: .userFile).allowed)
        #expect(guardian.verdict(for: "/Applications/Zoom.app", context: .cleanup).allowed == false)
        #expect(guardian.verdict(for: "/Applications/Zoom.app/Contents/MacOS/zoom", context: .uninstall).allowed == false)
    }

    @Test("/usr/local is only for cleanup and helper")
    func usrLocal() {
        #expect(guardian.verdict(for: "/usr/local/Homebrew/Library/Caches/x", context: .cleanup).allowed)
        #expect(guardian.verdict(for: "/usr/local/bin/brew", context: .userFile) == .refuse(.protectedLocation))
    }

    @Test("Whitelist blocks the entry, its children and its ancestors", arguments: PathContext.allCases)
    func whitelist(context: PathContext) {
        let g = guardian.with(whitelist: Whitelist(["~/Library/Caches/com.spotify.client", "~/Developer/**/node_modules/.cache"]))
        #expect(g.verdict(for: "\(home)/Library/Caches/com.spotify.client", context: .cleanup) == .refuse(.whitelisted))
        #expect(g.verdict(for: "\(home)/Library/Caches/com.spotify.client/Data/x", context: .cleanup) == .refuse(.whitelisted))
        #expect(g.verdict(for: "\(home)/Developer/app/web/node_modules/.cache/babel", context: .cleanup) == .refuse(.whitelisted))
        #expect(g.verdict(for: "\(home)/Developer/app/web/node_modules/.cache", context: .cleanup) == .refuse(.whitelisted))
        // Removing ~/Library/Caches itself is refused anyway; an ancestor of a literal entry is refused.
        let g2 = guardian.with(whitelist: Whitelist(["~/Developer/app/keep.txt"]))
        #expect(g2.verdict(for: "\(home)/Developer/app", context: .userFile) == .refuse(.containsWhitelisted))
        #expect(g.verdict(for: "\(home)/Library/Caches/com.spotify.clientX", context: .cleanup).allowed)
    }

    @Test("Symlinked parents are resolved before checking")
    func symlinkParent() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("pg-\(UUID().uuidString)")
        let fakeHome = tmp.appendingPathComponent("home")
        let caches = fakeHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createSymbolicLink(atPath: caches.appendingPathComponent("evil").path, withDestinationPath: "/System/Library")
        let g = PathGuard(home: fakeHome.path, userName: "carlos", uid: 501)
        #expect(g.verdict(for: caches.appendingPathComponent("evil/Fonts").path, context: .cleanup) == .refuse(.protectedLocation))
        // The link itself may be removed (that removes the link, not the target).
        #expect(g.verdict(for: caches.appendingPathComponent("evil").path, context: .cleanup).allowed)
    }

    @Test("Wildcard whitelist entries inside a folder protect the folder")
    func wildcardAncestor() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wl-\(UUID().uuidString)")
        let project = tmp.appendingPathComponent("home/Developer/web")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("node_modules/.cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("home/Developer/other/build"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let g = PathGuard(home: tmp.appendingPathComponent("home").path, userName: "carlos", uid: 501,
                          whitelist: Whitelist(["~/Developer/**/node_modules/.cache"]))
        #expect(g.verdict(for: project.path, context: .userFile) == .refuse(.containsWhitelisted))
        #expect(g.verdict(for: tmp.appendingPathComponent("home/Developer/other/build").path, context: .userFile).allowed)
    }
}

@Suite("GlobMatcher")
struct GlobMatcherTests {
    @Test func components() {
        #expect(GlobMatcher.componentMatches("*.dmg", "Xcode.dmg"))
        #expect(GlobMatcher.componentMatches("com.apple.*", "com.apple.Safari"))
        #expect(!GlobMatcher.componentMatches("*.dmg", "Xcode.dmg.part"))
        #expect(GlobMatcher.componentMatches("a?c", "abc"))
    }

    @Test func paths() {
        #expect(GlobMatcher.matches(pattern: "/Users/c/Library/Caches/*", path: "/Users/c/Library/Caches/x"))
        #expect(!GlobMatcher.matches(pattern: "/Users/c/Library/Caches/*", path: "/Users/c/Library/Caches/x/y"))
        #expect(GlobMatcher.matches(pattern: "/Users/c/**/node_modules", path: "/Users/c/a/b/node_modules"))
        #expect(GlobMatcher.matches(pattern: "/Users/c/**/node_modules", path: "/Users/c/node_modules"))
        #expect(GlobMatcher.matchesSelfOrAncestor(pattern: "/a/*/c", path: "/a/b/c/d/e"))
    }

    @Test func whitelistValidation() {
        #expect(Whitelist.validate("", home: home) == .empty)
        #expect(Whitelist.validate("Library", home: home) == .notAbsolute)
        #expect(Whitelist.validate("~/nope", home: home, fileExists: { _ in false }) == .doesNotExist)
        #expect(Whitelist.validate("~/Developer/**/x", home: home) == nil)
    }
}
