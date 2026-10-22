import AppKit
import SafetyKit

/// Reveal, Quick Look and Move to Trash for any list of paths, with the safety checks and logging every removal needs.
@MainActor
enum FileActions {
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The guard built from the user's whitelist.
    static func pathGuard() -> PathGuard {
        PathGuard(whitelist: Whitelist(UserDefaults.standard.stringArray(forKey: Preferences.Key.whitelist) ?? []))
    }

    static var deleteMode: DeleteMode {
        DeleteMode(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.deleteMode) ?? "trash") ?? .trash
    }

    /// Removes the given items (already previewed and confirmed by the user) and logs every outcome.
    static func remove(_ requests: [RemovalRequest], context: PathContext, kind: OperationKind, title: String,
                       log: OperationLogging, mode: DeleteMode? = nil) async -> [RemovalOutcome] {
        let remover = SafeRemover(pathGuard: pathGuard(), mode: mode ?? deleteMode, context: context)
        let outcomes = await Task.detached(priority: .userInitiated) { remover.remove(requests) }.value
        await log.record(SafeRemover.entries(outcomes, batchID: UUID(), kind: kind, title: title))
        return outcomes
    }
}

extension Array where Element == RemovalOutcome {
    var bytesRemoved: Int64 { filter { $0.result.removedItem }.reduce(0) { $0 + $1.bytes } }
    var removedCount: Int { filter { $0.result.removedItem }.count }
    var notRemoved: [RemovalOutcome] { filter { !$0.result.removedItem } }
}
