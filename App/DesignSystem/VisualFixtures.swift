import AppKit
import AppsKit
import CleanKit
import DuplicatesKit
import MetricsKit
import ProjectsKit
import ReportKit
import ScanKit
import SafetyKit
import SwiftUI

/// Opt-in, debug-only presentation data. Never starts real readers, commands or removals.
/// Release builds cannot enable this mode.
enum VisualFixtures {
    static var enabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-visual-fixtures") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }
    static var state: String { argument("-fixture-state") ?? "ready" }
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static let root = NSTemporaryDirectory() + "KeelMac-Visual-Fixtures"
    static var date: Date { Date().addingTimeInterval(-120) }
    static let system = SystemInfo(modelName: "MacBook Pro", modelIdentifier: "Mac", chip: "Apple M3 Pro", macOSVersion: "14.7",
                                   coreCount: 12, memoryBytes: 36 * 1_073_741_824, bootDate: Date().addingTimeInterval(-280_000))
    static var battery: BatteryInfo {
        state == "unavailable" ? .absent : BatteryInfo(isPresent: true, chargePercent: 84, isCharging: false, isPluggedIn: false,
            cycleCount: 124, maxCapacityPercent: 96, condition: "Normal", temperatureCelsius: 31, timeRemainingMinutes: 420)
    }
    static var processes: [ProcessSample] {
        ["WindowServer", "Safari", "Xcode", "KeelMac", "Finder", "Music"].enumerated().map { i, name in
            ProcessSample(id: Int32(900_000 + i), name: name, userName: "demo", uid: 501, cpuPercent: Double(18 - i * 3),
                          memoryBytes: UInt64(800 - i * 100) * 1_048_576, bundleIdentifier: nil, isOwnedByCurrentUser: false)
        }
    }
    static var snapshot: MetricsSnapshot {
        MetricsSnapshot(date: date, cpu: CPUSample(total: 0.18, user: 0.12, system: 0.06, perCore: Array(repeating: 0.18, count: 12)),
                        memory: MemorySample(totalBytes: 36 * 1_073_741_824, usedBytes: 20 * 1_073_741_824,
                            appBytes: 14 * 1_073_741_824, wiredBytes: 4 * 1_073_741_824, compressedBytes: 2 * 1_073_741_824,
                            cachedBytes: 5 * 1_073_741_824, swapUsedBytes: 0, pressure: .normal),
                        disk: DiskSample(volumeName: "Macintosh HD", totalBytes: 994_000_000_000, availableBytes: 284_000_000_000),
                        network: NetworkSample(bytesInPerSecond: 1_200_000, bytesOutPerSecond: 84_000, totalIn: 0, totalOut: 0),
                        battery: battery, temperatureCelsius: state == "unavailable" ? nil : 48, processes: processes)
    }
    static var apps: [InstalledApp] {
        ["Affinity Photo", "Sketch", "Visual Studio Code", "Firefox", "Obsidian", "Transmit", "Things", "A very long application name for layout verification"].enumerated().map { i, name in
            InstalledApp(name: name, path: root + "/Applications/\(name).app", bundleID: "com.example.app\(i)", version: "4.2.1", teamID: nil,
                         bytes: Int64(8 - i) * 340_000_000, lastUsed: date.addingTimeInterval(-Double(i) * 86_400), isApple: false)
        }
    }
    /// One of each kind the Login items screen explains: counted, updater, duplicate, orphan, disabled, on demand.
    static var launchItems: [LaunchItem] {
        let user = root + "/Library/LaunchAgents/", global = "/Library/LaunchAgents/"
        func item(_ label: String, _ folder: String, _ schedule: LaunchSchedule, owner: String?, installed: Bool = true, disabled: Bool = false) -> LaunchItem {
            LaunchItem(label: label, plistPath: folder + label + ".plist", program: nil, domain: folder == user ? .userAgent : .globalAgent,
                       schedule: schedule, ownerName: owner, ownerInstalled: installed, isDisabled: disabled)
        }
        return [
            item("com.example.app2.helper", user, .atLoad, owner: "Visual Studio Code"),
            item("com.example.app0.updater", user, .interval(3600), owner: "Affinity Photo"),
            item("com.example.app4.sync", user, .keepAlive, owner: "Obsidian"),
            item("com.example.app5.agent", user, .onDemand, owner: "Transmit"),
            item("com.example.app6.helper", user, .atLoad, owner: "Things", disabled: true),
            item("com.example.app5.agent", global, .onDemand, owner: "Transmit"),
            item("com.example.previous-editor.helper", global, .keepAlive, owner: "Previous editor", installed: false),
        ]
    }
    static var projectsGitHub: GitHubAvailability {
        state == "unavailable" ? .notSignedIn : .available(login: "demo", gh: "/opt/homebrew/bin/gh")
    }
    /// One project per status the Projects screen explains.
    static var projects: [ProjectScan] {
        let dev = root + "/Developer/"
        let old = Date().addingTimeInterval(-260 * 86_400), recent = Date().addingTimeInterval(-3 * 86_400)
        func remote(_ repo: String) -> [RemoteInfo] { [RemoteInfo(name: "origin", url: "https://github.com/\(repo).git", ownerRepo: repo)] }
        func main(ahead: Int = 0) -> [BranchInfo] { [BranchInfo(name: "main", sha: "a1", upstream: "origin/main", ahead: ahead)] }
        func scan(_ name: String, in folder: String = "", git: GitState?, github: GitHubCheck, bytes: Int64, changed: Date,
                  verdict: ProjectVerdict, nested: [String] = []) -> ProjectScan {
            ProjectScan(path: dev + folder + name, name: name, root: dev, git: git, github: github,
                        measure: FolderMeasure(bytes: bytes, fileCount: 1_200, newestModified: changed, ownModified: changed, unreadable: 0,
                                               nestedRepositories: nested),
                        lastChange: changed, isStale: changed == old, verdict: verdict, removalRefusal: nil, scannedAt: date)
        }
        let verified: GitHubCheck = state == "unavailable" ? .off : .checked
        return [
            scan("weather-widget", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, branches: main(), remotes: remote("demo/weather-widget"),
                                                lastCommitDate: old, ignoredPaths: [".env"], ignoredCount: 1),
                 github: verified, bytes: 1_840_000_000, changed: old, verdict: .safeToRemove),
            scan("recipe-api", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, branches: main(), remotes: remote("demo/recipe-api"), lastCommitDate: old),
                 github: verified, bytes: 412_000_000, changed: old, verdict: .safeToRemove),
            scan("portfolio-2023", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, branches: main(), remotes: remote("demo/portfolio-2023"), lastCommitDate: old),
                 github: .off, bytes: 96_000_000, changed: old, verdict: .safeToRemove),
            scan("game-prototype", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, uncommittedCount: 4, stashCount: 1,
                                                branches: main(ahead: 2) + [BranchInfo(name: "physics", sha: "b2", upstream: nil)],
                                                remotes: remote("demo/game-prototype"), lastCommitDate: old),
                 github: verified, bytes: 2_310_000_000, changed: old,
                 verdict: .notBackedUp([.uncommittedChanges(4), .stashes(1), .unpushedCommits(branch: "main", ahead: 2), .branchNotPushed("physics")])),
            scan("invoice-scripts", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, branches: [BranchInfo(name: "main", sha: "a1", upstream: nil)], lastCommitDate: old),
                 github: .notApplicable, bytes: 3_400_000, changed: old, verdict: .notBackedUp([.noRemote])),
            scan("sketches", git: nil, github: .notApplicable, bytes: 58_000_000, changed: old, verdict: .noGit),
            scan("keelmac", git: GitState(headBranch: "main", headSHA: "a1", hasCommits: true, branches: main(), remotes: remote("demo/keelmac"), lastCommitDate: recent),
                 github: verified, bytes: 980_000_000, changed: recent, verdict: .keep),
            scan("A project with a very long folder name for layout checks", git: nil, github: .notApplicable, bytes: 12_000, changed: recent, verdict: .noGit),
            // A plain folder holding a repository: the folder can't be backed up, the repository is listed on its own.
            scan("course-notes", git: nil, github: .notApplicable, bytes: 640_000_000, changed: old, verdict: .noGit, nested: ["react-basics"]),
            scan("react-basics", in: "course-notes/", git: GitState(headBranch: "main", headSHA: "c3", hasCommits: true, uncommittedCount: 3,
                                                                     branches: [BranchInfo(name: "main", sha: "c3", upstream: nil)], lastCommitDate: old),
                 github: .notApplicable, bytes: 638_000_000, changed: old, verdict: .notBackedUp([.uncommittedChanges(3), .noRemote])),
        ]
    }
    static var relatedFiles: [RelatedFile] {
        ["Application Support", "Caches", "Preferences"].enumerated().map { i, name in
            RelatedFile(path: root + "/Library/\(name)/com.example.editor", bytes: Int64(3 - i) * 120_000_000,
                        location: i == 0 ? .applicationSupport : .caches, isShared: false)
        }
    }
    static var cleanupPlan: CleanupPlan {
        let rules = (try? RuleSet.bundled().rules) ?? []
        let chosen = Array(rules.filter { $0.category == .developer }.prefix(3)) + [.userCaches, .browserCaches, .logs, .iosBackups].compactMap { category in rules.first { $0.category == category } }
        let groups = chosen.enumerated().map { i, rule in
            let items = (0..<4).map { j in
                CleanupItem(id: "fixture-\(i)-\(j)", ruleID: rule.id,
                            path: root + "/Library/Caches/\(rule.id)/\(["Workspace build cache", "Preview assets", "Development archive", "A long cache folder name with additional context"][j])",
                            bytes: Int64(4 - j) * 420_000_000, modified: date, isCommand: false, isDirectory: true)
            }
            return CleanupGroup(id: rule.id, rule: rule, items: items, bytes: items.reduce(0) { $0 + $1.bytes }, status: .ready, selectedByDefault: !rule.optIn)
        }
        return CleanupPlan(createdAt: date, groups: state == "empty" ? [] : groups)
    }
    static var duplicates: DuplicateSearchResult {
        let groups = ["Brand assets.zip", "Project presentation.pdf", "Summer footage.mov"].enumerated().map { i, name in
            DuplicateGroup(id: "fixture-\(i)", bytesEach: 820_000_000, files: ["Documents", "Downloads", "Archive"].enumerated().map { j, folder in
                DuplicateFile(path: root + "/\(folder)/\(name)", bytes: 820_000_000, modified: date.addingTimeInterval(-Double(j) * 86_400))
            })
        }
        return DuplicateSearchResult(groups: groups, unreadablePaths: [], protectedSkipped: 0, filesConsidered: 1240)
    }
    static var snapshots: [SnapshotValue] {
        (0..<3).map { i in
            SnapshotValue(date: date.addingTimeInterval(-Double(i) * 604_800), volumeTotal: 994_000_000_000,
                          volumeUsed: Int64(710 - i * 12) * 1_000_000_000, batteryMaxCapacityPercent: 96, reclaimableBytes: 42_000_000_000,
                          entries: Dictionary(uniqueKeysWithValues: ["Documents", "Downloads", "Library", "Movies", "Pictures"].enumerated().map { j, name in
                              (root + "/\(name)", Int64(80 - j * 10 - i * 2) * 1_000_000_000)
                          }))
        }
    }
    static var reviewRows: [ReviewRow] {
        ["Project archive.zip", "Design system.fig", "Local language model.gguf", "Documentary footage.mov", "Long project export with version and date.zip"].enumerated().map { i, name in
            let item = ReviewItem(id: "review-\(i)", name: name, path: root + "/Documents/\(name)", kind: i == 2 ? .aiModel : .archive,
                                  bytes: Int64(12 - i) * 1_000_000_000, nodes: [], lastOpened: date.addingTimeInterval(-20_000_000), owner: .none, removal: .trash([root + "/Documents/\(name)"]))
            return ReviewRow(item: item, owner: nil, status: i == 1 ? .locked(app: "Sketch") : .free)
        }
    }
    /// Use the existing cache decoder, keeping synthetic data out of public package interfaces.
    static func tree() -> ScanTree? {
        if state.hasPrefix("map") { return mapTree() }
        let names = ["Macintosh HD", "Applications", "Documents", "Movies", "Library", "Pictures", "Downloads"]
        func packed<T>(_ values: [T]) -> String { values.withUnsafeBytes { Data($0).base64EncodedString() } }
        var bytes: [UInt8] = [], starts: [UInt32] = [], lengths: [UInt16] = []
        for name in names { starts.append(UInt32(bytes.count)); lengths.append(UInt16(name.utf8.count)); bytes += name.utf8 }
        let object: [String: Any] = [
            "version": 1, "root": ["raw": 0], "scannedAt": date.timeIntervalSinceReferenceDate, "rootPath": root,
            "lastEventID": 0, "unreadable": [], "scanPath": root, "rootName": names[0], "deviceID": 0,
            "largeFileThreshold": 50_000_000, "firmlinks": [], "parents": packed([Int32]([-1, 0, 0, 0, 0, 0, 0])),
            "nameStart": packed(starts), "nameLength": packed(lengths), "nameBytes": packed(bytes),
            "flags": packed([UInt8](repeating: 1, count: names.count)),
            "ownBytes": packed([Int64]([0, 80, 120, 210, 160, 90, 50]).map { $0 * 1_000_000_000 }),
            "ownFiles": packed([UInt32](repeating: 0, count: names.count)),
            "ownModified": packed([UInt32](repeating: UInt32(Date().timeIntervalSince1970 - 604800), count: names.count))
        ]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(ScanTree.self, from: $0) }
    }
    /// Rich two-level map fixtures, including data absent from the older flat screenshot tree.
    private static func mapTree() -> ScanTree? {
        var names = ["Macintosh HD"], parents: [Int32] = [-1], sizes: [Int64] = [0], flags: [UInt8] = [1]
        @discardableResult func add(_ name: String, parent: Int, bytes: Int64, directory: Bool = true, unreadable: Bool = false) -> Int {
            let index = names.count
            names.append(name); parents.append(Int32(parent)); sizes.append(bytes); flags.append((directory ? 1 : 0) | (unreadable ? 2 : 0))
            if !directory { sizes[parent] += bytes }
            return index
        }
        let gb: Int64 = 1_000_000_000
        let library = add("Library", parent: 0, bytes: 2 * gb)
        let developer = add("Developer", parent: library, bytes: 8 * gb)
        add("Xcode Archives", parent: developer, bytes: 80 * gb)
        add("Simulator Devices", parent: developer, bytes: 60 * gb)
        add("Application Support", parent: library, bytes: 96 * gb)
        add("Caches", parent: library, bytes: 28 * gb)
        let movies = add("Movies", parent: 0, bytes: 3 * gb)
        add("Documentary final cut.mov", parent: movies, bytes: 82 * gb, directory: false)
        add("Behind the scenes.mp4", parent: movies, bytes: 26 * gb, directory: false)
        let documents = add("Documents", parent: 0, bytes: 6 * gb)
        add("Client project archive with a very long descriptive name and final delivery date.zip", parent: documents, bytes: 40 * gb, directory: false)
        add("Research library", parent: documents, bytes: 15 * gb)
        add("Applications", parent: 0, bytes: state == "map-dominant" ? 9_000 * gb : 48 * gb)
        add("Empty folder", parent: 0, bytes: 0)
        add("Protected records", parent: 0, bytes: 0, unreadable: true)
        for i in 0..<(state == "map-dense" ? 3000 : 30) {
            add("Small project \(i + 1)", parent: 0, bytes: Int64(30 + i % 10) * (state == "map-grouped" ? 100_000_000 : 1_000_000))
        }
        if state == "map-emptyFolder" { names = ["Empty folder"]; parents = [-1]; sizes = [0]; flags = [1] }
        func packed<T>(_ values: [T]) -> String { values.withUnsafeBytes { Data($0).base64EncodedString() } }
        var nameBytes: [UInt8] = [], starts: [UInt32] = [], lengths: [UInt16] = []
        for name in names { starts.append(UInt32(nameBytes.count)); lengths.append(UInt16(name.utf8.count)); nameBytes += name.utf8 }
        let object: [String: Any] = [
            "version": 1, "root": ["raw": 0], "scannedAt": date.timeIntervalSinceReferenceDate, "rootPath": root,
            "lastEventID": 0, "unreadable": state == "map-permission" ? [root + "/Protected records"] : [], "scanPath": root, "rootName": names[0], "deviceID": 0,
            "largeFileThreshold": 50_000_000, "firmlinks": [], "parents": packed(parents),
            "nameStart": packed(starts), "nameLength": packed(lengths), "nameBytes": packed(nameBytes), "flags": packed(flags),
            "ownBytes": packed(sizes), "ownFiles": packed([UInt32](repeating: 1, count: names.count)),
            "ownModified": packed([UInt32](repeating: UInt32(Date().timeIntervalSince1970 - 604800), count: names.count))
        ]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(ScanTree.self, from: $0) }
    }
}


struct FixtureWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard VisualFixtures.enabled else { return view }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let surfaceSizes = ["settings": "700x560", "welcome": "600x540", "about": "420x500", "menuBar": "400x660", "uninstall": "680x560", "result": "860x560"]
            let requestedSize = VisualFixtures.argument("-fixture-surface").flatMap { surfaceSizes[$0] } ?? VisualFixtures.argument("-fixture-size") ?? "1180x780"
            let dimensions = requestedSize.split(separator: "x").compactMap { Double($0) }
            if dimensions.count == 2 { window.setContentSize(NSSize(width: dimensions[0], height: dimensions[1])) }
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


struct FixtureResultView: View {
    @State private var result: CleanupResult?
    var body: some View {
        Group {
            if let result { CleanupResultView(result: result) }
            else { ProgressView() }
        }
        .task {
            guard VisualFixtures.enabled else { return }
            // A planted cache file with a no-op trasher. The user's Trash is never touched.
            let folder = URL(fileURLWithPath: VisualFixtures.root + "/Library/Caches")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("preview-result")
            try? Data("fixture".utf8).write(to: file)
            let rule = CleanupRule(id: "preview", category: .userCaches, title: .init(en: "App caches", es: "Cachés de apps"), detail: .init(en: "", es: ""))
            let item = CleanupItem(id: "preview", ruleID: rule.id, path: file.path, bytes: 420_000_000, modified: nil, isCommand: false)
            let group = CleanupGroup(id: rule.id, rule: rule, items: [item], bytes: item.bytes, status: .ready, selectedByDefault: true)
            var remover = SafeRemover(pathGuard: PathGuard(home: VisualFixtures.root), context: .cleanup)
            remover.trasher = { _ in }
            result = await CleanupExecutor(remover: remover, runner: RecordingCommandRunner(), log: InMemoryOperationLog())
                .execute(CleanupPlan(createdAt: VisualFixtures.date, groups: [group]), selected: [item.id])
        }
    }
}
