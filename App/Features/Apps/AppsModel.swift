import AppKit
import AppsKit
import HelperShared
import SafetyKit

/// Installed apps, leftovers and launch items (C16–C20), shared by the Apps, Leftovers and Login items screens.
@MainActor
@Observable
final class AppsModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var loadingApps = false
    private(set) var leftovers: [LeftoverGroup]?
    private(set) var loadingLeftovers = false
    private(set) var launchItems: [LaunchItem]?
    private(set) var loadingLaunchItems = false
    var uninstallTarget: InstalledApp?

    private let log: OperationLogging
    private let helper: HelperService
    private let onStartupCounts: (Int, Int) -> Void
    private var watcher: TrashWatcher?

    init(log: OperationLogging, helper: HelperService, onStartupCounts: @escaping (Int, Int) -> Void) {
        self.log = log
        self.helper = helper
        self.onStartupCounts = onStartupCounts
        if VisualFixtures.enabled {
            apps = VisualFixtures.state == "empty" ? [] : VisualFixtures.apps
            leftovers = VisualFixtures.state == "empty" ? [] : [LeftoverGroup(id: "com.example.editor", displayName: "Previous editor", files: VisualFixtures.relatedFiles)]
            launchItems = VisualFixtures.state == "empty" ? [] : VisualFixtures.apps.prefix(4).map {
                LaunchItem(label: $0.bundleID ?? $0.name, plistPath: VisualFixtures.root + "/Library/LaunchAgents/\($0.name).plist",
                           program: nil, domain: .userAgent, schedule: .atLoad, ownerName: $0.name, ownerInstalled: true, isDisabled: false)
            }
            loadingApps = VisualFixtures.state == "loading"
            if loadingApps { apps = []; leftovers = nil; launchItems = nil }
        }
    }

    private var home: String { NSHomeDirectory() }

    func loadApps() async {
        guard !VisualFixtures.enabled, !loadingApps else { return }
        loadingApps = true
        let folders = AppInventory.defaultFolders(home: home)
        // Names first (fast), then sizes and last-used dates.
        let quick = await AppInventory.scan(folders: folders, measure: false)
        if apps.isEmpty { apps = quick.filter { !$0.isApple } }
        apps = await AppInventory.scan(folders: folders).filter { !$0.isApple }
        loadingApps = false
    }

    func loadLeftovers() async {
        guard !VisualFixtures.enabled, !loadingLeftovers else { return }
        loadingLeftovers = true
        if apps.isEmpty { await loadApps() }
        let installed = apps, home = self.home
        leftovers = await Task.detached(priority: .userInitiated) { OrphanFinder.find(home: home, installed: installed) }.value
        loadingLeftovers = false
    }

    func loadLaunchItems() async {
        guard !VisualFixtures.enabled, !loadingLaunchItems else { return }
        loadingLaunchItems = true
        if apps.isEmpty { await loadApps() }
        let store = LaunchItemStore(home: home, uid: getuid(), runner: ProcessCommandRunner(), installed: apps)
        let items = await store.list()
        launchItems = items
        onStartupCounts(items.count, items.filter { !$0.ownerInstalled }.count)
        loadingLaunchItems = false
    }

    // MARK: Uninstall

    func relatedFiles(for app: InstalledApp) async -> [RelatedFile] {
        if VisualFixtures.enabled { return VisualFixtures.relatedFiles }
        let installed = apps, home = self.home
        return await Task.detached(priority: .userInitiated) { RelatedFileMatcher.find(for: app, home: home, installed: installed) }.value
    }

    /// Moves the app and the chosen related files to the Trash; /Library items go through the helper.
    func uninstall(_ app: InstalledApp, files: [RelatedFile]) async -> [RemovalOutcome] {
        let title = String(localized: "Uninstall \(app.name)")
        // An app the user already moved to the Trash stays there; only its related files are removed.
        let inTrash = PathGuard.isWithin(app.path, home + "/.Trash")
        var requests = inTrash ? [] : [RemovalRequest(path: app.path, bytes: app.bytes ?? 0)]
        requests += files.filter { !$0.needsHelper }.map { RemovalRequest(path: $0.path, bytes: $0.bytes, expectedModificationDate: $0.modified) }
        var outcomes = await FileActions.remove(requests, context: .uninstall, kind: .uninstall, title: title, log: log, mode: .trash)
        let system = files.filter(\.needsHelper)
        if !system.isEmpty {
            outcomes += await removeWithHelper(system.map(\.path), kind: .uninstall, title: title)
        }
        apps.removeAll { a in outcomes.contains { $0.path == a.path && $0.result.removedItem } }
        return outcomes
    }

    func removeWithHelper(_ paths: [String], kind: OperationKind, title: String) async -> [RemovalOutcome] {
        guard helper.isEnabled else {
            let outcomes = paths.map { RemovalOutcome(path: $0, bytes: 0, result: .skipped, reason: RefusalReason.needsHelper.englishDescription, refusal: .needsHelper) }
            await log.record(SafeRemover.entries(outcomes, batchID: UUID(), kind: kind, title: title))
            return outcomes
        }
        do {
            let response = try await helper.client.perform(.removeSystemItems(paths: paths))
            let outcomes = response.outcomes.map { RemovalOutcome(path: $0.path, bytes: $0.bytes, result: $0.result, reason: $0.reason, refusal: $0.refusal) }
            await log.record(SafeRemover.entries(outcomes, batchID: UUID(), kind: kind, title: title))
            return outcomes
        } catch {
            let outcomes = paths.map { RemovalOutcome(path: $0, bytes: 0, result: .failed, reason: "The helper didn’t respond", refusal: nil) }
            await log.record(SafeRemover.entries(outcomes, batchID: UUID(), kind: kind, title: title))
            return outcomes
        }
    }

    // MARK: Leftovers

    func removeLeftovers(_ files: [RelatedFile]) async -> [RemovalOutcome] {
        let outcomes = await FileActions.remove(files.map { RemovalRequest(path: $0.path, bytes: $0.bytes, expectedModificationDate: $0.modified) },
                                                context: .cleanup, kind: .leftovers, title: String(localized: "Leftovers"), log: log)
        let removed = Set(outcomes.filter(\.result.removedItem).map(\.path))
        leftovers = leftovers?.compactMap { g in
            let rest = g.files.filter { !removed.contains($0.path) }
            return rest.isEmpty ? nil : LeftoverGroup(id: g.id, displayName: g.displayName, files: rest, lastModified: g.lastModified)
        }
        return outcomes
    }

    // MARK: Launch items

    func setEnabled(_ item: LaunchItem, _ enabled: Bool) async -> String? {
        guard !VisualFixtures.enabled else { return nil }
        let title = String(localized: "Login items")
        let result: String?
        if item.needsHelper {
            guard helper.isEnabled else { return RefusalReason.needsHelper.englishDescription }
            do {
                let r = try await helper.client.perform(.launchd(label: item.label, plistPath: item.plistPath, action: enabled ? .enable : .disable))
                result = r.exitCode == 0 ? nil : (r.rejection?.englishDescription ?? "Exit code \(r.exitCode)")
            } catch {
                result = "The helper didn’t respond"
            }
        } else {
            let store = LaunchItemStore(home: home, uid: getuid(), runner: ProcessCommandRunner(), installed: apps)
            switch await store.apply(item, enabled: enabled) {
            case .changed: result = nil
            case .failed(let r): result = "Exit code \(r.exitCode)"
            case .needsHelper: result = RefusalReason.needsHelper.englishDescription
            }
        }
        await log.record([OperationEntry(batchID: UUID(), kind: .loginItem, title: title, path: item.plistPath, bytes: 0,
                                         result: result == nil ? (enabled ? .enabled : .disabled) : .failed, reason: result)])
        await loadLaunchItems()
        return result
    }

    func remove(_ item: LaunchItem) async -> String? {
        guard !VisualFixtures.enabled else { return nil }
        let title = String(localized: "Login items")
        if item.needsHelper {
            guard helper.isEnabled else { return RefusalReason.needsHelper.englishDescription }
            do {
                let r = try await helper.client.perform(.launchd(label: item.label, plistPath: item.plistPath, action: .remove))
                let outcomes = r.outcomes.map { RemovalOutcome(path: $0.path, bytes: $0.bytes, result: $0.result, reason: $0.reason, refusal: $0.refusal) }
                await log.record(SafeRemover.entries(outcomes, batchID: UUID(), kind: .loginItem, title: title))
                await loadLaunchItems()
                return r.exitCode == 0 ? nil : (r.rejection?.englishDescription ?? outcomes.first?.reason ?? "Exit code \(r.exitCode)")
            } catch {
                return "The helper didn’t respond"
            }
        }
        let store = LaunchItemStore(home: home, uid: getuid(), runner: ProcessCommandRunner(), installed: apps)
        _ = await store.unload(item)
        let out = await FileActions.remove([RemovalRequest(path: item.plistPath, bytes: 0)], context: .cleanup, kind: .loginItem, title: title, log: log, mode: .trash)
        await loadLaunchItems()
        return out.first?.result.removedItem == true ? nil : out.first?.reason
    }

    // MARK: Trash watcher (C18)

    func updateTrashWatcher(enabled: Bool) {
        guard !VisualFixtures.enabled else { return }
        if enabled, watcher == nil {
            let w = TrashWatcher(trashPath: home + "/.Trash") { appPath, bundleID, name in
                var components = URLComponents(string: "keelmac://open/apps")!
                components.queryItems = [URLQueryItem(name: "trashed", value: appPath)]
                let url = components.url
                Task {
                    await Notifier.shared.post(id: "trashed-\(bundleID ?? name)", title: String(localized: "Clean up after \(name)?"),
                                               body: String(localized: "You moved \(name) to the Trash. KeelMac can show the files it left in your Library."),
                                               category: .trashedApp, url: url)
                }
            }
            w.start()
            watcher = w
        } else if !enabled {
            watcher?.stop()
            watcher = nil
        }
    }
}
