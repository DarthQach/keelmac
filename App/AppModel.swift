import SwiftData
import SwiftUI
import AppsKit
import AssistantKit
import SafetyKit

/// Root state shared by the main window, Settings and the menu bar.
@MainActor
@Observable
final class AppModel {
    var route: Route = .dashboard
    var hasFullDiskAccess: Bool = VisualFixtures.enabled ? !["permission", "map-permission"].contains(VisualFixtures.state) : FullDiskAccess.isGranted()
    var showWelcome: Bool = false
    /// A short message shown as an alert (for example why an item was refused).
    var notice: String?
    let storage = StorageModel()

    /// True when the app runs under UI tests with fixture data and an in-memory store.
    let isUITesting = (CommandLine.arguments.contains("-uitest") || VisualFixtures.enabled)

    let container: ModelContainer
    let operationLog: OperationLogStore
    let snapshots: SnapshotService
    let helper = HelperService()
    let metrics = MetricsMonitor()
    let health = HealthService()
    let cleanup: CleanupModel
    let apps: AppsModel
    let projects: ProjectsModel
    let updater: Updater
    let assistant = AssistantModel()

    init() {
        container = Store.makeContainer(inMemory: (CommandLine.arguments.contains("-uitest") || VisualFixtures.enabled))
        operationLog = OperationLogStore(modelContainer: container)
        updater = Updater(start: !(CommandLine.arguments.contains("-uitest") || VisualFixtures.enabled))
        snapshots = SnapshotService(store: SnapshotStore(modelContainer: container))
        let health = self.health
        cleanup = CleanupModel(log: operationLog, onReclaimable: { health.recordReclaimable($0) })
        apps = AppsModel(log: operationLog, helper: helper, onStartupCounts: { health.recordStartupItems(total: $0, orphans: $1) })
        projects = ProjectsModel(log: operationLog)
        let log = operationLog
        Task.detached(priority: .background) { await log.prune(olderThan: Date().addingTimeInterval(-365 * 86_400)) }
        var fixtureBackend: (@Sendable (AssistantProvider, URL) -> any ChatBackend)?
        if isUITesting { fixtureBackend = { _, _ in FixtureChatBackend() as any ChatBackend } }
        let tools = AssistantTools.all(self)
        let routeOf: @MainActor () -> Route = { [unowned self] in self.route }
        assistant.configure(tools: tools, backend: fixtureBackend, route: routeOf)
        if VisualFixtures.enabled {
            for (i, file) in VisualFixtures.relatedFiles.enumerated() {
                container.mainContext.insert(OperationRecord(OperationEntry(batchID: UUID(), kind: .cleanup, title: "Cleanup",
                    path: file.path, bytes: file.bytes, result: i == 2 ? .skipped : .trashed, reason: i == 2 ? "Protected system location" : nil)))
            }
            try? container.mainContext.save()
            route = VisualFixtures.argument("-fixture-route").flatMap(Route.init(rawValue:)) ?? .dashboard
            return
        }
        let defaults = UserDefaults.standard
        if !isUITesting && !CommandLine.arguments.contains("-menuBarOnly") && !defaults.bool(forKey: Preferences.Key.welcomeShown) && !hasFullDiskAccess {
            showWelcome = true
        }
    }

    /// Starts background services once the UI is up.
    func start() {
        guard !VisualFixtures.enabled, !started else { return }
        started = true
        metrics.start()
        metrics.onAlert = { events in Task { await AlertNotifications.post(events) } }
        Notifier.shared.configure()
        Notifier.shared.onOpenURL = { [weak self] url in
            self?.open(url)
            NSApp.activate()
        }
        if !isUITesting { snapshots.startWeeklySchedule() }
        apps.updateTrashWatcher(enabled: UserDefaults.standard.bool(forKey: Preferences.Key.trashWatcher))
        if assistant.isEnabled, assistant.isPresented { assistant.refresh() }
        // Measure reclaimable space and startup items in the background so the Health Score is complete.
        Task {
            try? await Task.sleep(for: .seconds(8))
            if cleanup.phase == .idle { await cleanup.check(hasFullDiskAccess: hasFullDiskAccess) }
            if apps.launchItems == nil { await apps.loadLaunchItems() }
        }
    }

    private var started = false

    func refreshFullDiskAccess() {
        guard !VisualFixtures.enabled else { return }
        let granted = FullDiskAccess.isGranted()
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    func open(_ url: URL) {
        guard let route = Route(url: url) else { return }
        self.route = route
        if route == .apps, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "trashed" })?.value,
           PathGuard.isWithin(path, NSHomeDirectory() + "/.Trash"), let app = AppInventory.app(at: path) {
            apps.uninstallTarget = app
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
