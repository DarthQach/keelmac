import Foundation
import HelperShared
import SafetyKit

/// Runs one `HelperOperation` after validating it. Linked by the KeelMacHelper daemon; testable without XPC.
///
/// - Every operation is checked with `HelperValidation` first; a refused request runs nothing.
/// - Commands come only from `HelperCommandMap` (absolute executables, argument arrays), run through `CommandRunning`.
/// - Removals go through `SafeRemover`; in production its context is `.helper` and its trasher moves items into
///   the requesting user's `~/.Trash/KeelMac` (see `forClient(uid:)`).
public struct HelperExecutor: Sendable {
    public let runner: any CommandRunning
    public let remover: SafeRemover
    /// The uid of the user who asked; picks `gui/<uid>` for /Library/LaunchAgents items.
    public var clientUID: UInt32
    /// Reads a plist's `Label`, used when a plist's file name isn't `<label>.plist`.
    public var plistLabelReader: @Sendable (String) -> String? = HelperExecutor.readPlistLabel
    /// Caps the output returned to the app.
    public var maxOutputBytes = 2 * 1024 * 1024

    public init(runner: any CommandRunning, remover: SafeRemover, clientUID: UInt32 = getuid()) {
        self.runner = runner
        self.remover = remover
        self.clientUID = clientUID
    }

    /// The production executor for one connecting user: a `.helper` remover whose PathGuard knows that user,
    /// moving into `<their home>/.Trash/KeelMac`.
    public static func forClient(uid: UInt32, runner: any CommandRunning = ProcessCommandRunner(), whitelist: Whitelist = Whitelist()) -> HelperExecutor {
        let account = UserAccount(uid: uid)
        let pathGuard = PathGuard(home: account?.home ?? "/var/empty", userName: account?.name ?? "", uid: uid, whitelist: whitelist)
        var remover = SafeRemover(pathGuard: pathGuard, mode: .trash, context: .helper)
        let mover = UserTrashMover.forUser(uid: uid)
        remover.trasher = { url in
            guard let mover else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "~/.Trash"]) }
            try mover.move(url)
        }
        return HelperExecutor(runner: runner, remover: remover, clientUID: uid)
    }

    public func perform(_ op: HelperOperation) async -> HelperResponse {
        if let rejection = HelperValidation.validate(op, plistLabel: plistLabelReader) {
            return .rejected(rejection)
        }
        var output = ""
        var outcomes: [HelperItemOutcome] = []
        var exitCode: Int32 = 0
        var timedOut = false

        stepLoop: for step in HelperCommandMap.steps(for: op, clientUID: clientUID) {
            switch step {
            case .run(let inv):
                // Defence in depth: the map is the only source of commands, and it only names these executables.
                guard HelperCommandMap.allowedExecutables.contains(inv.executable) else {
                    exitCode = 126
                    break stepLoop
                }
                let result = await runner.run(inv.executable, inv.arguments, timeout: op.timeout, onOutput: nil)
                append(&output, result.stdout)
                append(&output, result.stderr)
                if !result.succeeded && !inv.bestEffort {
                    exitCode = result.exitCode == 0 ? 1 : result.exitCode
                    timedOut = result.timedOut
                    break stepLoop
                }
            case .trash(let paths):
                let results = remover.remove(paths.map { RemovalRequest(path: $0, bytes: 0) }).map(HelperItemOutcome.init)
                outcomes.append(contentsOf: results)
                if results.contains(where: { $0.result == .failed || $0.result == .refused }) {
                    exitCode = 1
                }
            }
        }
        return HelperResponse(exitCode: exitCode, output: output, outcomes: outcomes, timedOut: timedOut)
    }

    private func append(_ output: inout String, _ text: String) {
        guard !text.isEmpty, output.utf8.count < maxOutputBytes else { return }
        output += text
        if !text.hasSuffix("\n") { output += "\n" }
    }

    /// Reads `Label` from a regular file (never follows a symlink).
    public static func readPlistLabel(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 1_000_000,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["Label"] as? String
    }
}
