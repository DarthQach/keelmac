import Foundation
import Testing
import SafetyKit
@testable import ProjectsKit

@Suite("Git parsers")
struct GitParserTests {
    @Test func statusOnTrackedBranch() {
        let out = """
        # branch.oid 3a2e9d5fde00e5080725ad2a94c576ffb7ada3ef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        # stash 3
        1 .M N... 100644 100644 100644 aaaa bbbb Sources/a.swift
        2 R. N... 100644 100644 100644 aaaa bbbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaaa bbbb cccc c.swift
        ? notes.txt
        ? scratch/
        ! .env
        ! node_modules/

        """
        let s = GitParsers.status(out)
        #expect(s.headSHA == "3a2e9d5fde00e5080725ad2a94c576ffb7ada3ef")
        #expect(s.headBranch == "main")
        #expect(!s.isDetached)
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.stashCount == 3)
        #expect(s.changedCount == 3)
        #expect(s.untrackedCount == 2)
        #expect(s.uncommittedCount == 5)
        #expect(s.ignored == [".env", "node_modules/"])
    }

    @Test func statusDetachedAndInitial() {
        let detached = GitParsers.status("# branch.oid abc\n# branch.head (detached)\n")
        #expect(detached.isDetached && detached.headBranch == nil && detached.headSHA == "abc")
        let initial = GitParsers.status("# branch.oid (initial)\n# branch.head main\n")
        #expect(initial.headSHA == nil && initial.headBranch == "main" && !initial.isDetached)
    }

    @Test func refsWithTracking() {
        let out = """
        refs/heads/feat\tad3f\t\t
        refs/heads/main\t3a2e\torigin/main\t[ahead 1, behind 2]
        refs/heads/old\t9999\torigin/old\t[gone]
        refs/heads/up\t8888\torigin/up\t[behind 4]
        refs/tags/v1\t3a2e\t\t
        """
        let refs = GitParsers.refs(out)
        #expect(refs.branches.map(\.name) == ["feat", "main", "old", "up"])
        #expect(refs.branches[0].upstream == nil)
        #expect(refs.branches[1].upstream == "origin/main" && refs.branches[1].ahead == 1 && refs.branches[1].behind == 2)
        #expect(refs.branches[2].upstreamGone)
        #expect(refs.branches[3].ahead == 0 && refs.branches[3].behind == 4)
        #expect(refs.tags == [TagInfo(name: "v1", sha: "3a2e")])
    }

    @Test func remotesKeepFetchLines() {
        let out = "origin\thttps://github.com/DarthQach/keelmac.git (fetch)\norigin\thttps://github.com/DarthQach/keelmac.git (push)\nlab\tgit@gitlab.com:me/x.git (fetch)\nlab\tgit@gitlab.com:me/x.git (push)\n"
        let remotes = GitParsers.remotes(out)
        #expect(remotes.count == 2)
        #expect(remotes[0].ownerRepo == "DarthQach/keelmac")
        #expect(remotes[0].webURL?.absoluteString == "https://github.com/DarthQach/keelmac")
        #expect(remotes[1].name == "lab" && !remotes[1].isGitHub)
    }

    @Test(arguments: [
        ("https://github.com/o/n.git", "o/n"),
        ("https://github.com/o/n", "o/n"),
        ("https://github.com/o/n/", "o/n"),
        ("https://user@github.com/o/n.git", "o/n"),
        ("http://www.github.com/o/n", "o/n"),
        ("git@github.com:o/n.git", "o/n"),
        ("github.com:o/n", "o/n"),
        ("ssh://git@github.com/o/n.git", "o/n"),
        ("ssh://git@github.com:22/o/n", "o/n"),
        ("git://github.com/o/n.git", "o/n"),
    ])
    func githubURLs(url: String, expected: String) {
        #expect(GitParsers.ownerRepo(fromURL: url) == expected)
    }

    @Test(arguments: ["https://gitlab.com/o/n.git", "git@bitbucket.org:o/n.git", "/Users/me/bare.git", "../origin.git",
                      "https://github.com/o", "https://github.com.evil.com/o/n", "https://github.com/o/n/extra"])
    func nonGitHubURLs(url: String) {
        #expect(GitParsers.ownerRepo(fromURL: url) == nil)
    }

    @Test func lsRemoteSkipsPeeledTags() {
        let out = "aaa\trefs/heads/main\nbbb\trefs/heads/feat\nccc\trefs/tags/v2\nddd\trefs/tags/v2^{}\n"
        let (heads, tags) = GitParsers.lsRemote(out)
        #expect(heads == ["main": "aaa", "feat": "bbb"])
        #expect(tags == ["v2": "ccc"])
    }

    @Test func commitDate() {
        #expect(GitParsers.commitDate("1792792368\n") == Date(timeIntervalSince1970: 1_792_792_368))
        #expect(GitParsers.commitDate("") == nil)
    }
}

@Suite("gh parsers and failures")
struct GitHubParserTests {
    @Test func login() {
        #expect(GitHubParsers.login(fromAPI: "DarthQach\n") == "DarthQach")
        #expect(GitHubParsers.login(fromAPI: "") == nil)
        #expect(GitHubParsers.login(fromAPI: "To get started with GitHub CLI") == nil)
    }

    @Test func repoViewAndCreate() {
        #expect(GitHubParsers.isRepoNotFound("GraphQL: Could not resolve to a Repository with the name 'DarthQach/x'. (repository)"))
        #expect(!GitHubParsers.isRepoNotFound("error connecting to api.github.com"))
        #expect(GitHubParsers.isNameTaken("GraphQL: Name already exists on this account (createRepository)"))
        #expect(GitHubParsers.repoURL(fromCreate: "✓ Created repository DarthQach/x on GitHub\n  https://github.com/DarthQach/x\n")?.absoluteString
                == "https://github.com/DarthQach/x")
    }

    @Test func classifiesFailures() {
        func f(_ err: String, exit: Int32 = 128) -> CommandFailure { CommandFailure.classify(CommandResult(exitCode: exit, stdout: "", stderr: err)) }
        #expect(f("fatal: could not read Username for 'https://github.com': Device not configured") == .authentication)
        #expect(f("git@github.com: Permission denied (publickey).") == .authentication)
        #expect(f("remote: Repository not found.\nfatal: repository 'https://github.com/o/n.git/' not found") == .repositoryNotFound)
        #expect(f("fatal: unable to access 'https://github.com/o/n.git/': Could not resolve host: github.com") == .offline)
        #expect(f(" ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs") == .rejected)
        #expect(f("Author identity unknown\n*** Please tell me who you are.") == .identityMissing)
        #expect(CommandFailure.classify(CommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)) == .timedOut)
        #expect(CommandFailure.classify(CommandResult(exitCode: 127, stdout: "", stderr: "gh: not found")) == .toolMissing)
        #expect(f("fatal: something odd\n", exit: 2) == .other(exit: 2, message: "fatal: something odd"))
    }
}

@Suite("Names and command lines")
struct NamingTests {
    @Test(arguments: [
        ("keelmac", "keelmac"),
        ("My App", "My-App"),
        ("Café  Menu!", "Cafe-Menu"),
        ("..hidden..", "hidden"),
        ("a/b\\c", "a-b-c"),
        ("🚀", "project"),
        ("v2.0_final", "v2.0_final"),
    ])
    func slugs(name: String, expected: String) {
        #expect(RepoSlug.make(name) == expected)
    }

    @Test func slugLimitAndValidity() {
        #expect(RepoSlug.make(String(repeating: "a", count: 150)).count == 100)
        #expect(RepoSlug.isValid("my-app"))
        #expect(!RepoSlug.isValid("my app"))
        #expect(!RepoSlug.isValid(""))
    }

    @Test func commandLinesQuoteOnlyWhatNeedsIt() {
        #expect(ProjectTools.commandLine("/usr/bin/git", ["-C", "/Users/me/Developer/My App", "commit", "-m", "Backup from KeelMac"])
                == "/usr/bin/git -C '/Users/me/Developer/My App' commit -m 'Backup from KeelMac'")
        #expect(ProjectTools.commandLine("/usr/bin/git", ["commit", "-m", "it's"]) == "/usr/bin/git commit -m 'it'\\''s'")
        #expect(ProjectTools.commandLine("/opt/homebrew/bin/gh", ["repo", "view", "o/n"]) == "/opt/homebrew/bin/gh repo view o/n")
    }

    @Test func ghLookup() {
        #expect(ProjectTools.gh(isExecutable: { $0 == "/usr/local/bin/gh" }) == "/usr/local/bin/gh")
        #expect(ProjectTools.gh(isExecutable: { _ in true }) == "/opt/homebrew/bin/gh")
        #expect(ProjectTools.gh(isExecutable: { _ in false }) == nil)
    }
}
