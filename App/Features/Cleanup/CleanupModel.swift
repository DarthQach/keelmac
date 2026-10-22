import AppKit
import CleanKit
import SafetyKit

/// Cleanup state kept across navigation: the dry-run plan, the user's selection and the last result (C12–C15).
@MainActor
@Observable
final class CleanupModel {
    enum Phase: Equatable {
        case idle, planning, ready, cleaning, done
    }

    private(set) var phase: Phase = .idle
    private(set) var plan: CleanupPlan?
    private(set) var result: CleanupResult?
    private(set) var loadError: String?
    var selected: Set<String> = []

    private let log: OperationLogging
    private let onReclaimable: (Int64) -> Void

    init(log: OperationLogging, onReclaimable: @escaping (Int64) -> Void) {
        self.log = log
        self.onReclaimable = onReclaimable
    }

    var selectedBytes: Int64 { plan?.bytes(selected: selected) ?? 0 }
    var selectedCount: Int { plan?.allItems.filter { selected.contains($0.id) }.count ?? 0 }
    var selectionDeletesPermanently: Bool {
        guard let plan else { return false }
        if FileActions.deleteMode == .permanent { return true }
        return plan.groups.contains { $0.deletesPermanently && $0.items.contains { selected.contains($0.id) } }
    }

    /// Builds the dry-run plan. Nothing is removed or run.
    func check(hasFullDiskAccess: Bool) async {
        guard phase != .planning, phase != .cleaning else { return }
        phase = .planning
        loadError = nil
        do {
            let rules = try RuleSet.bundled()
            let skipRunning = UserDefaults.standard.bool(forKey: Preferences.Key.skipRunningAppCaches)
            let running = skipRunning ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) : []
            let env = CleanupEnvironment(hasFullDiskAccess: hasFullDiskAccess, runningBundleIDs: running)
            let planner = CleanupPlanner(rules: rules, pathGuard: FileActions.pathGuard(), environment: env, runner: ProcessCommandRunner())
            let newPlan = await planner.plan()
            plan = newPlan
            selected = newPlan.defaultSelection()
            onReclaimable(newPlan.bytes(selected: selected))
            phase = .ready
        } catch {
            loadError = error.localizedDescription
            phase = .idle
        }
    }

    /// Removes exactly the selected plan items and logs every one.
    func clean() async {
        guard let plan, phase == .ready, !selected.isEmpty else { return }
        phase = .cleaning
        let remover = SafeRemover(pathGuard: FileActions.pathGuard(), mode: FileActions.deleteMode, context: .cleanup)
        let executor = CleanupExecutor(remover: remover, runner: ProcessCommandRunner(), log: log)
        let chosen = selected
        result = await executor.execute(plan, selected: chosen)
        phase = .done
    }

    func finish() {
        result = nil
        plan = nil
        phase = .idle
    }

    // MARK: Selection helpers

    enum CheckState { case on, off, mixed }

    func state(of ids: [String]) -> CheckState {
        let n = ids.filter(selected.contains).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggle(_ ids: [String]) {
        if state(of: ids) == .on { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
}
