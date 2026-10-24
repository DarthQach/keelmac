import AppKit
import ProjectsKit
import SafetyKit

/// Projects state kept across navigation (C34): the last check of every project folder, the selection, and the
/// GitHub login gh reported. Checks are read-only; only Back up and Move to Trash change anything, after a preview.
@MainActor
@Observable
final class ProjectsModel {
    enum Phase: Equatable { case idle, checking, ready }

    enum Filter: String, CaseIterable, Identifiable {
        case all, safeToRemove, notBackedUp, noGit, keep
        var id: String { rawValue }

        func matches(_ scan: ProjectScan) -> Bool {
            switch self {
            case .all: true
            case .safeToRemove: scan.verdict == .safeToRemove
            case .notBackedUp: if case .notBackedUp = scan.verdict { true } else { false }
            case .noGit: scan.verdict == .noGit
            case .keep: scan.verdict == .keep
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var scans: [ProjectScan] = []
    private(set) var github: GitHubAvailability?
    private(set) var unreadableRoots: [String] = []
    private(set) var loadError: String?
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var checkedAt: Date?
    var selection: Set<ProjectScan.ID> = []
    var filter: Filter = .all
    var showTrashSheet = false
    var backupTarget: ProjectScan?
    var showBulkBackupSheet = false

    private let log: OperationLogging

    init(log: OperationLogging) {
        self.log = log
        if VisualFixtures.enabled {
            switch VisualFixtures.state {
            case "empty": phase = .ready
            case "loading": phase = .checking; checked = 3; total = 8
            case "error": loadError = String(localized: "Couldn’t read ~/Developer. Check that the folder exists, or choose another in Settings › Cleanup and safety.")
            default:
                scans = VisualFixtures.projects
                phase = .ready
                checkedAt = VisualFixtures.date
            }
            github = VisualFixtures.projectsGitHub
            switch VisualFixtures.argument("-fixture-projects-sheet") {
            case "trash":
                selection = Set(scans.filter(\.isTrashCandidate).map(\.id))
                showTrashSheet = true
            case "backup": backupTarget = scans.first { $0.verdict == .noGit }
            case "bulkBackup":
                selection = Set(scans.filter(\.canBackUp).map(\.id))
                bulkBackupChoice = selectedBackable
                showBulkBackupSheet = true
            default: break
            }
        }
    }

    // MARK: Settings

    var roots: [String] {
        get { UserDefaults.standard.stringArray(forKey: Preferences.Key.projectRoots) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Preferences.Key.projectRoots) }
    }
    var staleDays: Int { max(1, UserDefaults.standard.integer(forKey: Preferences.Key.projectStaleDays)) }
    /// UI tests with live data never reach GitHub, whatever the setting says.
    var verifyWithGitHub: Bool {
        !CommandLine.arguments.contains("-uitest") && UserDefaults.standard.bool(forKey: Preferences.Key.projectsVerifyGitHub)
    }

    // MARK: Derived

    var visible: [ProjectScan] { scans.filter(filter.matches) }
    func count(_ filter: Filter) -> Int { scans.filter(filter.matches).count }
    var trashCandidates: [ProjectScan] { scans.filter(\.isTrashCandidate) }
    var unverifiedCount: Int { scans.filter(\.needsVerification).count }
    var selectedScans: [ProjectScan] { scans.filter { selection.contains($0.id) } }
    var selectedTrashable: [ProjectScan] { selectedScans.filter(\.isTrashCandidate) }
    var selectedBytes: Int64 { selectedTrashable.reduce(0) { $0 + ($1.measure?.bytes ?? 0) } }

    func selectAllTrashable() { selection = Set(trashCandidates.map(\.id)) }

    /// Projects Back up can put on GitHub, in the filter shown: Not backed up or No git when one of them is chosen.
    var backUpCandidates: [ProjectScan] {
        switch filter {
        case .notBackedUp, .noGit: scans.filter { filter.matches($0) && $0.canBackUp }
        default: scans.filter(\.canBackUp)
        }
    }
    var selectedBackable: [ProjectScan] { selectedScans.filter(\.canBackUp) }
    var selectedBackableInFilter: [ProjectScan] { selectedBackable.filter(filter.matches) }
    var selectedBackableBytes: Int64 { selectedBackableInFilter.reduce(0) { $0 + ($1.measure?.bytes ?? 0) } }

    func selectAllBackable() { selection = Set(backUpCandidates.map(\.id)) }

    /// Opens the single-project sheet for one project and the batch sheet for several.
    func openBackup(_ chosen: [ProjectScan]) {
        let backable = chosen.filter(\.canBackUp)
        if backable.count == 1 {
            backupTarget = backable[0]
        } else if backable.count > 1 {
            bulkBackupChoice = backable
            showBulkBackupSheet = true
        }
    }

    /// What the batch sheet backs up, set when it opens.
    private(set) var bulkBackupChoice: [ProjectScan] = []

    // MARK: Checking

    private func scanner() -> ProjectScanner {
        ProjectScanner(runner: ProcessCommandRunner(), pathGuard: FileActions.pathGuard())
    }

    /// Checks every project folder. Read-only; reaches GitHub only when Verify with GitHub is on.
    func check() async {
        guard !VisualFixtures.enabled, phase != .checking else { return }
        let roots = self.roots
        loadError = nil
        guard !roots.isEmpty else { scans = []; phase = .idle; return }
        phase = .checking
        checked = 0
        total = 0
        let options = ProjectScanOptions(staleAfterDays: staleDays, verifyWithGitHub: verifyWithGitHub)
        var found: [ProjectScan] = []
        for await event in scanner().scan(roots: roots, options: options) {
            switch event {
            case .listed(let listing):
                total = listing.entries.count
                unreadableRoots = listing.unreadableRoots
            case .github(let availability):
                github = availability
            case .project(let scan):
                found.append(scan)
                checked += 1
                scans = found.sorted(by: ProjectScanner.order)
            case .finished(let all):
                scans = all
            }
        }
        if total == 0, unreadableRoots.count == roots.count {
            let list = roots.joined(separator: ", ")
            loadError = String(localized: "Couldn’t read \(list). Check that the folder exists, or choose another.")
        }
        let ids = Set(scans.map(\.id))
        selection = selection.filter(ids.contains)
        checkedAt = Date()
        phase = .ready
    }

    /// Checks one project again, with GitHub, after the user backed it up.
    func recheck(_ path: String) async {
        guard !VisualFixtures.enabled, let old = scans.first(where: { $0.path == path }) else { return }
        let options = ProjectScanOptions(staleAfterDays: staleDays, verifyWithGitHub: true)
        let updated = await scanner().scan(ProjectEntry(root: old.root, path: old.path, kind: .directory), options: options)
        if let index = scans.firstIndex(where: { $0.path == path }) { scans[index] = updated }
    }

    // MARK: Actions

    /// Moves the selected projects that are proved to be on GitHub to the Trash. Always the Trash, whatever the
    /// delete setting: a project is unique work, and the Trash is its undo.
    func trash(_ chosen: [ProjectScan]) async -> [RemovalOutcome] {
        let requests = chosen.filter(\.isTrashCandidate).map {
            RemovalRequest(path: $0.path, bytes: $0.measure?.bytes ?? 0, expectedModificationDate: $0.measure?.ownModified)
        }
        guard !requests.isEmpty else { return [] }
        let outcomes = await FileActions.remove(requests, context: .userFile, kind: .projects, title: String(localized: "Projects"),
                                                log: log, mode: .trash)
        let removed = Set(outcomes.filter(\.result.removedItem).map(\.path))
        scans.removeAll { removed.contains($0.path) }
        selection.subtract(removed)
        return outcomes
    }

    /// The gh login for Back up. Asks gh only when the last check didn't (verification off).
    func availabilityForBackup() async -> GitHubAvailability {
        if VisualFixtures.enabled { return VisualFixtures.projectsGitHub }
        if let github, case .available = github { return github }
        let availability = await scanner().githubAvailability(verify: true)
        github = availability
        return availability
    }

    /// Runs a previewed backup, logs every step, then checks the project again.
    func backUp(_ plan: BackupPlan, onStep: @escaping @Sendable (BackupStepOutcome) -> Void) async -> BackupResult? {
        guard !VisualFixtures.enabled else { return nil }
        let executor = BackupExecutor(runner: ProcessCommandRunner(), log: log)
        let result = await executor.execute(plan, title: String(localized: "Back up \(plan.projectName)"), onStep: onStep)
        await recheck(plan.projectPath)
        return result
    }

    /// Runs several previewed backups one after the other. Each project is checked again as soon as it finishes, so
    /// its row updates while the rest run. `shouldStop` is asked between projects.
    func backUp(_ plans: [BackupPlan], shouldStop: @escaping @Sendable () async -> Bool,
                onEvent: @escaping @Sendable (BackupBatchEvent) -> Void) async -> BackupBatchResult? {
        guard !VisualFixtures.enabled else { return nil }
        let executor = BackupExecutor(runner: ProcessCommandRunner(), log: log)
        return await executor.execute(plans, title: { String(localized: "Back up \($0.projectName)") }, shouldStop: shouldStop) { event in
            onEvent(event)
            // Read-only, so it can run while the next project pushes.
            if case .finished(let path, _) = event { Task { @MainActor in await self.recheck(path) } }
        }
    }
}
