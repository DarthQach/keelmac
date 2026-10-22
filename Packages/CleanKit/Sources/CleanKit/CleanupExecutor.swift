import Foundation
import SafetyKit

public struct CleanupResult: Sendable {
    public let batchID: UUID
    /// One per selected path item, in plan order.
    public let outcomes: [RemovalOutcome]
    /// Keyed by item id.
    public let commandResults: [String: CommandResult]
    /// Moved to the Trash + deleted + freed by commands.
    public let bytesFreed: Int64
    public let bytesMovedToTrash: Int64
    public let bytesDeleted: Int64
    public let bytesFreedByCommands: Int64
    /// The rows written to the operation log (one per selected item).
    public let entries: [OperationEntry]
}

/// Carries out an approved plan. It only touches items that are in the plan and selected; it never
/// expands a glob again. Paths go through `SafeRemover` (which re-checks `PathGuard` and "changed since
/// preview"), commands through `CommandRunning` with exactly the executable and arguments from the plan.
public struct CleanupExecutor: Sendable {
    public static let logTitle = "Cleanup"

    public let remover: SafeRemover
    public let runner: CommandRunning
    public let log: OperationLogging

    public init(remover: SafeRemover, runner: CommandRunning, log: OperationLogging) {
        self.remover = remover; self.runner = runner; self.log = log
    }

    /// The remover for rules that delete permanently (the Trash): same guard, context and checks.
    var permanentRemover: SafeRemover {
        var r = SafeRemover(pathGuard: remover.pathGuard, mode: .permanent, context: remover.context)
        r.modificationTolerance = remover.modificationTolerance
        r.trasher = remover.trasher
        return r
    }

    public func execute(_ plan: CleanupPlan, selected: Set<String>) async -> CleanupResult {
        let batchID = UUID()
        var outcomes: [RemovalOutcome] = []
        var entries: [OperationEntry] = []
        var commandResults: [String: CommandResult] = [:]
        var trashed: Int64 = 0, deleted: Int64 = 0, byCommands: Int64 = 0
        var done = Set<String>()
        let permanent = permanentRemover

        for group in plan.groups where group.status == .ready {
            for item in group.items where selected.contains(item.id) && done.insert(item.id).inserted {
                if item.isCommand {
                    guard let command = item.command else { continue }
                    let (result, freed, entry) = await run(command, item: item, batchID: batchID)
                    commandResults[item.id] = result
                    byCommands += freed
                    entries.append(entry)
                    continue
                }
                let request = RemovalRequest(path: item.path, bytes: item.bytes, expectedModificationDate: item.modified)
                let outcome = group.deletesPermanently ? permanent.removeOne(request) : remover.removeOne(request)
                outcomes.append(outcome)
                switch outcome.result {
                case .trashed: trashed += outcome.bytes
                case .deleted, .removed: deleted += outcome.bytes
                default: break
                }
                entries.append(contentsOf: SafeRemover.entries([outcome], batchID: batchID, kind: .cleanup, title: Self.logTitle))
            }
        }
        await log.record(entries)
        return CleanupResult(batchID: batchID, outcomes: outcomes, commandResults: commandResults,
                             bytesFreed: trashed + deleted + byCommands, bytesMovedToTrash: trashed, bytesDeleted: deleted,
                             bytesFreedByCommands: byCommands, entries: entries)
    }

    private func run(_ command: CommandInvocation, item: CleanupItem, batchID: UUID) async -> (CommandResult, Int64, OperationEntry) {
        let result = await runner.run(command.executable, command.arguments, timeout: command.timeout)
        var freed: Int64 = 0
        if result.succeeded {
            switch command.measurement {
            case .none:
                break
            default:
                if case .success(let after) = await CommandMeasurer.measure(command.measurement, runner: runner) {
                    freed = max(0, item.bytes - after.bytes)
                }
            }
        }
        let reason: String?
        if result.succeeded {
            reason = nil
        } else if result.timedOut {
            reason = "Timed out (exit code \(result.exitCode))"
        } else {
            let last = result.stderr.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            reason = last.isEmpty ? "Exit code \(result.exitCode)" : "Exit code \(result.exitCode): \(last)"
        }
        let entry = OperationEntry(batchID: batchID, kind: .cleanup, title: Self.logTitle, path: command.commandLine,
                                   bytes: result.succeeded ? freed : 0, result: result.succeeded ? .ran : .failed, reason: reason)
        return (result, freed, entry)
    }
}
