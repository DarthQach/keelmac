import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

/// Opt-in: `KEELMAC_LIVE_GH=1 swift test --filter Live`. Asks gh who is signed in; reads nothing else and changes nothing.
@Suite("Live gh", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE_GH"] == "1"))
struct LiveGitHubTests {
    @Test func signedInLogin() async {
        let scanner = ProjectScanner(runner: ProcessCommandRunner(), pathGuard: PathGuard())
        let availability = await scanner.githubAvailability(verify: true)
        guard case .available(let login, _) = availability else { Issue.record("gh: \(availability)"); return }
        #expect(!login.isEmpty)
    }
}

/// Opt-in: `KEELMAC_LIVE=1 swift test --filter LiveProjects` checks ~/Developer read-only and prints one line per
/// project. Add `KEELMAC_LIVE_GH=1` to verify against GitHub (`git ls-remote`, `gh api user`). Nothing is changed.
@Suite("Live projects", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE"] == "1"))
struct LiveProjectsTests {
    @Test func checksDeveloperReadOnly() async {
        let verify = ProcessInfo.processInfo.environment["KEELMAC_LIVE_GH"] == "1"
        let scanner = ProjectScanner(runner: ProcessCommandRunner(), pathGuard: PathGuard())
        var all: [ProjectScan] = []
        var github: GitHubAvailability?
        let started = Date()
        for await event in scanner.scan(roots: ["~/Developer"], options: ProjectScanOptions(verifyWithGitHub: verify)) {
            if case .finished(let scans) = event { all = scans }
            if case .github(let g) = event { github = g }
        }
        let byVerdict = Dictionary(grouping: all) { "\($0.verdict.rank)" }.mapValues(\.count)
        print("LIVE \(all.count) projects in \(Int(Date().timeIntervalSince(started))) s, github \(String(describing: github)), by rank \(byVerdict.sorted { $0.key < $1.key })")
        for p in all {
            let reasons = p.verdict.reasons.map { "\($0)" }.joined(separator: "; ")
            print("LIVE \(p.relativePath) | backup=\(p.canBackUp) | inside=\(p.embeddedRepositories.joined(separator: ",")) | \(p.verdict.rank) | trash=\(p.isTrashCandidate) | \(p.github) | \(p.lastChange.map { "\(Int(Date().timeIntervalSince($0) / 86_400))d" } ?? "-") | \(ByteCountFormatter.string(fromByteCount: p.measure?.bytes ?? 0, countStyle: .file)) | \(p.git?.githubRemote?.ownerRepo ?? "-") | \(reasons)")
        }
        #expect(!all.isEmpty)
    }
}
