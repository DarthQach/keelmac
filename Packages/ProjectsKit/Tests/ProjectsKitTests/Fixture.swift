import Foundation
import SafetyKit
@testable import ProjectsKit

/// A throwaway folder tree in the temp directory with real git repositories in it. Git runs with no global or
/// system config and a fake HOME, so nothing reads or changes the real home folder, and no remote is on the network.
final class Fixture: @unchecked Sendable {
    let root: String

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("projectskit-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathGuard.canonical(URL(fileURLWithPath: base.path).resolvingSymlinksInPath().path)
        dir("home/Developer")
    }

    deinit {
        // Restore permissions a test may have removed, then delete.
        _ = try? FileManager.default.subpathsOfDirectory(atPath: root).forEach {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/" + $0)
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    var home: String { root + "/home" }
    var developer: String { home + "/Developer" }
    var pathGuard: PathGuard { PathGuard(home: home, userName: "carlos", uid: 501) }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func dir(_ relative: String) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096, modified: Date? = nil) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
        if let modified { setModified(p, modified) }
        return p
    }

    func setModified(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Sets every work-tree file's date (`.git` left alone).
    func age(_ folder: String, to date: Date) {
        let fm = FileManager.default
        for sub in (try? fm.subpathsOfDirectory(atPath: folder)) ?? [] where !sub.hasPrefix(".git/") && sub != ".git" {
            setModified(folder + "/" + sub, date)
        }
    }

    // MARK: - git

    var gitEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": home, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
         "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com", "GIT_TERMINAL_PROMPT": "0"]
    }

    /// Runs real git synchronously. Output goes through temp files, so large output can't block.
    @discardableResult
    func git(_ args: [String], in dir: String? = nil, date: Date? = nil) -> CommandResult {
        var env = gitEnvironment
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp; env["GIT_COMMITTER_DATE"] = stamp
        }
        return Self.run(ProjectTools.git, (dir.map { ["-C", $0] } ?? []) + ["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args,
                        environment: env, scratch: root)
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String], scratch: String) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outPath = scratch + "/.out-\(UUID().uuidString)", errPath = scratch + "/.err-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: outPath); try? FileManager.default.removeItem(atPath: errPath) }
        process.standardOutput = FileHandle(forWritingAtPath: outPath)
        process.standardError = FileHandle(forWritingAtPath: errPath)
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(exitCode: 126, stdout: "", stderr: "\(error)") }
        process.waitUntilExit()
        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    /// A repository with one committed file.
    @discardableResult
    func repo(_ relative: String, committed: Date? = nil) -> String {
        let p = dir(relative)
        git(["init", "-q", "-b", "main"], in: p)
        file(relative + "/README.md", bytes: 100)
        git(["add", "-A"], in: p)
        git(["commit", "-q", "-m", "first"], in: p, date: committed)
        return p
    }

    @discardableResult
    func commit(_ repo: String, file name: String, date: Date? = nil) -> CommandResult {
        FileManager.default.createFile(atPath: repo + "/" + name, contents: Data(UUID().uuidString.utf8))
        git(["add", "-A"], in: repo)
        return git(["commit", "-q", "-m", "change \(name)"], in: repo, date: date)
    }

    @discardableResult
    func bare(_ relative: String) -> String {
        let p = dir(relative)
        git(["init", "-q", "--bare", "-b", "main"], in: p)
        return p
    }

    /// Pushes `main` to a bare repository as `origin` with tracking, then points `origin` at a GitHub URL.
    /// `FixtureRunner` sends that remote's network calls back to the bare repository.
    func publish(_ repo: String, to bare: String, as ownerRepo: String) {
        git(["remote", "add", "origin", bare], in: repo)
        git(["push", "-q", "-u", "origin", "--all"], in: repo)
        git(["push", "-q", "origin", "--tags"], in: repo)
        git(["remote", "set-url", "origin", "https://github.com/\(ownerRepo).git"], in: repo)
    }
}

/// Runs real git with the fixture's environment and answers gh with canned results. `ls-remote` and `push` to a
/// remote listed in `remotes` go to that local bare repository instead of the network.
final class FixtureRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    let fixture: Fixture
    var remotes: [String: String] = [:]
    var gh: @Sendable ([String]) -> CommandResult = { _ in CommandResult(exitCode: 1, stdout: "", stderr: "unexpected gh call") }

    init(_ fixture: Fixture) { self.fixture = fixture }

    var calls: [(String, [String])] { lock.withLock { _calls } }
    var gitCalls: [[String]] { calls.filter { $0.0 == ProjectTools.git }.map(\.1) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> CommandResult {
        lock.withLock { _calls.append((executable, arguments)) }
        guard executable == ProjectTools.git else { return gh(arguments) }
        var args = arguments
        if args.contains("ls-remote") || args.contains("push") {
            let map = lock.withLock { remotes }
            args = args.map { map[$0] ?? $0 }
        }
        return Fixture.run(executable, args, environment: fixture.gitEnvironment, scratch: fixture.root)
    }
}

extension Date {
    static func daysAgo(_ days: Double, from now: Date = Date()) -> Date { now.addingTimeInterval(-days * 86_400) }
}
