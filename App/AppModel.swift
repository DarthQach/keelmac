import SwiftData
import SwiftUI
import SafetyKit

/// Root state shared by the main window, Settings and the menu bar.
@MainActor
@Observable
final class AppModel {
    var route: Route = .dashboard
    var hasFullDiskAccess: Bool = FullDiskAccess.isGranted()
    var showWelcome: Bool = false

    /// True when the app runs under UI tests with fixture data and an in-memory store.
    let isUITesting = CommandLine.arguments.contains("-uitest")

    let container: ModelContainer
    let operationLog: OperationLogStore
    let snapshots: SnapshotService
    let helper = HelperService()

    init() {
        container = Store.makeContainer(inMemory: CommandLine.arguments.contains("-uitest"))
        operationLog = OperationLogStore(modelContainer: container)
        snapshots = SnapshotService(store: SnapshotStore(modelContainer: container))
        let log = operationLog
        Task.detached(priority: .background) { await log.prune(olderThan: Date().addingTimeInterval(-365 * 86_400)) }
        let defaults = UserDefaults.standard
        if !isUITesting && !defaults.bool(forKey: Preferences.Key.welcomeShown) && !hasFullDiskAccess {
            showWelcome = true
        }
    }

    /// Starts background services once the UI is up.
    func start() {
        guard !started else { return }
        started = true
        Notifier.shared.configure()
        Notifier.shared.onOpenURL = { [weak self] url in
            self?.open(url)
            NSApp.activate()
        }
        if !isUITesting { snapshots.startWeeklySchedule() }
    }

    private var started = false

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
        helper.refresh()
    }

    func open(_ url: URL) {
        if let route = Route(url: url) { self.route = route }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
