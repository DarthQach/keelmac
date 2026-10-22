import Foundation
import SafetyKit
import ScanKit

/// The storage scan shared by Storage map, Large and old files and System Data (C8–C11).
@MainActor
@Observable
final class StorageModel {
    enum Phase: Equatable { case idle, scanning, ready, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var tree: ScanTree?
    private(set) var progress: ScanProgress?
    private(set) var systemData: [SystemDataItem]?
    private(set) var measuringSystemData = false
    /// Per-folder file-kind totals for the map's colours; nil until computed for the current tree.
    private(set) var kindShares: KindShares?
    private var scanTask: Task<Void, Never>?
    private let cacheURL = ScanCache.defaultURL(forRoot: "/")

    init() {}

    /// Computes the map colours for the current tree once (off the main thread).
    func updateKindShares() async {
        guard let tree, kindShares?.key != KindShares.key(for: tree) else { return }
        let home = NSHomeDirectory()
        let shares = await Task.detached(priority: .userInitiated) { KindShares(tree: tree, home: home) }.value
        if let current = self.tree, KindShares.key(for: current) == shares.key { kindShares = shares }
    }

    /// Loads the last scan from disk so the map appears instantly.
    func loadCache() {
        guard tree == nil else { return }
        let url = cacheURL
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { try? ScanCache.load(from: url) }.value
            if let loaded, tree == nil {
                tree = loaded
                phase = .ready
            }
        }
    }

    private var exclusions: [String] {
        (UserDefaults.standard.stringArray(forKey: Preferences.Key.scanExclusions) ?? []).map { ($0 as NSString).expandingTildeInPath }
    }

    /// Full scan the first time, then incremental rescans (only folders that changed since the last scan).
    func scan(full: Bool = false) {
        guard phase != .scanning else { return }
        phase = .scanning
        progress = nil
        let scanner = DiskScanner()
        let previous = full ? nil : tree
        let exclusions = self.exclusions
        scanTask = Task {
            do {
                let events: AsyncThrowingStream<ScanEvent, Error>
                if let previous {
                    events = await scanner.rescan(previous, exclusions: exclusions)
                } else {
                    events = await scanner.scan(root: "/", exclusions: exclusions)
                }
                for try await event in events {
                    switch event {
                    case .progress(let p): progress = p
                    case .finished(let t): finish(t)
                    }
                }
            } catch is CancellationError {
                phase = tree == nil ? .idle : .ready
            } catch {
                phase = tree == nil ? .failed(error.localizedDescription) : .ready
            }
        }
    }

    func rescan(folder: String) {
        guard let tree, phase != .scanning else { return }
        phase = .scanning
        let scanner = DiskScanner()
        let exclusions = self.exclusions
        scanTask = Task {
            do {
                for try await event in await scanner.rescan(tree, folder: folder, exclusions: exclusions) {
                    switch event {
                    case .progress(let p): progress = p
                    case .finished(let t): finish(t)
                    }
                }
            } catch {
                phase = .ready
            }
        }
    }

    func cancel() { scanTask?.cancel() }

    private func finish(_ t: ScanTree) {
        tree = t
        phase = .ready
        progress = nil
        let url = cacheURL
        Task.detached(priority: .utility) { try? ScanCache.save(t, to: url) }
    }

    func measureSystemData() async {
        guard !measuringSystemData else { return }
        measuringSystemData = true
        let runner = ScanCommandRunner { exe, args in
            let r = await ProcessCommandRunner().run(exe, args, timeout: 30)
            return .init(exitCode: r.exitCode, stdout: r.stdout)
        }
        systemData = await SystemDataBreakdown.measure(home: NSHomeDirectory(), runner: runner)
        measuringSystemData = false
    }

    /// After items were removed, rescan their parent folders so the map stays honest.
    func refresh(after removedPaths: [String]) {
        let parents = Set(removedPaths.map { ($0 as NSString).deletingLastPathComponent })
        if parents.count == 1, let folder = parents.first { rescan(folder: folder) } else { scan() }
    }
}
