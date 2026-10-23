import AppsKit
import CleanKit
import Foundation
import MetricsKit
import ProjectsKit
import ReportKit
import ScanKit
import SwiftUI

/// One "label: value" line the assistant can quote.
struct ContextFact: Hashable, Sendable {
    let label: String
    let value: String
}

/// One selected thing on screen, described by metadata only (never contents).
struct ContextItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case file, folder, app, process, cleanupGroup, leftoverGroup, launchItem, project }
    let id: String
    let kind: Kind
    let name: String
    let path: String?
    let fields: [ContextFact]
}

/// What the user is looking at: the screen, a few facts about it and the current selection.
struct ScreenContext: Hashable, Sendable {
    var route: Route
    var facts: [ContextFact] = []
    var selection: [ContextItem] = []

    static func routeOnly(_ route: Route) -> ScreenContext { ScreenContext(route: route) }

    /// True when `selection` is what the user picked (rather than the screen's own list).
    var hasUserSelection: Bool {
        !selection.isEmpty && [.largeOld, .storageMap, .apps, .cleanup, .projects].contains(route)
    }

    /// Plain text for the model, capped so a big selection can’t crowd out the conversation.
    func rendered(maxItems: Int = 12, maxBytes: Int = 1_500) -> String {
        var lines = ["Screen: \(route.name) — \(route.tagline)"]
        for f in facts { lines.append("\(f.label): \(f.value)") }
        if !selection.isEmpty {
            lines.append("Selected (\(selection.count)):")
            for item in selection.prefix(maxItems) {
                var parts = ["\(item.name) [\(item.kind.rawValue)]"]
                if let p = item.path { parts.append(Self.abbreviate(p)) }
                parts += item.fields.map { "\($0.label) \($0.value)" }
                lines.append("- " + parts.joined(separator: " · "))
            }
            if selection.count > maxItems { lines.append("- and \(selection.count - maxItems) more") }
        }
        var text = lines.joined(separator: "\n")
        if text.utf8.count > maxBytes {
            while text.utf8.count > maxBytes { text.removeLast() }
            text += "…"
        }
        return text
    }

    /// Suggestion chips for this screen, most useful first.
    var suggestions: [String] {
        switch route {
        case .largeOld, .storageMap, .systemData:
            if selection.isEmpty { return [String(localized: "What takes the most space here?"), String(localized: "What is safe to remove?")] }
            return selection.count == 1
                ? [String(localized: "What is this file?"), String(localized: "Is it safe to remove?"), String(localized: "Why is it so big?")]
                : [String(localized: "What are these files?"), String(localized: "Are they safe to remove?")]
        case .monitor:
            return [String(localized: "Why is CPU high?"), String(localized: "What is using memory?"), String(localized: "Is this temperature normal?")]
        case .dashboard:
            return [String(localized: "How do I raise my score?"), String(localized: "What should I do first?")]
        case .cleanup:
            return [String(localized: "What is safe to clean here?"), String(localized: "What does this category hold?")]
        case .apps:
            return selection.isEmpty ? [String(localized: "Which apps haven’t I used in months?")] : [String(localized: "What does this app leave behind?"), String(localized: "Is it safe to uninstall?")]
        case .leftovers:
            return [String(localized: "Are these leftovers safe to remove?")]
        case .loginItems:
            return [String(localized: "Which login items can I turn off?"), String(localized: "What does this item do?")]
        case .duplicates:
            return [String(localized: "Which copy should I keep?")]
        case .maintenance:
            return [String(localized: "Which task helps with a slow Mac?")]
        case .projects:
            return selection.isEmpty
                ? [String(localized: "Which projects are safe to remove?"), String(localized: "Which projects aren’t backed up?")]
                : [String(localized: "Why isn’t this project backed up?"), String(localized: "Is it safe to remove?")]
        case .snapshots:
            return [String(localized: "What grew the most?")]
        case .operationLog:
            return [String(localized: "What did KeelMac change recently?")]
        }
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Builders (plain functions so tests can render them without SwiftUI)

extension ScreenContext {
    static func largeFiles(shown: [ReviewRow], selected: [ReviewRow], minBytes: Int64, months: Int, now: Date = .now) -> ScreenContext {
        var c = ScreenContext(route: .largeOld)
        let total = shown.reduce(0) { $0 + $1.item.bytes }
        c.facts = [ContextFact(label: String(localized: "Showing"),
                               value: String(localized: "\(shown.count) files over \(Format.bytes(minBytes)) not opened in \(months) months, \(Format.bytes(total)) in all"))]
        c.selection = selected.map { row in
            var fields = [
                ContextFact(label: String(localized: "Size"), value: Format.bytes(row.item.bytes)),
                ContextFact(label: String(localized: "Kind"), value: row.item.kind.rawValue),
                ContextFact(label: String(localized: "Last opened"), value: row.item.lastOpened.map { Format.relative($0, now: now) } ?? String(localized: "Unknown")),
            ]
            if let owner = row.owner {
                fields.append(ContextFact(label: String(localized: "Used by"), value: owner.isRunning ? String(localized: "\(owner.name) (open now)") : owner.name))
            }
            switch row.status {
            case .locked(let app): fields.append(ContextFact(label: String(localized: "Status"), value: String(localized: "locked, \(app) is open")))
            case .recentlyUsed(let app, let date): fields.append(ContextFact(label: String(localized: "Status"), value: String(localized: "\(app) used it \(Format.relative(date, now: now))")))
            case .free: break
            }
            if case .ollamaRemove(let model) = row.item.removal { fields.append(ContextFact(label: String(localized: "Ollama model"), value: model)) }
            return ContextItem(id: row.id, kind: .file, name: row.item.name, path: row.item.path, fields: fields)
        }
        return c
    }

    @MainActor static func monitor(_ m: MetricsMonitor) -> ScreenContext {
        var c = ScreenContext(route: .monitor)
        if let s = m.latest {
            if let cpu = s.cpu { c.facts.append(ContextFact(label: "CPU", value: Format.percent(cpu.total))) }
            if let mem = s.memory {
                c.facts.append(ContextFact(label: String(localized: "Memory"), value: "\(Format.memory(mem.usedBytes)) of \(Format.memory(mem.totalBytes)), pressure \(mem.pressure)"))
                if mem.swapUsedBytes > 0 { c.facts.append(ContextFact(label: "Swap", value: Format.memory(mem.swapUsedBytes))) }
            }
            if let net = s.network { c.facts.append(ContextFact(label: String(localized: "Network"), value: "↓ \(Format.rate(net.bytesInPerSecond)) ↑ \(Format.rate(net.bytesOutPerSecond))")) }
        }
        if let t = m.temperature { c.facts.append(ContextFact(label: String(localized: "Temperature"), value: Format.temperature(t))) }
        if let b = m.battery, b.isPresent {
            var parts: [String] = []
            if let p = b.chargePercent { parts.append("\(p) %") }
            if let cap = b.maxCapacityPercent { parts.append(String(localized: "max capacity \(Format.percent(cap / 100))")) }
            if let cycles = b.cycleCount { parts.append(String(localized: "\(cycles) cycles")) }
            c.facts.append(ContextFact(label: String(localized: "Battery"), value: parts.joined(separator: ", ")))
        }
        let top = m.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)
        if !top.isEmpty {
            c.facts.append(ContextFact(label: String(localized: "Top processes"), value: top.map { "\($0.name) \(Format.percent($0.cpuPercent / 100))" }.joined(separator: ", ")))
        }
        return c
    }

    static func dashboard(report: HealthReport, inputs: HealthInputs) -> ScreenContext {
        var c = ScreenContext(route: .dashboard)
        c.facts.append(ContextFact(label: String(localized: "Health Score"), value: "\(report.score)/100 (\(report.band.rawValue))"))
        c.facts.append(ContextFact(label: String(localized: "Disk"), value: String(localized: "\(Format.bytes(inputs.diskAvailable)) free of \(Format.bytes(inputs.diskTotal))")))
        for f in report.factors { c.facts.append(ContextFact(label: f.id.rawValue, value: "\(f.points)/\(f.maxPoints)")) }
        return c
    }

    @MainActor static func cleanup(_ model: CleanupModel, category: CleanupCategory?, languageCode: String) -> ScreenContext {
        var c = ScreenContext(route: .cleanup)
        guard let plan = model.plan else {
            c.facts.append(ContextFact(label: String(localized: "Status"), value: model.phase == .planning ? String(localized: "checking") : String(localized: "not checked yet")))
            return c
        }
        let total = plan.groups.reduce(0) { $0 + $1.bytes }
        c.facts.append(ContextFact(label: String(localized: "Reclaimable"), value: String(localized: "\(Format.bytes(total)) in \(plan.groups.count) groups, \(Format.bytes(model.selectedBytes)) selected")))
        let groups = category.map { cat in plan.groups.filter { $0.rule.category == cat } } ?? []
        c.selection = groups.map { g in
            ContextItem(id: g.id, kind: .cleanupGroup, name: g.rule.title.value(for: languageCode), path: nil, fields: [
                ContextFact(label: String(localized: "Size"), value: Format.bytes(g.bytes)),
                ContextFact(label: String(localized: "Items"), value: "\(g.items.count)"),
                ContextFact(label: String(localized: "Status"), value: "\(g.status)"),
                ContextFact(label: String(localized: "Detail"), value: g.rule.detail.value(for: languageCode)),
            ])
        }
        return c
    }

    @MainActor static func apps(_ model: AppsModel, selected: InstalledApp?, now: Date = .now) -> ScreenContext {
        var c = ScreenContext(route: .apps)
        c.facts.append(ContextFact(label: String(localized: "Installed"), value: String(localized: "\(model.apps.count) apps")))
        if let app = selected {
            var fields = [ContextFact(label: String(localized: "Size"), value: app.bytes.map(Format.bytes) ?? String(localized: "Unknown"))]
            fields.append(ContextFact(label: String(localized: "Last used"), value: app.lastUsed.map { Format.relative($0, now: now) } ?? String(localized: "Unknown")))
            if let v = app.version { fields.append(ContextFact(label: String(localized: "Version"), value: v)) }
            if let b = app.bundleID { fields.append(ContextFact(label: "Bundle ID", value: b)) }
            c.selection = [ContextItem(id: app.id, kind: .app, name: app.name, path: app.path, fields: fields)]
        }
        return c
    }

    static func storageMap(tree: ScanTree, focus: NodeID, selected: NodeID?) -> ScreenContext {
        var c = ScreenContext(route: .storageMap)
        let f = tree.info(focus)
        c.facts.append(ContextFact(label: String(localized: "Folder"), value: "\(abbreviate(f.path)), \(Format.bytes(tree.bytes(of: focus)))"))
        if let selected {
            let i = tree.info(selected)
            c.selection = [ContextItem(id: i.path, kind: i.isDirectory ? .folder : .file, name: i.name, path: i.path, fields: [
                ContextFact(label: String(localized: "Size"), value: Format.bytes(tree.bytes(of: selected))),
                ContextFact(label: String(localized: "Items"), value: "\(i.fileCount)"),
                ContextFact(label: String(localized: "Modified"), value: Format.relative(i.modified)),
            ])]
        }
        return c
    }

    static func leftovers(_ groups: [LeftoverGroup]) -> ScreenContext {
        var c = ScreenContext(route: .leftovers)
        let total = groups.reduce(0) { $0 + $1.bytes }
        c.facts.append(ContextFact(label: String(localized: "Found"), value: String(localized: "\(groups.count) apps left \(Format.bytes(total)) behind")))
        c.selection = groups.prefix(12).map { g in
            ContextItem(id: g.id, kind: .leftoverGroup, name: g.displayName, path: nil, fields: [
                ContextFact(label: "Bundle ID", value: g.id),
                ContextFact(label: String(localized: "Size"), value: Format.bytes(g.bytes)),
                ContextFact(label: String(localized: "Files"), value: "\(g.files.count)"),
            ])
        }
        return c
    }

    @MainActor static func projects(_ model: ProjectsModel, selected: [ProjectScan], now: Date = .now) -> ScreenContext {
        var c = ScreenContext(route: .projects)
        c.facts.append(ContextFact(label: String(localized: "Folders"), value: model.roots.joined(separator: ", ")))
        guard model.phase != .idle || !model.scans.isEmpty else {
            c.facts.append(ContextFact(label: String(localized: "Status"), value: String(localized: "not checked yet")))
            return c
        }
        c.facts.append(ContextFact(label: String(localized: "Projects"), value: ProjectsModel.Filter.allCases.dropFirst()
            .map { "\($0.title): \(model.count($0))" }.joined(separator: ", ")))
        c.facts.append(ContextFact(label: String(localized: "Stale after"), value: String(localized: "\(model.staleDays) days without a commit or a file change")))
        c.facts.append(ContextFact(label: "GitHub", value: model.github?.title ?? String(localized: "not asked")))
        if model.unverifiedCount > 0 {
            c.facts.append(ContextFact(label: String(localized: "Unverified"), value: String(localized: "\(model.unverifiedCount) look safe but need Verify with GitHub before they can go to the Trash")))
        }
        c.selection = selected.prefix(12).map { p in
            var fields = [
                ContextFact(label: String(localized: "Status"), value: p.statusTitle),
                ContextFact(label: String(localized: "Last change"), value: p.lastChange.map { Format.relative($0, now: now) } ?? String(localized: "Unknown")),
                ContextFact(label: String(localized: "Size"), value: p.measure.map { Format.bytes($0.bytes) } ?? String(localized: "Unknown")),
                ContextFact(label: "GitHub", value: p.githubText),
            ]
            if !p.verdict.reasons.isEmpty { fields.append(ContextFact(label: String(localized: "Reasons"), value: p.verdict.reasons.map(\.text).joined(separator: "; "))) }
            if let git = p.git, git.ignoredCount > 0 { fields.append(ContextFact(label: String(localized: "Not in git"), value: git.ignoredPaths.prefix(5).joined(separator: ", "))) }
            return ContextItem(id: p.id, kind: .project, name: p.name, path: p.path, fields: fields)
        }
        return c
    }

    static func loginItems(_ items: [LaunchItem], advice: [String: LaunchAdvice]) -> ScreenContext {
        var c = ScreenContext(route: .loginItems)
        c.facts.append(ContextFact(label: String(localized: "Found"), value: String(localized: "\(items.count) items, \(items.filter { !$0.ownerInstalled }.count) without an installed app")))
        c.facts.append(ContextFact(label: "Counted for the score", value: "\(items.filter(\.countsTowardStartup).count) (enabled items that start on their own; \(HealthScore.startupItemAllowance) are free, every 3 more cost 1 point, each item from a deleted app costs 2)"))
        // Advised items first, so the 12 the model sees include every recommendation it may be asked about.
        let ordered = items.filter { advice[$0.id] != nil } + items.filter { advice[$0.id] == nil }
        c.selection = ordered.prefix(12).map { i in
            var fields = [
                ContextFact(label: String(localized: "Program"), value: i.program ?? String(localized: "Unknown")),
                ContextFact(label: String(localized: "Owner"), value: i.ownerName ?? String(localized: "Unknown")),
                ContextFact(label: String(localized: "Status"), value: i.isDisabled ? String(localized: "disabled") : String(localized: "enabled")),
            ]
            if let a = advice[i.id] { fields.append(ContextFact(label: "Advice", value: a.summary)) }
            return ContextItem(id: i.id, kind: .launchItem, name: i.label, path: i.plistPath, fields: fields)
        }
        return c
    }
}

extension Route {
    /// The screen's name in the user's language, as text the model can quote.
    var name: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .monitor: String(localized: "Monitor")
        case .storageMap: String(localized: "Storage map")
        case .largeOld: String(localized: "Review large files")
        case .systemData: String(localized: "System Data")
        case .duplicates: String(localized: "Duplicates")
        case .snapshots: String(localized: "Snapshots")
        case .cleanup: String(localized: "Cleanup")
        case .apps: String(localized: "Apps")
        case .leftovers: String(localized: "Leftovers")
        case .loginItems: String(localized: "Login items")
        case .maintenance: String(localized: "Maintenance")
        case .projects: String(localized: "Projects")
        case .operationLog: String(localized: "Operation log")
        }
    }

    var tagline: String {
        switch self {
        case .dashboard: String(localized: "A clear view of your Mac.")
        case .monitor: String(localized: "Live activity, at a glance.")
        case .storageMap: String(localized: "See where your space goes.")
        case .largeOld: String(localized: "Find what is worth keeping.")
        case .systemData: String(localized: "Understand the space behind System Data.")
        case .duplicates: String(localized: "Compare copies before removing them.")
        case .snapshots: String(localized: "See how your storage changes over time.")
        case .cleanup: String(localized: "More room. Every item in your control.")
        case .apps: String(localized: "Your apps and everything that comes with them.")
        case .leftovers: String(localized: "Review files left behind by removed apps.")
        case .loginItems: String(localized: "Know what starts with your Mac.")
        case .maintenance: String(localized: "Purposeful tools. Transparent commands.")
        case .projects: String(localized: "Keep what you work on. Let go of what GitHub already has.")
        case .operationLog: String(localized: "A record of every change.")
        }
    }
}

// MARK: - Publishing from views

extension View {
    /// Tells the Assistant what this screen shows and what is selected. Pass nil to fall back to the screen's name alone.
    func assistantContext(_ context: ScreenContext?) -> some View {
        modifier(AssistantContextModifier(context: context))
    }
}

private struct AssistantContextModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let context: ScreenContext?

    func body(content: Content) -> some View {
        content
            .onAppear { model.assistant.context = context }
            .onChange(of: context) { _, new in model.assistant.context = new }
            .onDisappear { if model.assistant.context?.route == context?.route { model.assistant.context = nil } }
    }
}

extension LaunchAdvice {
    /// English for the model, like the other non-localized context labels.
    var summary: String {
        let verb = action == .remove ? "remove" : "turn off"
        let why = switch reason {
        case .appGone: "its app is no longer installed"
        case .duplicate(let other): "the same label also runs from \(other)"
        case .updater: "it only checks for updates; the app updates itself when opened"
        case .appUnused(let lastUsed): "its app hasn't been opened since \(lastUsed.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(isStrong ? "recommended" : "worth a look"): \(verb), because \(why)"
    }
}
