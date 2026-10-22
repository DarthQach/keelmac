import Foundation

/// One fixed command: an absolute executable and its argument array. Never a shell string.
public struct HelperInvocation: Sendable, Equatable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// A failure doesn't stop the operation (for example `bootout` of a job that isn't running).
    public let bestEffort: Bool

    public init(_ executable: String, _ arguments: [String], bestEffort: Bool = false) {
        self.executable = executable; self.arguments = arguments; self.bestEffort = bestEffort
    }
}

/// One step of an operation, in order.
public enum HelperStep: Sendable, Equatable {
    case run(HelperInvocation)
    /// Move these paths to the requesting user's Trash with `SafeRemover` (context `.helper`).
    case trash([String])
}

/// Which launchd domain a validated plist belongs to.
public enum LaunchPlistFolder: String, Sendable, Equatable, CaseIterable {
    case daemons = "/Library/LaunchDaemons"
    case agents = "/Library/LaunchAgents"
}

/// The single source of truth for what each operation runs. Pure: no file system, no process.
public enum HelperCommandMap {
    public static let dscacheutil = "/usr/bin/dscacheutil"
    public static let killall = "/usr/bin/killall"
    public static let mdutil = "/usr/bin/mdutil"
    public static let periodic = "/usr/sbin/periodic"
    public static let tmutil = "/usr/bin/tmutil"
    public static let launchctl = "/bin/launchctl"
    public static let sfltool = "/usr/bin/sfltool"

    /// The commands an operation runs, in order. `clientUID` picks the `gui/<uid>` domain for
    /// items in /Library/LaunchAgents (the helper passes the connecting user's uid; in the app the default is the app's own).
    public static func invocations(for op: HelperOperation, clientUID: UInt32 = getuid()) -> [(executable: String, arguments: [String])] {
        steps(for: op, clientUID: clientUID).compactMap {
            if case .run(let inv) = $0 { return (executable: inv.executable, arguments: inv.arguments) }
            return nil
        }
    }

    /// Every step of an operation, including Trash moves and best-effort flags.
    public static func steps(for op: HelperOperation, clientUID: UInt32 = getuid()) -> [HelperStep] {
        switch op {
        case .flushDNS:
            return [.run(HelperInvocation(dscacheutil, ["-flushcache"])),
                    .run(HelperInvocation(killall, ["-HUP", "mDNSResponder"]))]
        case .rebuildSpotlight:
            return [.run(HelperInvocation(mdutil, ["-E", "/"]))]
        case .runPeriodic:
            return [.run(HelperInvocation(periodic, ["daily", "weekly", "monthly"]))]
        case .thinLocalSnapshots(let bytes):
            return [.run(HelperInvocation(tmutil, ["thinlocalsnapshots", "/", String(bytes), "4"]))]
        case .removeSystemItems(let paths):
            return [.trash(paths)]
        case .dumpBackgroundItems:
            return [.run(HelperInvocation(sfltool, ["dumpbtm"]))]
        case .launchd(let label, let plistPath, let action):
            let domain = launchdDomain(plistPath: plistPath, clientUID: clientUID)
            let target = "\(domain)/\(label)"
            switch action {
            case .enable:
                return [.run(HelperInvocation(launchctl, ["enable", target])),
                        .run(HelperInvocation(launchctl, ["bootstrap", domain, plistPath], bestEffort: true))]
            case .disable:
                return [.run(HelperInvocation(launchctl, ["disable", target])),
                        .run(HelperInvocation(launchctl, ["bootout", target], bestEffort: true))]
            case .remove:
                return [.run(HelperInvocation(launchctl, ["bootout", target], bestEffort: true)),
                        .trash([plistPath])]
            }
        }
    }

    /// `system` for /Library/LaunchDaemons, `gui/<uid>` for /Library/LaunchAgents.
    public static func launchdDomain(plistPath: String, clientUID: UInt32) -> String {
        HelperValidation.plistFolder(of: plistPath) == .agents ? "gui/\(clientUID)" : "system"
    }

    /// Every executable the helper can ever run. The helper runs nothing outside this set.
    public static let allowedExecutables: Set<String> = [dscacheutil, killall, mdutil, periodic, tmutil, launchctl, sfltool]
}

/// Pure checks the helper runs on every request before anything happens (the app can run them too, to pre-check).
public enum HelperValidation {
    public static let maxPaths = 1000
    public static let maxLabelLength = 200
    /// 100 TB: far more than any disk; anything bigger is a malformed request.
    public static let maxThinBytes: Int64 = 100_000_000_000_000

    /// - Parameter plistLabel: reads the `Label` key of a plist; consulted only when the file name isn't `<label>.plist`.
    public static func validate(_ op: HelperOperation, plistLabel: (String) -> String? = { _ in nil }) -> HelperRejection? {
        switch op {
        case .flushDNS, .rebuildSpotlight, .runPeriodic, .dumpBackgroundItems:
            return nil
        case .thinLocalSnapshots(let bytes):
            return (bytes > 0 && bytes <= maxThinBytes) ? nil : .invalidByteCount
        case .removeSystemItems(let paths):
            if paths.isEmpty { return .noPaths }
            if paths.count > maxPaths { return .tooManyPaths }
            return paths.allSatisfy(isCleanAbsolutePath) ? nil : .invalidPath
        case .launchd(let label, let plistPath, _):
            guard isValidLabel(label) else { return .invalidLabel }
            if isAppleLabel(label) { return .appleLabel }
            guard isCleanAbsolutePath(plistPath), plistFolder(of: plistPath) != nil else { return .plistOutsideLaunchFolders }
            let fileName = (plistPath as NSString).lastPathComponent
            if fileName == label + ".plist" { return nil }
            guard fileName.hasSuffix(".plist"), plistLabel(plistPath) == label else { return .plistLabelMismatch }
            return nil
        }
    }

    /// Reverse-DNS: two or more dot-separated components of letters, digits, `-` and `_`; nothing else
    /// (no spaces, slashes, quotes, `;`, `..`, leading or trailing dots).
    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.utf8.count <= maxLabelLength else { return false }
        let parts = label.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard let first = part.unicodeScalars.first, isASCIIAlphanumeric(first) else { return false }
            for scalar in part.unicodeScalars where !(isASCIIAlphanumeric(scalar) || scalar == "-" || scalar == "_") {
                return false
            }
        }
        return true
    }

    public static func isAppleLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("com.apple.")
    }

    /// Absolute, already normalized (no `.`/`..`/empty components, no trailing slash), no control characters.
    public static func isCleanAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, path.utf8.count <= 1024, !path.hasSuffix("/") else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        for part in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    /// The launch folder a plist sits in directly (not in a subfolder), or nil.
    public static func plistFolder(of path: String) -> LaunchPlistFolder? {
        let ns = path as NSString
        guard ns.pathExtension == "plist" else { return nil }
        return LaunchPlistFolder(rawValue: ns.deletingLastPathComponent)
    }

    private static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9")
    }
}

/// Renders invocations for display, exactly as they run: arguments with spaces or shell metacharacters are
/// single-quoted, and multiple commands are joined with ` && ` (an operation stops at the first failing command).
public enum CommandLineFormatter {
    public static func format(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }

    public static func join(_ invocations: [(executable: String, arguments: [String])]) -> String {
        invocations.map { format($0.executable, $0.arguments) }.joined(separator: " && ")
    }

    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./,:=+@%")
        if !word.isEmpty && word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
