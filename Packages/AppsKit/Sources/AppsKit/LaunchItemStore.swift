import Foundation
import SafetyKit

/// Login items and background agents from the three launchd folders.
public struct LaunchItemStore: Sendable {
    public static let launchctl = "/bin/launchctl"

    public let home: String
    public let uid: UInt32
    public let runner: CommandRunning
    public let installed: [InstalledApp]
    public let userAgentsFolder: String
    public let globalAgentsFolder: String
    public let globalDaemonsFolder: String

    public init(home: String, uid: UInt32, runner: CommandRunning, installed: [InstalledApp]) {
        self.init(home: home, uid: uid, runner: runner, installed: installed,
                  globalAgentsFolder: "/Library/LaunchAgents", globalDaemonsFolder: "/Library/LaunchDaemons")
    }

    /// Folders are injectable so tests read fixtures instead of /Library.
    public init(home: String, uid: UInt32, runner: CommandRunning, installed: [InstalledApp],
                userAgentsFolder: String? = nil, globalAgentsFolder: String, globalDaemonsFolder: String) {
        self.home = home; self.uid = uid; self.runner = runner; self.installed = installed
        self.userAgentsFolder = userAgentsFolder ?? (home as NSString).appendingPathComponent("Library/LaunchAgents")
        self.globalAgentsFolder = globalAgentsFolder; self.globalDaemonsFolder = globalDaemonsFolder
    }

    var guiDomain: String { "gui/\(uid)" }

    // MARK: - Listing

    public func list() async -> [LaunchItem] {
        let userDisabled = await disabledLabels(domain: guiDomain)
        let systemDisabled = await disabledLabels(domain: "system")
        var items: [LaunchItem] = []
        let folders: [(String, LaunchDomain)] = [(userAgentsFolder, .userAgent), (globalAgentsFolder, .globalAgent),
                                                 (globalDaemonsFolder, .globalDaemon)]
        for (folder, domain) in folders {
            for name in FileSizer.list(folder) where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let job = LaunchdPlist.read(path) else { continue }
                let overrides = domain == .globalDaemon ? systemDisabled : userDisabled
                let disabled = overrides[job.label] ?? job.disabledInPlist
                items.append(item(job: job, plistPath: path, domain: domain, disabled: disabled))
            }
        }
        return items.sorted {
            if $0.domain != $1.domain { return order($0.domain) < order($1.domain) }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private func order(_ d: LaunchDomain) -> Int {
        switch d { case .userAgent: 0; case .globalAgent: 1; case .globalDaemon: 2 }
    }

    /// `launchctl print-disabled <domain>`: label → disabled. Both output styles are understood:
    /// `"label" => disabled|enabled` (macOS 11+) and `"label" => true|false` (older; true means disabled).
    func disabledLabels(domain: String) async -> [String: Bool] {
        let result = await runner.run(Self.launchctl, ["print-disabled", domain], timeout: 10)
        guard result.succeeded else { return [:] }
        return Self.parseDisabled(result.stdout)
    }

    static func parseDisabled(_ output: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "disabled", "true": out[label] = true
            case "enabled", "false": out[label] = false
            default: continue
            }
        }
        return out
    }

    func item(job: LaunchdPlist, plistPath: String, domain: LaunchDomain, disabled: Bool) -> LaunchItem {
        let program = job.executable
        let programExists = program.map(Self.programExists) ?? false
        let owner = ownerApp(for: job)
        let ownerName: String?
        let ownerInstalled: Bool
        if let owner {
            ownerName = owner.name
            ownerInstalled = true
        } else {
            let appPath = job.mentionedPaths.lazy.compactMap(Self.enclosingApp).first
            let appExists = appPath.map(FileSizer.isDirectory) ?? false
            if let appPath, appExists, let info = BundleReader.read(bundle: appPath) {
                ownerName = info.displayName ?? info.bundleName ?? BundleReader.stem(of: appPath)
            } else {
                ownerName = appPath.map { BundleReader.stem(of: $0) }
            }
            if !programExists {
                ownerInstalled = false
            } else if appPath != nil {
                // An app outside the Applications folders (vendor support folders) still counts while it exists;
                // `/usr/bin/open -a /Applications/Gone.app` doesn't.
                ownerInstalled = appExists
            } else if let program, Self.isVendorHelperLocation(program) {
                ownerInstalled = false     // a vendor helper whose app is gone
            } else {
                ownerInstalled = true      // a standalone tool (Homebrew service, CLI): not an orphan
            }
        }
        return LaunchItem(label: job.label, plistPath: plistPath, program: program, domain: domain,
                          schedule: job.schedule, ownerName: ownerName, ownerInstalled: ownerInstalled,
                          isDisabled: disabled, ownerBundleID: owner?.bundleID, programExists: programExists)
    }

    /// The installed app a job belongs to: its program (or an argument) lives inside the bundle, it names the app
    /// in AssociatedBundleIdentifiers, its label is the bundle id or a sub-id, or it shares the app's vendor prefix.
    func ownerApp(for job: LaunchdPlist) -> InstalledApp? {
        let paths = job.mentionedPaths
        if let hit = installed.filter({ app in paths.contains { PathGuard.isWithin($0, app.path) } })
            .max(by: { $0.path.count < $1.path.count }) { return hit }
        for bid in job.associatedBundleIDs {
            if let hit = installed.first(where: { $0.bundleID?.caseInsensitiveCompare(bid) == .orderedSame }) { return hit }
        }
        let byLabel = installed.filter { app in app.bundleID.map { Identifiers.isOrSubID(job.label, of: $0) } ?? false }
        if let hit = byLabel.max(by: { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }) { return hit }
        if let vendor = Identifiers.vendorKey(job.label) {
            let peers = installed.filter { $0.bundleID.flatMap(Identifiers.vendorKey) == vendor }
            // The vendor's flagship tends to have the shortest id (com.google.Chrome before com.google.drivefs).
            if let hit = peers.min(by: { a, b in
                let la = a.bundleID?.count ?? 0, lb = b.bundleID?.count ?? 0
                return la != lb ? la < lb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }) { return hit }
        }
        return nil
    }

    static func programExists(_ program: String) -> Bool {
        if program.hasPrefix("/") { return FileSizer.exists(program) }
        // Looked up through launchd's default PATH.
        return ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
            .contains { FileSizer.exists($0 + "/" + program) }
    }

    /// The `.app` bundle a path points into, if any.
    static func enclosingApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func isVendorHelperLocation(_ program: String) -> Bool {
        program.hasPrefix("/Library/PrivilegedHelperTools/") || program.hasPrefix("/Library/Application Support/")
            || program.contains("/Library/Application Support/")
    }

    // MARK: - Changing

    /// Contract form. For /Library items nothing runs and the result has exit code 77 (EX_NOPERM) and stderr
    /// `needsHelper`; prefer `apply(_:enabled:)`, which says so in its type.
    public func setEnabled(_ item: LaunchItem, _ enabled: Bool) async -> CommandResult {
        switch await apply(item, enabled: enabled) {
        case .changed(let r), .failed(let r): return r
        case .needsHelper: return CommandResult(exitCode: 77, stdout: "", stderr: "needsHelper")
        }
    }

    /// User agents: `launchctl enable|disable gui/<uid>/<label>`, then `bootstrap gui/<uid> <plist>` after enabling
    /// or `bootout gui/<uid>/<label>` after disabling, so the change takes effect now. A bootstrap or bootout that
    /// fails because the job was already loaded or unloaded doesn't fail the change.
    public func apply(_ item: LaunchItem, enabled: Bool) async -> LaunchToggleOutcome {
        guard item.domain == .userAgent else { return .needsHelper(label: item.label, plistPath: item.plistPath) }
        let target = "\(guiDomain)/\(item.label)"
        let primary = await runner.run(Self.launchctl, [enabled ? "enable" : "disable", target], timeout: 15)
        guard primary.succeeded else { return .failed(primary) }
        if enabled {
            _ = await runner.run(Self.launchctl, ["bootstrap", guiDomain, item.plistPath], timeout: 15)
        } else {
            _ = await runner.run(Self.launchctl, ["bootout", target], timeout: 15)
        }
        return .changed(primary)
    }

    /// Before the app trashes a user agent's plist: `launchctl bootout gui/<uid>/<label>` so it stops running.
    /// /Library items need the helper (`LaunchdAction.remove`).
    public func unload(_ item: LaunchItem) async -> LaunchToggleOutcome {
        guard item.domain == .userAgent else { return .needsHelper(label: item.label, plistPath: item.plistPath) }
        let result = await runner.run(Self.launchctl, ["bootout", "\(guiDomain)/\(item.label)"], timeout: 15)
        // 3 (No such process) and 113 (not loaded) mean it was already stopped.
        return result.succeeded || result.exitCode == 3 || result.exitCode == 113 ? .changed(result) : .failed(result)
    }
}
