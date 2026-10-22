import Foundation
import Testing
@testable import DuplicatesKit

private func file(_ path: String, _ day: Double) -> DuplicateFile {
    DuplicateFile(path: path, bytes: 100, modified: Date(timeIntervalSince1970: day * 86_400))
}

private func group(_ files: [DuplicateFile]) -> DuplicateGroup {
    DuplicateGroup(id: "hash", bytesEach: 100, files: files)
}

private let allRules: [AutoSelectRule] = [.newest, .oldest, .preferredFolder("/Users/c/Keep"), .preferredFolder("/Nowhere")]

@Suite("AutoSelectRule")
struct AutoSelectRuleTests {
    let sample = group([
        file("/Users/c/Downloads/a.pdf", 3),
        file("/Users/c/Keep/b.pdf", 1),
        file("/Users/c/Desktop/c.pdf", 5),
        file("/Users/c/Keep/sub/d.pdf", 2),
    ])

    @Test("newest keeps the most recently modified copy")
    func newest() {
        let removed = AutoSelectRule.newest.filesToRemove(in: sample).map(\.path)
        #expect(removed == ["/Users/c/Downloads/a.pdf", "/Users/c/Keep/b.pdf", "/Users/c/Keep/sub/d.pdf"])
        #expect(AutoSelectRule.newest.fileToKeep(in: sample)?.path == "/Users/c/Desktop/c.pdf")
    }

    @Test("oldest keeps the oldest copy")
    func oldest() {
        #expect(AutoSelectRule.oldest.fileToKeep(in: sample)?.path == "/Users/c/Keep/b.pdf")
        #expect(!AutoSelectRule.oldest.filesToRemove(in: sample).contains { $0.path == "/Users/c/Keep/b.pdf" })
    }

    @Test("preferredFolder keeps the newest copy inside the folder, else the newest overall")
    func preferred() {
        #expect(AutoSelectRule.preferredFolder("/Users/c/Keep").fileToKeep(in: sample)?.path == "/Users/c/Keep/sub/d.pdf")
        #expect(AutoSelectRule.preferredFolder("/Users/c/Keep/").fileToKeep(in: sample)?.path == "/Users/c/Keep/sub/d.pdf")
        #expect(AutoSelectRule.preferredFolder("/Nowhere").fileToKeep(in: sample)?.path == "/Users/c/Desktop/c.pdf")
        // A sibling whose name only starts with the folder's name is not inside it.
        let tricky = group([file("/Users/c/Keeper/x", 9), file("/Users/c/Keep/y", 1)])
        #expect(AutoSelectRule.preferredFolder("/Users/c/Keep").fileToKeep(in: tricky)?.path == "/Users/c/Keep/y")
    }

    @Test("Ties on dates are broken by path, whatever the input order", arguments: allRules)
    func ties(rule: AutoSelectRule) {
        let files = [file("/Users/c/Keep/z", 1), file("/Users/c/Keep/a", 1), file("/Users/c/m", 1)]
        let forward = rule.filesToRemove(in: group(files))
        let backward = rule.filesToRemove(in: group(files.reversed()))
        #expect(forward == backward)
        #expect(forward.count == 2)
        // All dates equal: every rule falls back to the smallest path (inside Keep for preferredFolder too).
        #expect(rule.fileToKeep(in: group(files))?.path == "/Users/c/Keep/a")
    }

    @Test("Every rule keeps exactly one file in every group", arguments: allRules)
    func keepsExactlyOne(rule: AutoSelectRule) {
        var seed: UInt64 = 42
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        for size in 2...12 {
            for _ in 0..<20 {
                let files = (0..<size).map { i in
                    let folder = next() % 3 == 0 ? "/Users/c/Keep" : "/Users/c/Other\(next() % 2)"
                    return file("\(folder)/f\(i)", Double(next() % 4))  // few distinct dates → many ties
                }
                let g = group(files)
                let removed = rule.filesToRemove(in: g)
                let keep = rule.fileToKeep(in: g)
                #expect(removed.count == size - 1)
                #expect(keep != nil && !removed.contains(keep!))
                #expect(Set(removed.map(\.path)).count == removed.count)
            }
        }
    }

    @Test("Groups with fewer than two files remove nothing", arguments: allRules)
    func tinyGroups(rule: AutoSelectRule) {
        #expect(rule.filesToRemove(in: group([])).isEmpty)
        #expect(rule.filesToRemove(in: group([file("/a", 1)])).isEmpty)
        #expect(rule.fileToKeep(in: group([])) == nil)
    }
}
