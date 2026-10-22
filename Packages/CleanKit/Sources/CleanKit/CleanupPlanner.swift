import Foundation
import SafetyKit

/// Builds the dry-run preview. Read-only: it lists, sizes and runs measurement commands
/// (`simctl list`, `docker info`/`system df`, `pnpm store path`, `codesign -dv`), never a removal.
public actor CleanupPlanner {
    public let rules: RuleSet
    public let pathGuard: PathGuard
    public let environment: CleanupEnvironment
    public let runner: CommandRunning

    public init(rules: RuleSet, pathGuard: PathGuard, environment: CleanupEnvironment, runner: CommandRunning) {
        self.rules = rules; self.pathGuard = pathGuard; self.environment = environment; self.runner = runner
    }

    public func plan() async -> CleanupPlan {
        let evaluator = RuleEvaluator(pathGuard: pathGuard, environment: environment, runner: runner)
        let ruleList = rules.rules

        // 1. Expand every rule concurrently (globs, exclusions, PathGuard, tools, command measurements).
        var preps = [RulePreparation?](repeating: nil, count: ruleList.count)
        await withTaskGroup(of: (Int, RulePreparation).self) { group in
            for (i, rule) in ruleList.enumerated() {
                group.addTask { (i, await evaluator.prepare(rule)) }
            }
            for await (i, prep) in group { preps[i] = prep }
        }
        var prepared = preps.compactMap { $0 }

        // 2. No overlaps: folders a command manages first, then path items in rule order.
        //    A path that equals, contains or lies inside an already claimed path is dropped.
        var claims = ClaimSet()
        for prep in prepared { for p in prep.claimedByCommand { claims.claim(p) } }
        for i in prepared.indices {
            prepared[i].candidates = prepared[i].candidates.filter { c in
                guard !claims.conflicts(c.match.path) else { return false }
                claims.claim(c.match.path)
                return true
            }
        }

        // 3. Size every folder candidate of every rule in one shared parallel pass.
        let folders = prepared.flatMap { $0.candidates.filter { $0.match.isDirectory && !$0.match.isSymlink }.map(\.match.path) }
        let sizes = await DirectorySizer.size(folders)

        // 4. Age, keep-newest, groups.
        let groups = prepared.map { evaluator.finalize($0, sizes: sizes) }
        return CleanupPlan(createdAt: environment.now, groups: groups)
    }
}

/// Paths claimed so far, with all their ancestors, for O(depth) overlap checks.
struct ClaimSet {
    private var claimed = Set<String>()
    private var ancestors = Set<String>()

    mutating func claim(_ path: String) {
        claimed.insert(path)
        var p = path
        while let slash = p.lastIndex(of: "/"), slash != p.startIndex {
            p = String(p[..<slash])
            if !ancestors.insert(p).inserted { break }
        }
    }

    func conflicts(_ path: String) -> Bool {
        if claimed.contains(path) || ancestors.contains(path) { return true }
        var p = path
        while let slash = p.lastIndex(of: "/"), slash != p.startIndex {
            p = String(p[..<slash])
            if claimed.contains(p) { return true }
        }
        return false
    }
}
