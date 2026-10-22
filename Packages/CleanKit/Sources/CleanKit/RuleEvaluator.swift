import Darwin
import Foundation
import SafetyKit

/// A match a rule may offer, before sizing and age filters.
struct Candidate: Sendable {
    let match: GlobMatch
    let patternIndex: Int
    var skip: SkipReason?
    var detail: ItemDetail?
}

/// What evaluating one rule found before sizing.
struct RulePreparation: Sendable {
    let rule: CleanupRule
    var status: GroupStatus = .ready
    var candidates: [Candidate] = []
    var refused = 0
    var unreadable = 0
    var toolPath: String?
    /// Command rules: the item to offer (nil when there is nothing to do).
    var commandItem: CleanupItem?
    /// Folders a command manages; path rules never offer anything overlapping them.
    var claimedByCommand: [String] = []
}

/// Expands one rule against the environment: placeholders, globs, exclusions, PathGuard, running apps,
/// filters, tools and command measurements. Sizing and age/keep-newest filters happen in `finalize`.
struct RuleEvaluator: Sendable {
    let pathGuard: PathGuard
    let environment: CleanupEnvironment
    let runner: CommandRunning
    let home: String

    init(pathGuard: PathGuard, environment: CleanupEnvironment, runner: CommandRunning) {
        self.pathGuard = pathGuard
        self.environment = environment
        self.runner = runner
        self.home = PathGuard.canonical(PathGuard.normalize(environment.home))
    }

    // MARK: - Placeholders

    /// `~` → home, `{uid}` → uid, a leading `/Volumes` → `environment.volumesRoot`; then normalized.
    func resolve(_ pattern: String) -> String {
        var p = pattern.replacingOccurrences(of: CleanupRule.uidPlaceholder, with: String(environment.uid))
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if environment.volumesRoot != "/Volumes", PathGuard.isWithin(p, "/Volumes") {
            p = environment.volumesRoot + p.dropFirst("/Volumes".count)
        }
        return PathGuard.canonical(PathGuard.normalize(p))
    }

    // MARK: - Prepare

    func prepare(_ rule: CleanupRule) async -> RulePreparation {
        var prep = RulePreparation(rule: rule)
        if rule.needsAdmin { prep.status = .needsHelper; return prep }
        if rule.needsFullDiskAccess && !environment.hasFullDiskAccess { prep.status = .needsFullDiskAccess; return prep }
        switch rule.kind {
        case .command: await prepareCommand(rule, into: &prep)
        case .paths: await preparePaths(rule, into: &prep)
        }
        return prep
    }

    private func runningApp(in bundleIDs: [String]) -> String? {
        let running = Set(environment.runningBundleIDs.map { $0.lowercased() })
        return bundleIDs.first { running.contains($0.lowercased()) }
    }

    /// The running bundle id an item is named after: `com.foo.app` or `com.foo.app.helper`/`.ShipIt`.
    private func runningAppNaming(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        for id in environment.runningBundleIDs {
            let lower = id.lowercased()
            if name == lower || name.hasPrefix(lower + ".") { return id }
        }
        return nil
    }

    private func preparePaths(_ rule: CleanupRule, into prep: inout RulePreparation) async {
        let excludes = rule.exclude.map { GlobExpander.Exclusion(resolve($0)) }
        var seen = Set<String>()
        var matches: [(GlobMatch, Int)] = []
        for (index, pattern) in rule.paths.enumerated() {
            let resolved = resolve(pattern)
            let expansion = GlobExpander.expand(resolved)
            prep.unreadable += expansion.unreadable
            for m in expansion.matches where seen.insert(m.path).inserted { matches.append((m, index)) }
        }

        if rule.filter == .unsignedAppLanguages {
            matches = await languageMatches(apps: matches, rule: rule, unreadable: &prep.unreadable)
        }

        let ruleBlocker = runningApp(in: rule.skipIfRunning)
        if let ruleBlocker { prep.status = .appRunning(ruleBlocker) }

        for (match, index) in matches {
            if excludes.contains(where: { GlobExpander.isExcluded(match.path, by: $0) }) { continue }
            guard pathGuard.verdict(for: match.path, context: .cleanup).allowed else { prep.refused += 1; continue }
            var candidate = Candidate(match: match, patternIndex: index)
            if let ruleBlocker {
                candidate.skip = .appRunning(ruleBlocker)
            } else if rule.skipItemIfAppRunning, let id = runningAppNaming(match.path) {
                candidate.skip = .appRunning(id)
            }
            if rule.itemInfo == .iosBackup { candidate.detail = .iosBackup(Self.readBackupInfo(match.path)) }
            if rule.filter == .unsignedAppLanguages { candidate.detail = matchDetail(match) }
            prep.candidates.append(candidate)
        }
    }

    // MARK: - Language files

    private static let legacyLanguageNames: [String: String] = [
        "english": "en", "spanish": "es", "french": "fr", "german": "de", "japanese": "ja", "italian": "it",
        "dutch": "nl", "portuguese": "pt", "swedish": "sv", "danish": "da", "finnish": "fi", "norwegian": "no",
        "russian": "ru", "polish": "pl", "korean": "ko", "chinese": "zh",
    ]

    /// `en`, `en-GB`, `en_GB`, `English`, `zh-Hans` → `en`, `en`, `en`, `en`, `zh`. `Base` → `base`.
    static func languageCode(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let legacy = legacyLanguageNames[lower] { return legacy }
        return String(lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(lower))
    }

    private func matchDetail(_ match: GlobMatch) -> ItemDetail? {
        guard match.path.hasSuffix(".lproj") else { return nil }
        let resources = (match.path as NSString).deletingLastPathComponent
        let app = ((resources as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        guard app.hasSuffix(".app") else { return nil }
        let language = ((match.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return .appLanguage(appName: ((app as NSString).lastPathComponent as NSString).deletingPathExtension, appPath: app, language: language)
    }

    private func languageMatches(apps: [(GlobMatch, Int)], rule: CleanupRule, unreadable: inout Int) async -> [(GlobMatch, Int)] {
        let keep = Set((rule.keepLanguages + environment.preferredLanguages).map(Self.languageCode))
        var out: [(GlobMatch, Int)] = []
        for (app, index) in apps where app.isDirectory && !app.isSymlink && app.path.hasSuffix(".app") {
            var st = stat()
            if lstat(app.path + "/Contents/_CodeSignature", &st) == 0 { continue }
            // An embedded signature without the folder still counts as signed: removing files would break it.
            let check = await runner.run("/usr/bin/codesign", ["-dv", app.path], timeout: CommandMeasurer.checkTimeout)
            if check.exitCode == 0 { continue }
            let expansion = GlobExpander.expand(app.path + "/Contents/Resources/*.lproj")
            unreadable += expansion.unreadable
            for lproj in expansion.matches where lproj.isDirectory && !lproj.isSymlink {
                let language = ((lproj.path as NSString).lastPathComponent as NSString).deletingPathExtension
                if keep.contains(Self.languageCode(language)) { continue }
                out.append((lproj, index))
            }
        }
        return out
    }

    // MARK: - iOS backups

    static func readBackupInfo(_ folder: String) -> IOSBackupInfo {
        func plist(_ name: String) -> [String: Any]? {
            guard let data = FileManager.default.contents(atPath: folder + "/" + name) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        let info = plist("Info.plist")
        let manifest = plist("Manifest.plist")
        return IOSBackupInfo(
            deviceName: info?["Device Name"] as? String ?? info?["Display Name"] as? String,
            productType: info?["Product Type"] as? String,
            productVersion: info?["Product Version"] as? String,
            lastBackupDate: info?["Last Backup Date"] as? Date,
            isEncrypted: manifest?["IsEncrypted"] as? Bool)
    }

    // MARK: - Commands

    private func prepareCommand(_ rule: CleanupRule, into prep: inout RulePreparation) async {
        guard let spec = rule.command else { prep.status = .failed("missing command"); return }
        var tool: String?
        if !rule.toolPaths.isEmpty {
            tool = rule.toolPaths.map(resolve).first { $0.hasPrefix("/") && environment.isExecutable($0) }
            guard tool != nil else { prep.status = .toolMissing; return }
        }
        prep.toolPath = tool
        let executable = spec.resolvedExecutable(tool: tool)
        guard executable.hasPrefix("/"), executable != CleanupRule.toolPlaceholder, environment.isExecutable(executable) else {
            prep.status = .toolMissing; return
        }
        if let check = rule.toolCheck {
            let checkExecutable = check.resolvedExecutable(tool: tool)
            let r = await runner.run(checkExecutable, check.arguments, timeout: check.timeoutSeconds ?? CommandMeasurer.checkTimeout)
            if !r.succeeded {
                prep.status = .toolNotResponding(rule.requiresTool ?? (checkExecutable as NSString).lastPathComponent)
                return
            }
        }

        var extraPaths = (rule.measure ?? []).map(resolve)
        let measurement: CommandMeasurement
        switch rule.measureWith {
        case .simctlUnavailableDevices:
            measurement = .simctlUnavailableDevices(xcrun: tool ?? executable, devicesFolder: home + "/Library/Developer/CoreSimulator/Devices")
        case .dockerSystemDF:
            measurement = .dockerSystemDF(docker: tool ?? executable)
        case .pnpmStorePath:
            let r = await runner.run(tool ?? executable, ["store", "path"], timeout: CommandMeasurer.checkTimeout)
            guard r.succeeded, let store = CommandMeasurer.parseStorePath(r.stdout) else {
                prep.status = .failed(CommandMeasurer.failureText("pnpm store path", r)); return
            }
            extraPaths.append(PathGuard.canonical(store))
            measurement = .paths(extraPaths)
        case nil:
            measurement = extraPaths.isEmpty ? .none : .paths(extraPaths)
        }

        let measured: CommandMeasurer.Measured
        switch await CommandMeasurer.measure(measurement, runner: runner) {
        case .success(let m): measured = m
        case .failure(.toolMissing): prep.status = .toolMissing; return
        case .failure(.failed(let text)): prep.status = .failed(text); return
        }
        prep.claimedByCommand = measured.paths + extraPaths
        prep.unreadable += measured.unreadable

        let worthOffering: Bool
        switch measurement {
        case .none: worthOffering = true
        case .simctlUnavailableDevices: worthOffering = measured.detail != nil
        case .paths, .dockerSystemDF: worthOffering = measured.bytes > 0
        }
        if let blocker = runningApp(in: rule.skipIfRunning) { prep.status = .appRunning(blocker); return }
        guard worthOffering else { return }
        let invocation = CommandInvocation(executable: executable, arguments: spec.arguments,
                                           timeout: spec.timeoutSeconds ?? 600, measurement: measurement)
        prep.commandItem = CleanupItem(id: CleanupItem.commandID(rule: rule.id), ruleID: rule.id, path: invocation.commandLine,
                                       bytes: measured.bytes, modified: nil, isCommand: true, detail: measured.detail,
                                       command: invocation)
    }

    // MARK: - Finalize

    /// Applies sizes, keep-newest and minimum age, and builds the group.
    func finalize(_ prep: RulePreparation, sizes: [String: SizeInfo]) -> CleanupGroup {
        let rule = prep.rule
        var unreadable = prep.unreadable
        struct Sized { let candidate: Candidate; let info: SizeInfo; let newest: Date }
        var sized: [Sized] = []
        for c in prep.candidates {
            var info: SizeInfo
            if c.match.isDirectory && !c.match.isSymlink {
                guard let s = sizes[c.match.path], s.exists else { continue }
                info = s
            } else {
                info = SizeInfo(bytes: c.match.ownBytes, fileCount: 1, newestModified: c.match.modified, unreadable: 0,
                                ownModified: c.match.modified, isDirectory: false, exists: true)
            }
            unreadable += info.unreadable
            if info.newestModified == nil { info.newestModified = c.match.modified }
            sized.append(Sized(candidate: c, info: info, newest: info.newestModified ?? c.match.modified))
        }

        if rule.keepNewest > 0 {
            var kept = Set<String>()
            for index in Set(sized.map(\.candidate.patternIndex)) {
                let newestFirst = sized.filter { $0.candidate.patternIndex == index }
                    .sorted { $0.newest != $1.newest ? $0.newest > $1.newest : $0.candidate.match.path > $1.candidate.match.path }
                for s in newestFirst.prefix(rule.keepNewest) { kept.insert(s.candidate.match.path) }
            }
            sized.removeAll { kept.contains($0.candidate.match.path) }
        }
        if rule.minAgeDays > 0 {
            let cutoff = environment.now.addingTimeInterval(-Double(rule.minAgeDays) * 86_400)
            sized.removeAll { $0.newest > cutoff }
        }

        var items: [CleanupItem] = []
        var skipped: [SkippedItem] = []
        for s in sized {
            // Nothing to gain from an empty folder or a zero-byte file, except when emptying the Trash.
            if s.info.bytes == 0 && !rule.deletesPermanently { continue }
            let path = s.candidate.match.path
            if let reason = s.candidate.skip {
                skipped.append(SkippedItem(path: path, bytes: s.info.bytes, reason: reason))
                continue
            }
            items.append(CleanupItem(
                id: CleanupItem.pathID(rule: rule.id, path: path), ruleID: rule.id, path: path, bytes: s.info.bytes,
                modified: s.candidate.match.modified, isCommand: false, newestModified: s.newest,
                isDirectory: s.candidate.match.isDirectory, fileCount: s.info.fileCount, detail: s.candidate.detail))
        }
        if let commandItem = prep.commandItem { items.append(commandItem) }
        items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        skipped.sort { $0.bytes > $1.bytes }

        let status = prep.status
        return CleanupGroup(
            id: rule.id, rule: rule, items: status == .ready ? items : [],
            bytes: status == .ready ? items.reduce(0) { $0 + $1.bytes } : 0,
            status: status, selectedByDefault: status == .ready && !rule.optIn,
            skipped: skipped, unreadableCount: unreadable, refusedCount: prep.refused, toolPath: prep.toolPath)
    }
}
