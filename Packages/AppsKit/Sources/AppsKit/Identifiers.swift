import Foundation

/// Bundle-id string rules shared by the matcher, the orphan finder and the launch item store.
/// All comparisons are case-insensitive (bundle ids are, in practice).
enum Identifiers {
    /// `id == bundleID` or `id` starts with `bundleID.`
    static func isOrSubID(_ id: String, of bundleID: String) -> Bool {
        let a = id.lowercased(), b = bundleID.lowercased()
        return a == b || a.hasPrefix(b + ".")
    }

    /// True when `bundleID` occurs in `name` on dot boundaries: `group.com.foo.app`, `TEAM.com.foo.app.shared`.
    /// `com.foo.application` does not contain `com.foo.app`.
    static func containsOnBoundary(_ name: String, _ bundleID: String) -> Bool {
        let hay = name.lowercased(), needle = bundleID.lowercased()
        guard !needle.isEmpty else { return false }
        var searchStart = hay.startIndex
        while let range = hay.range(of: needle, range: searchStart..<hay.endIndex) {
            let beforeOK = range.lowerBound == hay.startIndex || hay[hay.index(before: range.lowerBound)] == "."
            let afterOK = range.upperBound == hay.endIndex || hay[range.upperBound] == "."
            if beforeOK && afterOK { return true }
            searchStart = hay.index(after: range.lowerBound)
        }
        return false
    }

    /// Looks like a reverse-DNS bundle id with at least three components: `com.vendor.app`.
    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = parts.first, tld.count >= 2, tld.count <= 12,
              tld.allSatisfy({ $0.isASCII && ($0.isLetter) }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for part in parts {
            guard part.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return false }
        }
        // The second component is a vendor name, not a number or a version.
        return parts[1].contains { $0.isLetter }
    }

    /// A ten-character Apple team identifier: `UBF8T346G9`.
    static func isTeamID(_ s: Substring) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
            && s.contains { $0.isLetter } && s.contains { $0.isNumber }
    }

    /// Second-level components that are hosting namespaces rather than vendors (`com.github.user.app`).
    static let hostingNamespaces: Set<String> = [
        "github", "gitlab", "bitbucket", "sourceforge", "googlecode", "electron", "electronjs", "example",
        "mycompany", "yourcompany", "company", "personal", "test", "local", "apps", "app",
    ]

    /// `com.vendor` for vendor-level ownership, or `com.github.user` for hosting namespaces.
    /// Nil when the id is too short to name a vendor.
    static func vendorKey(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        if hostingNamespaces.contains(String(parts[1])) {
            return parts.count >= 4 ? parts.prefix(3).joined(separator: ".") : nil
        }
        return parts.prefix(2).joined(separator: ".")
    }

    /// The vendor component (`google` in `com.google.Chrome`), when it can name a folder.
    static func vendorName(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        guard vendor.count >= 3, !hostingNamespaces.contains(vendor.lowercased()) else { return nil }
        return vendor
    }

    static func isApple(_ id: String) -> Bool {
        let l = id.lowercased()
        return l == "com.apple" || l.hasPrefix("com.apple.") || l.hasPrefix("group.com.apple.")
            || l.contains(".com.apple.") || l.hasSuffix(".com.apple") || l.hasPrefix("systemgroup.")
            || l.hasPrefix("com.apple-")
            // Apple-owned namespaces that don't say "apple": Shortcuts (Workflow) and CUPS printing.
            || l.hasPrefix("is.workflow.") || l.hasPrefix("org.cups.")
    }

    /// Ids written by frameworks, SDKs, toolchains and shared updaters inside many apps. A cache or plist named
    /// after one of these has no single owner, so the orphan finder never offers it.
    static let sharedVendorPrefixes: [String] = [
        "com.crashlytics", "io.fabric", "com.plausiblelabs", "net.hockeyapp", "com.hockeyapp", "io.sentry",
        "com.getsentry", "com.bugsnag", "com.firebase", "com.google.firebase", "com.segment", "com.amplitude",
        "com.mixpanel", "com.microsoft.appcenter", "org.sparkle-project", "com.github.sparkle",
        "com.google.keystone", "com.google.googleupdater", "com.google.softwareupdate", "com.microsoft.autoupdate",
        "com.microsoft.office", "com.microsoft.shared", "com.microsoft.mau", "com.adobe.acc", "com.adobe.ccx",
        "com.adobe.adobeupdatedaemon", "com.adobe.arm", "com.oracle.java", "com.oracle.javadeployment",
        "org.python", "org.swift", "org.llvm", "org.cocoapods", "org.carthage", "org.nodejs", "org.chromium",
        "com.github.electron", "org.mozilla.updater", "com.squirrel", "com.electron", "org.gpgtools",
        "org.macports", "org.xquartz", "com.openssh", "org.openssh", "com.vmware.fusion.shared", "org.webkit",
        "com.onevcat", "com.squareup", "com.facebook.sdk", "com.google.gtm", "com.google.gtmsessionfetcher",
    ]

    static func isSharedVendorID(_ id: String) -> Bool {
        let l = id.lowercased()
        return sharedVendorPrefixes.contains { l == $0 || l.hasPrefix($0 + ".") }
    }

    /// Folder names too generic to tie to an app by name alone.
    static let genericNames: Set<String> = [
        "app", "apps", "application", "cache", "caches", "crashreporter", "crashes", "data", "default",
        "helper", "logs", "log", "preferences", "settings", "shared", "support", "temp", "tmp", "updates",
        "updater", "user", "users", "electron", "chromium", "cef", "common", "plugins", "extensions", "library",
        "diagnostics", "reports", "storage", "webkit", "google", "microsoft", "adobe", "mozilla",
    ]

    /// Words too common to tie an id to an installed app.
    static let genericTokens: Set<String> = [
        "app", "apps", "mac", "macos", "osx", "the", "inc", "llc", "ltd", "labs", "lab", "software", "studio",
        "desktop", "helper", "agent", "com", "org", "net", "dev", "pro", "plus", "tools", "tool", "tech", "group",
        "media", "digital", "systems", "cloud", "web", "online", "games", "game", "team", "client", "for", "and",
        "update", "updater", "service", "services", "mobile", "beta", "free", "lite", "new", "manager", "assistant",
    ]

    /// Lowercased alphanumeric words of at least three characters.
    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { $0.count >= 3 && !genericTokens.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    static func strippingByHostSuffix(_ stem: String) -> String {
        // ByHost plists: com.foo.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B (or a 12-hex Ethernet id on old macOS).
        let parts = stem.split(separator: ".")
        guard parts.count > 3, let last = parts.last else { return stem }
        let s = String(last)
        let isUUID = UUID(uuidString: s) != nil
        let isHex12 = s.count == 12 && s.allSatisfy { $0.isHexDigit }
        return (isUUID || isHex12) ? parts.dropLast().joined(separator: ".") : stem
    }
}
