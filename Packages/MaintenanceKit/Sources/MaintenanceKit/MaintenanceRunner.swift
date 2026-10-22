import Foundation
import HelperShared
import SafetyKit

/// Why a task stopped before (or instead of) producing an exit code from its commands.
public enum MaintenanceFailure: Sendable, Equatable {
    case unavailable(MaintenanceUnavailableReason)
    /// An admin task, but no helper was given to the runner.
    case helperMissing
    case helper(HelperClientError)
    /// The helper refused the request.
    case rejected(HelperRejection)
    case timedOut
}

public enum MaintenanceEvent: Sendable, Equatable {
    /// One line of output (no trailing newline).
    case output(String)
    /// Emitted before `finished` when the task couldn't run or was cut off.
    case failed(MaintenanceFailure)
    /// Always the last event.
    case finished(exitCode: Int32, duration: TimeInterval)
}

/// Runs maintenance tasks: user tasks through `CommandRunning` with live output, admin tasks through the helper.
public struct MaintenanceRunner: Sendable {
    /// Exit code reported when a task couldn't run at all.
    public static let notRunExitCode: Int32 = -1

    public let runner: any CommandRunning
    public let helper: (any HelperPerforming)?
    /// Checked before running; injected in tests.
    public var executableExists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    public init(runner: any CommandRunning, helper: HelperClient?) {
        self.runner = runner
        self.helper = helper
    }

    public init(runner: any CommandRunning, helperPerformer: (any HelperPerforming)?) {
        self.runner = runner
        self.helper = helperPerformer
    }

    public func run(_ task: MaintenanceTask) -> AsyncStream<MaintenanceEvent> {
        AsyncStream { continuation in
            let work = Task {
                let start = Date()
                let exitCode = await execute(task, continuation)
                continuation.yield(.finished(exitCode: exitCode, duration: Date().timeIntervalSince(start)))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func execute(_ task: MaintenanceTask, _ continuation: AsyncStream<MaintenanceEvent>.Continuation) async -> Int32 {
        if case .unavailable(let reason) = task.availability(executableExists: executableExists) {
            continuation.yield(.failed(.unavailable(reason)))
            return Self.notRunExitCode
        }
        if let op = task.helperOperation {
            return await runAdmin(op, continuation)
        }
        return await runUser(task, continuation)
    }

    private func runUser(_ task: MaintenanceTask, _ continuation: AsyncStream<MaintenanceEvent>.Continuation) async -> Int32 {
        for (executable, arguments) in task.userInvocations {
            if Task.isCancelled { return Self.notRunExitCode }
            let splitter = LineSplitter()
            let result = await runner.run(executable, arguments, timeout: task.timeout) { chunk in
                for line in splitter.feed(chunk) { continuation.yield(.output(line)) }
            }
            if let rest = splitter.flush() { continuation.yield(.output(rest)) }
            if result.timedOut {
                continuation.yield(.failed(.timedOut))
                return result.exitCode == 0 ? 1 : result.exitCode
            }
            if result.exitCode != 0 { return result.exitCode }
        }
        return 0
    }

    private func runAdmin(_ op: HelperOperation, _ continuation: AsyncStream<MaintenanceEvent>.Continuation) async -> Int32 {
        guard let helper else {
            continuation.yield(.failed(.helperMissing))
            return Self.notRunExitCode
        }
        do {
            let response = try await helper.perform(op)
            let splitter = LineSplitter()
            for line in splitter.feed(response.output) { continuation.yield(.output(line)) }
            if let rest = splitter.flush() { continuation.yield(.output(rest)) }
            if let rejection = response.rejection { continuation.yield(.failed(.rejected(rejection))) }
            if response.timedOut { continuation.yield(.failed(.timedOut)) }
            return response.exitCode
        } catch let error as HelperClientError {
            continuation.yield(.failed(.helper(error)))
            return Self.notRunExitCode
        } catch {
            continuation.yield(.failed(.helper(.connectionFailed((error as NSError).localizedDescription))))
            return Self.notRunExitCode
        }
    }
}

/// Splits streamed chunks into whole lines; keeps a partial last line until more arrives.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func feed(_ chunk: String) -> [String] {
        lock.withLock {
            pending += chunk
            var lines: [String] = []
            while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
                lines.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            return lines
        }
    }

    func flush() -> String? {
        lock.withLock {
            defer { pending = "" }
            return pending.isEmpty ? nil : pending
        }
    }
}
