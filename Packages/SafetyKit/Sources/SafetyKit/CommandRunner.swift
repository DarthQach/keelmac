import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs an executable with a fixed argument array. KeelMac never builds shell strings:
/// every command is an absolute executable path plus arguments.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) async -> CommandResult {
        await run(executable, arguments, timeout: timeout, onOutput: nil)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(exitCode: 127, stdout: "", stderr: "\(executable): not found")
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let collector = OutputCollector(onOutput: onOutput)
            out.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, toStdout: true) }
            err.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, toStdout: false) }
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.append(out.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
                collector.append(err.fileHandleForReading.readDataToEndOfFile(), toStdout: false)
                let (o, e, timedOut) = collector.finish()
                continuation.resume(returning: CommandResult(exitCode: p.terminationStatus, stdout: o, stderr: e, timedOut: timedOut))
            }
            do { try process.run() } catch {
                continuation.resume(returning: CommandResult(exitCode: 126, stdout: "", stderr: error.localizedDescription))
                return
            }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { collector.markTimedOut(); process.terminate() }
                }
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data(), timedOut = false
    private let onOutput: (@Sendable (String) -> Void)?

    init(onOutput: (@Sendable (String) -> Void)?) { self.onOutput = onOutput }

    func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStdout { stdout.append(data) } else { stderr.append(data) }
        lock.unlock()
        if let onOutput, let text = String(data: data, encoding: .utf8) { onOutput(text) }
    }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func finish() -> (String, String, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), timedOut)
    }
}

/// A runner for tests: returns canned results and records invocations.
public final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    private let handler: @Sendable (String, [String]) -> CommandResult

    public init(handler: @escaping @Sendable (String, [String]) -> CommandResult = { _, _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }) {
        self.handler = handler
    }

    public var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        lock.withLock { _calls.append((executable, arguments)) }
        let r = handler(executable, arguments)
        if !r.stdout.isEmpty { onOutput?(r.stdout) }
        return r
    }
}
