import AppKit
import AppsKit
import AssistantKit
import CleanKit
import Foundation
import MetricsKit
import ReportKit
import SafetyKit
import ScanKit

/// Read-only lookups the model may run. None of them removes, runs a command or changes a setting.
enum AssistantTools {
    static let outputCap = 4_000

    @MainActor static func all(_ app: AppModel) -> [any AssistantTool] {
        [GetHealthTool(app: app), GetMetricsTool(app: app), ListTopProcessesTool(app: app), ListLargeFilesTool(app: app),
         InspectPathTool(app: app), GetCleanupSummaryTool(app: app), ListLeftoversTool(app: app), ListLoginItemsTool(app: app)]
    }

    static func cap(_ text: String) -> String {
        guard text.utf8.count > outputCap else { return text }
        return String(text.prefix(outputCap)) + "\n… (cut; ask with a smaller limit)"
    }

    static func date(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown" }
}

struct GetHealthTool: AssistantTool {
    let app: AppModel
    let name = "get_health"
    let description = "KeelMac's Health Score (0-100) with its five factors and the numbers behind them."
    let parameters: JSONValue = .schema()

    func call(_ arguments: JSONValue) async throws -> String { await Self.render(app) }

    @MainActor static func render(_ app: AppModel) -> String {
        let report = HealthScore.compute(app.health.inputs(metrics: app.metrics))
        var lines = ["Health Score \(report.score)/100 (\(report.band.rawValue))."]
        for f in report.factors {
            var line = "\(f.id.rawValue): \(f.points)/\(f.maxPoints)"
            switch f.details {
            case .diskFree(let total, let available, let used, _):
                line += " — \(Format.bytes(available)) free of \(Format.bytes(total)), \(Format.percent(used)) used"
            case .memoryPressure(let warning, let critical):
                line += " — memory pressure in the last hour: warning \(Format.percent(warning)), critical \(Format.percent(critical))"
            case .battery(let has, let capacity, let cycles):
                line += has ? " — max capacity \(capacity.map { Format.percent($0 / 100) } ?? "unknown"), \(cycles.map(String.init) ?? "unknown") cycles" : " — no battery (desktop Mac)"
            case .reclaimable(let bytes, let fraction):
                line += bytes.map { " — \(Format.bytes($0)) reclaimable in Cleanup (\(Format.percent(fraction ?? 0)) of the disk)" } ?? " — not measured yet (Cleanup › Check again)"
            case .startupItems(let total, let orphans, let over):
                line += " — \(total) login items, \(orphans) without an installed app, \(over) over the allowance"
            }
            if let fix = f.fix, let route = Route(rawValue: fix.rawValue) { line += " · fix in \(route.name) (keelmac://open/\(route.rawValue))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

struct GetMetricsTool: AssistantTool {
    let app: AppModel
    let name = "get_metrics"
    let description = "Live CPU, memory, disk, network, temperature, battery and uptime, plus the Mac model and chip."
    let parameters: JSONValue = .schema()

    func call(_ arguments: JSONValue) async throws -> String { await Self.render(app) }

    @MainActor static func render(_ app: AppModel) -> String {
        let m = app.metrics
        var lines: [String] = []
        let info = m.systemInfo
        lines.append("Mac: \(info.modelName), \(info.chip), \(info.coreCount) cores, \(Format.memory(info.memoryBytes)) memory, macOS \(info.macOSVersion), up \(Format.relative(info.bootDate).replacingOccurrences(of: " ago", with: ""))")
        guard let s = m.latest else { lines.append("No sample yet."); return lines.joined(separator: "\n") }
        if let cpu = s.cpu { lines.append("CPU: \(Format.percent(cpu.total)) total (user \(Format.percent(cpu.user)), system \(Format.percent(cpu.system)))") }
        if let mem = s.memory {
            lines.append("Memory: \(Format.memory(mem.usedBytes)) used of \(Format.memory(mem.totalBytes)), pressure \(mem.pressure), app \(Format.memory(mem.appBytes)), wired \(Format.memory(mem.wiredBytes)), compressed \(Format.memory(mem.compressedBytes)), swap \(Format.memory(mem.swapUsedBytes))")
        }
        if let d = s.disk { lines.append("Disk \(d.volumeName): \(Format.bytes(d.availableBytes)) free of \(Format.bytes(d.totalBytes))") }
        if let n = s.network { lines.append("Network: in \(Format.rate(n.bytesInPerSecond)), out \(Format.rate(n.bytesOutPerSecond))") }
        lines.append("Temperature: \(m.temperature.map(Format.temperature) ?? "unavailable")")
        if let b = m.battery, b.isPresent {
            lines.append("Battery: \(b.chargePercent.map { "\($0) %" } ?? "unknown") charge, \(b.isCharging ? "charging" : (b.isPluggedIn ? "plugged in" : "on battery")), max capacity \(b.maxCapacityPercent.map { Format.percent($0 / 100) } ?? "unknown"), \(b.cycleCount.map(String.init) ?? "unknown") cycles, condition \(b.condition ?? "unknown")")
        } else {
            lines.append("Battery: none")
        }
        return lines.joined(separator: "\n")
    }
}

struct ListTopProcessesTool: AssistantTool {
    let app: AppModel
    let name = "list_top_processes"
    let description = "The processes using the most CPU or memory right now. Other users' and system processes show 0 (the kernel hides them)."
    let parameters: JSONValue = .schema(properties: [
        "sortBy": .property("string", "cpu or memory", enum: ["cpu", "memory"]),
        "limit": .property("integer", "How many, 1-15 (default 10)"),
    ])

    func call(_ arguments: JSONValue) async throws -> String {
        let byMemory = arguments["sortBy"]?.stringValue == "memory"
        let limit = min(max(arguments["limit"]?.intValue ?? 10, 1), 15)
        let processes = await Self.sample(app)
        guard !processes.isEmpty else { return "No process sample yet; try again in a few seconds." }
        let sorted = byMemory ? processes.sorted { $0.memoryBytes > $1.memoryBytes } : processes.sorted { $0.cpuPercent > $1.cpuPercent }
        let lines = sorted.prefix(limit).map { p in
            "\(p.name) (pid \(p.id)): CPU \(String(format: "%.1f", p.cpuPercent)) % (100 = one core), memory \(Format.memory(p.memoryBytes)), user \(p.userName)\(p.bundleIdentifier.map { ", \($0)" } ?? "")"
        }
        return (["Sorted by \(byMemory ? "memory" : "CPU"):"] + lines).joined(separator: "\n")
    }

    /// Turns detailed sampling on just long enough to get one process list.
    @MainActor static func sample(_ app: AppModel) async -> [ProcessSample] {
        let m = app.metrics
        let before = m.latest?.date
        m.beginDetailed()
        defer { m.endDetailed() }
        for _ in 0..<15 {
            if !m.processes.isEmpty, VisualFixtures.enabled || m.latest?.date != before { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return m.processes
    }
}

struct ListLargeFilesTool: AssistantTool {
    let app: AppModel
    let name = "list_large_files"
    let description = "The largest files from the last storage scan: path, size, kind, when it was last opened and which app owns it."
    let parameters: JSONValue = .schema(properties: [
        "minBytes": .property("integer", "Only files at least this big, in bytes (default 500000000)"),
        "limit": .property("integer", "How many, 1-20 (default 10)"),
        "kind": .property("string", "Only this kind", enum: FileKind.allCases.map(\.rawValue)),
    ])

    func call(_ arguments: JSONValue) async throws -> String {
        let minBytes = Int64(max(arguments["minBytes"]?.intValue ?? 500_000_000, 1_000_000))
        let limit = min(max(arguments["limit"]?.intValue ?? 10, 1), 20)
        let kind = arguments["kind"]?.stringValue.flatMap(FileKind.init(rawValue:))
        guard let tree = await app.storage.tree else {
            return "No storage scan yet. Suggest Storage map › Scan disk (keelmac://open/storageMap)."
        }
        let home = NSHomeDirectory()
        let rows = await Task.detached(priority: .userInitiated) {
            OwnerResolver.rows(for: ReviewFinder.find(in: tree, home: home, minBytes: minBytes, notOpenedSince: nil))
        }.value
        let chosen = rows.filter { kind == nil || $0.item.kind == kind }.prefix(limit)
        guard !chosen.isEmpty else { return "No files over \(Format.bytes(minBytes))\(kind.map { " of kind \($0.rawValue)" } ?? ")") in the scan." }
        let lines = chosen.map { r -> String in
            var parts = ["\(ScreenContext.abbreviate(r.item.path)) · \(Format.bytes(r.item.bytes)) · \(r.item.kind.rawValue) · last opened \(AssistantTools.date(r.item.lastOpened))"]
            if let o = r.owner { parts.append("used by \(o.name)\(o.isRunning ? " (open now)" : "")") }
            if r.isLocked { parts.append("locked") }
            return parts.joined(separator: " · ")
        }
        return AssistantTools.cap(lines.joined(separator: "\n"))
    }
}

struct InspectPathTool: AssistantTool {
    let app: AppModel
    let name = "inspect_path"
    let description = "Metadata for one path: whether it exists, size, kind, dates, the app that owns it and whether KeelMac would allow removing it. Never reads the contents."
    let parameters: JSONValue = .schema(properties: ["path": .property("string", "Absolute path, ~ allowed")], required: ["path"])

    func call(_ arguments: JSONValue) async throws -> String {
        guard let raw = arguments["path"]?.stringValue, !raw.isEmpty else { throw AssistantError.toolFailed(name: name, "path is required") }
        let home = NSHomeDirectory()
        let (path, verdict, tree) = await MainActor.run {
            let pathGuard = FileActions.pathGuard()
            let p = pathGuard.expandTilde(raw)
            return (p, pathGuard.verdict(for: p, context: .userFile), app.storage.tree)
        }
        return await Task.detached(priority: .userInitiated) { Self.describe(path: path, verdict: verdict, tree: tree, home: home) }.value
    }

    static func describe(path: String, verdict: PathVerdict, tree: ScanTree?, home: String) -> String {
        var o: [String: JSONValue] = ["path": .string(ScreenContext.abbreviate(path))]
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        guard let values else {
            o["exists"] = false
            return render(o)
        }
        let isDir = values.isDirectory ?? false
        o["exists"] = true
        o["isDirectory"] = .bool(isDir)
        if values.isPackage == true { o["isPackage"] = true }
        if isDir {
            if let tree, let id = tree.lookup(path: path) {
                o["bytes"] = .string(Format.bytes(tree.bytes(of: id)))
                o["items"] = .number(Double(tree.info(id).fileCount))
                o["bytesSource"] = "storage scan"
            } else {
                o["bytes"] = "not measured (scan the disk for folder sizes)"
            }
        } else {
            let bytes = values.totalFileAllocatedSize ?? values.fileSize ?? 0
            o["bytes"] = .string(Format.bytes(Int64(bytes)))
            o["kind"] = .string(FileKind.of(path: path).rawValue)
        }
        o["created"] = .string(AssistantTools.date(values.creationDate))
        o["modified"] = .string(AssistantTools.date(values.contentModificationDate))
        o["lastOpened"] = .string(AssistantTools.date(LargeFileFinder.spotlightLastOpened(path)))
        if let rel = ReviewFinder.relative(path, to: home) {
            let owner = ReviewFinder.owner(ofRelative: rel)
            if owner != .none, let app = OwnerResolver.resolve(owner) {
                var ownerObject: [String: JSONValue] = ["name": .string(app.name), "isOpenNow": .bool(app.isRunning)]
                if let b = app.bundleID { ownerObject["bundleID"] = .string(b) }
                if let u = app.lastUsed { ownerObject["lastUsed"] = .string(AssistantTools.date(u)) }
                o["owner"] = .object(ownerObject)
            }
            if ReviewFinder.isModelStorage(path, home: home) { o["isAIModelStorage"] = true }
        }
        o["removal"] = verdict.allowed ? "KeelMac would allow moving it to the Trash" : .string("KeelMac refuses: \(verdict.reason?.englishDescription ?? "protected")")
        return render(o)
    }

    private static func render(_ o: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(JSONValue.object(o))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

struct GetCleanupSummaryTool: AssistantTool {
    let app: AppModel
    let name = "get_cleanup_summary"
    let description = "What KeelMac's Cleanup check found: each group with its size, item count and status. Runs the check (a dry run) if it hasn't run yet."
    let parameters: JSONValue = .schema()

    func call(_ arguments: JSONValue) async throws -> String {
        let lang = AssistantPrompt.languageCode
        return await MainActor.run { () -> Task<String, Never> in
            Task { @MainActor in
                let cleanup = app.cleanup
                if cleanup.plan == nil, cleanup.phase == .idle { await cleanup.check(hasFullDiskAccess: app.hasFullDiskAccess) }
                guard let plan = cleanup.plan else { return cleanup.loadError.map { "Cleanup check failed: \($0)" } ?? "Cleanup is still checking; ask again in a moment." }
                let total = plan.groups.reduce(0) { $0 + $1.bytes }
                var lines = ["\(Format.bytes(total)) reclaimable in \(plan.groups.count) groups; \(Format.bytes(cleanup.selectedBytes)) selected. Cleanup › Clean (keelmac://open/cleanup)."]
                for g in plan.groups.sorted(by: { $0.bytes > $1.bytes }) {
                    let selected = cleanup.state(of: g.items.map(\.id))
                    lines.append("\(g.rule.title.value(for: lang)) [\(g.rule.category.rawValue)]: \(Format.bytes(g.bytes)), \(g.items.count) items, status \(g.status), \(selected == .on ? "selected" : selected == .mixed ? "partly selected" : "not selected")\(g.rule.optIn ? ", opt-in" : "")")
                }
                return AssistantTools.cap(lines.joined(separator: "\n"))
            }
        }.value
    }
}

struct ListLeftoversTool: AssistantTool {
    let app: AppModel
    let name = "list_leftovers"
    let description = "Files left behind by apps that are no longer installed, grouped by app, with sizes."
    let parameters: JSONValue = .schema()

    func call(_ arguments: JSONValue) async throws -> String {
        await MainActor.run { () -> Task<String, Never> in
            Task { @MainActor in
                let apps = app.apps
                if apps.leftovers == nil { await apps.loadLeftovers() }
                guard let groups = apps.leftovers else { return "Leftovers haven't been searched yet. Open Leftovers (keelmac://open/leftovers)." }
                guard !groups.isEmpty else { return "No leftovers found." }
                let lines = groups.sorted { $0.bytes > $1.bytes }.prefix(25).map { g in
                    "\(g.displayName) (\(g.id)): \(Format.bytes(g.bytes)) in \(g.files.count) files, e.g. \(g.files.prefix(2).map { ScreenContext.abbreviate($0.path) }.joined(separator: ", "))"
                }
                return AssistantTools.cap((["Leftovers › Remove (keelmac://open/leftovers):"] + lines).joined(separator: "\n"))
            }
        }.value
    }
}

struct ListLoginItemsTool: AssistantTool {
    let app: AppModel
    let name = "list_login_items"
    let description = "Login items and background agents: label, program, domain, schedule, owner and whether they are disabled."
    let parameters: JSONValue = .schema()

    func call(_ arguments: JSONValue) async throws -> String {
        await MainActor.run { () -> Task<String, Never> in
            Task { @MainActor in
                let apps = app.apps
                if apps.launchItems == nil { await apps.loadLaunchItems() }
                guard let items = apps.launchItems else { return "Login items haven't been listed yet. Open Login items (keelmac://open/loginItems)." }
                guard !items.isEmpty else { return "No login items." }
                let lines = items.prefix(40).map { i in
                    "\(i.label): \(i.program.map(ScreenContext.abbreviate) ?? "unknown program"), \(i.domain.rawValue), \(i.schedule), owner \(i.ownerName ?? "unknown")\(i.ownerInstalled ? "" : " (app not installed)")\(i.isDisabled ? ", disabled" : "")"
                }
                return AssistantTools.cap((["Login items (keelmac://open/loginItems):"] + lines).joined(separator: "\n"))
            }
        }.value
    }
}
