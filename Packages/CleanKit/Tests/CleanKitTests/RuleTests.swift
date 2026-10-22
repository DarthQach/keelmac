import Foundation
import SafetyKit
import Testing
@testable import CleanKit

@Suite("Bundled rules file")
struct BundledRulesTests {
    @Test func decodesAndValidates() throws {
        let set = try RuleSet.bundled()
        #expect(set.schemaVersion == 1)
        #expect(set.validate().isEmpty)
        #expect(Set(set.rules.map(\.id)).count == set.rules.count)
        for rule in set.rules {
            for text in [rule.title, rule.detail] {
                #expect(!text.en.isEmpty && !text.es.isEmpty, "\(rule.id) needs en and es")
                #expect(text.en != text.es, "\(rule.id) Spanish looks untranslated")
            }
            for p in rule.paths + rule.exclude + (rule.measure ?? []) + rule.toolPaths {
                #expect(p.hasPrefix("/") || p.hasPrefix("~/"), "\(rule.id): \(p)")
                #expect(!p.contains("**"), "\(rule.id): \(p)")
            }
            if rule.kind == .command {
                #expect(rule.command != nil)
                #expect(rule.command?.executable == CleanupRule.toolPlaceholder || rule.command?.executable.hasPrefix("/") == true)
            }
        }
        // Every category of the contract has a rule.
        #expect(Set(set.rules.map(\.category)) == Set(CleanupCategory.allCases))
    }

    @Test func roundTripsThroughJSON() throws {
        let set = try RuleSet.bundled()
        let data = try JSONEncoder().encode(set)
        #expect(try RuleSet.load(from: data) == set)
    }

    @Test func onlyTheTrashDeletesPermanently() throws {
        let set = try RuleSet.bundled()
        #expect(set.rules.filter(\.deletesPermanently).map(\.id) == ["trash"])
    }

    @Test func validationCatchesMistakes() {
        let bad = RuleSet(rules: [
            rule("dup", ["~/a/*"]), rule("dup", ["relative/*"]),
            CleanupRule(id: "x y", category: .logs, title: LocalizedText(en: "", es: "e"), detail: LocalizedText(en: "d", es: "d"),
                        paths: ["~/Library/**"]),
            CleanupRule(id: "cmd", category: .developer, title: LocalizedText(en: "c", es: "c"), detail: LocalizedText(en: "c", es: "c"),
                        kind: .command, command: CommandSpec(executable: "brew", arguments: ["cleanup"])),
        ])
        let issues = bad.validate().map(\.issue)
        #expect(issues.contains(.duplicateID))
        #expect(issues.contains(.relativePath("relative/*")))
        #expect(issues.contains(.badID))
        #expect(issues.contains(.missingTranslation))
        #expect(issues.contains(.recursiveGlob("~/Library/**")))
        #expect(issues.contains(.relativeExecutable("brew")))
        #expect(throws: RuleSet.LoadError.self) { try RuleSet.load(from: try JSONEncoder().encode(bad)) }
    }

    @Test func decodesMinimalRuleWithDefaults() throws {
        let json = #"{"schemaVersion":1,"rules":[{"id":"r","category":"logs","title":{"en":"a","es":"b"},"detail":{"en":"c","es":"d"},"paths":["~/x/*"]}]}"#
        let set = try RuleSet.load(from: Data(json.utf8))
        let r = try #require(set.rules.first)
        #expect(r.kind == .paths && r.minAgeDays == 0 && !r.optIn && r.keepNewest == 0 && r.exclude.isEmpty && !r.deletesPermanently)
        #expect(r.title.value(for: "es-MX") == "b" && r.title.value(for: "en") == "a" && r.title.value(for: "fr") == "a")
        #expect(throws: RuleSet.LoadError.unsupportedSchemaVersion(2)) {
            try RuleSet.load(from: Data(json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8))
        }
    }
}

@Suite("Rules against a fixture home")
struct RuleFixtureTests {
    @Test func derivedDataSelectsProjectsOnly() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let paths = plan.paths("xcode-derived-data")
        #expect(paths == [f.path("Library/Developer/Xcode/DerivedData/ProjA-abc"), f.path("Library/Developer/Xcode/DerivedData/ProjB-def")])
        let projA = try #require(plan.group(id: "xcode-derived-data")?.items.first { $0.path.hasSuffix("ProjA-abc") })
        #expect(projA.bytes >= 64 * 1024)
        #expect(projA.fileCount == 1)
        #expect(plan.group(id: "xcode-derived-data")?.selectedByDefault == true)
    }

    @Test func archivesOlderThan90DaysAreOptIn() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        #expect(plan.paths("xcode-archives") == [f.path("Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive")])
        #expect(plan.group(id: "xcode-archives")?.selectedByDefault == false)
        #expect(!plan.defaultSelection().contains { $0.hasPrefix("xcode-archives:") })
    }

    @Test func deviceSupportKeepsNewestTwoPerPlatform() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        // iOS has three: the two newest stay. watchOS has one: it stays.
        #expect(plan.paths("xcode-device-support") == [f.path("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)")])
    }

    @Test func unavailableSimulatorsCommand() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let group = try #require(plan.group(id: "simulators-unavailable"))
        #expect(group.status == .ready)
        let item = try #require(group.items.first)
        #expect(group.items.count == 1 && item.isCommand)
        #expect(item.command?.executable == "/usr/bin/xcrun")
        #expect(item.command?.arguments == ["simctl", "delete", "unavailable"])
        #expect(item.path == "/usr/bin/xcrun simctl delete unavailable")
        let unavailable = await DirectorySizer.size(f.path("Library/Developer/CoreSimulator/Devices/\(Fixture.unavailableUDID)"))
        #expect(item.bytes == unavailable.bytes)
        guard case .simulators(let devices) = item.detail else { Issue.record("no simulator detail"); return }
        #expect(devices.map(\.udid) == [Fixture.unavailableUDID])
        #expect(devices.first?.runtime == "iOS-16-0")
    }

    @Test func simulatorsNotOfferedWhenNoneUnavailable() async throws {
        let f = try Fixture()
        _ = await f.runner().run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])   // flips the fake state
        let plan = try await f.plan()
        #expect(plan.group(id: "simulators-unavailable")?.items.isEmpty == true)
        #expect(plan.group(id: "simulators-unavailable")?.status == .ready)
    }

    @Test func simulatorsToolMissingWithoutXcode() async throws {
        let f = try Fixture()
        f.state.failCommands = []
        let runner = RecordingCommandRunner { exe, _ in
            CommandResult(exitCode: 72, stdout: "", stderr: "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")
        }
        let plan = try await f.plan(runner: runner)
        #expect(plan.group(id: "simulators-unavailable")?.status == .toolMissing)
    }

    @Test func packageManagerCachesSelectContentsOnly() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        #expect(plan.paths("swiftpm-cache") == [f.path("Library/Caches/org.swift.swiftpm/repositories"), f.path("Library/Caches/org.swift.swiftpm/manifests")])
        #expect(plan.paths("npm-cache") == [f.path(".npm/_cacache/index-v5")])
        #expect(plan.paths("yarn-cache") == [f.path("Library/Caches/Yarn/v6")])
        #expect(plan.paths("cocoapods-cache") == [f.path("Library/Caches/CocoaPods/Pods")])
        #expect(plan.paths("gradle-cache") == [f.path(".gradle/caches/modules-2")])
        let all = Set(plan.allItems.map(\.path))
        for never in [".npm/_logs", ".npm", ".gradle/wrapper", ".gradle", "Library/Caches/org.swift.swiftpm", "Library/Caches/Yarn"] {
            #expect(!all.contains(f.path(never)), "\(never) must never be selected")
        }
    }

    @Test func gradleSkippedWhileAndroidStudioRuns() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(running: ["com.google.android.studio"]))
        let g = try #require(plan.group(id: "gradle-cache"))
        #expect(g.status == .appRunning("com.google.android.studio"))
        #expect(g.items.isEmpty && !g.selectedByDefault)
        #expect(g.skipped.map(\.path) == [f.path(".gradle/caches/modules-2")])
    }

    @Test func homebrewCommandMeasuresItsCache() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let g = try #require(plan.group(id: "homebrew-cleanup"))
        let item = try #require(g.items.first)
        #expect(item.command?.executable == "/opt/homebrew/bin/brew")
        #expect(item.command?.arguments == ["cleanup", "--prune=all", "-s"])
        #expect(item.bytes == (await DirectorySizer.size(f.path("Library/Caches/Homebrew"))).bytes)
        #expect(g.toolPath == "/opt/homebrew/bin/brew")
        // The cache itself is never a path item.
        #expect(!plan.allItems.contains { !$0.isCommand && PathGuard.isWithin($0.path, f.path("Library/Caches/Homebrew")) })
    }

    @Test func toolMissingForCommandRules() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(tools: []))
        for id in ["homebrew-cleanup", "pnpm-store", "docker-prune", "simulators-unavailable"] {
            #expect(plan.group(id: id)?.status == .toolMissing, "\(id)")
            #expect(plan.group(id: id)?.items.isEmpty == true)
        }
    }

    @Test func intelHomebrewIsFound() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(tools: ["/usr/local/bin/brew"]))
        #expect(plan.group(id: "homebrew-cleanup")?.items.first?.command?.executable == "/usr/local/bin/brew")
    }

    @Test func pnpmStorePrune() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let item = try #require(plan.group(id: "pnpm-store")?.items.first)
        #expect(item.command?.executable == "/opt/homebrew/bin/pnpm" && item.command?.arguments == ["store", "prune"])
        #expect(item.bytes == (await DirectorySizer.size(f.path("Library/pnpm/store/v10"))).bytes)
        #expect(!plan.allItems.contains { !$0.isCommand && $0.path.contains("/Library/pnpm") })
    }

    @Test func dockerPruneIsOptInAndMeasured() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let g = try #require(plan.group(id: "docker-prune"))
        #expect(g.status == .ready && !g.selectedByDefault)
        let item = try #require(g.items.first)
        #expect(item.command?.executable == "/usr/local/bin/docker" && item.command?.arguments == ["system", "prune", "-f"])
        #expect(item.bytes == 120_000_000 + 1_500_000_000)   // containers + build cache; unused images not counted
        guard case .docker(let usage) = item.detail else { Issue.record("no docker detail"); return }
        #expect(usage.imagesReclaimableBytes == 2_500_000_000)
    }

    @Test func dockerDaemonNotResponding() async throws {
        let f = try Fixture()
        f.state.dockerInfoExit = 1
        let plan = try await f.plan()
        #expect(plan.group(id: "docker-prune")?.status == .toolNotResponding("docker"))
        #expect(plan.group(id: "docker-prune")?.items.isEmpty == true)
    }

    @Test func dockerNothingReclaimableOffersNothing() async throws {
        let f = try Fixture()
        f.state.dockerDF = #"{"Reclaimable":"0B","Type":"Containers"}"# + "\n" + #"{"Reclaimable":"0B","Type":"Build Cache"}"#
        let plan = try await f.plan()
        #expect(plan.group(id: "docker-prune")?.items.isEmpty == true)
    }

    @Test func userCachesSelectsAppCachesOnly() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(running: ["com.running.app"]))
        let g = try #require(plan.group(id: "user-caches"))
        let c = { (n: String) in f.path("Library/Caches/" + n) }
        #expect(plan.paths("user-caches") == [c("com.example.editor"), c("loose.cache")])
        for never in ["CloudKit", "com.apple.bird", "com.apple.iCloudNotificationAgent", "com.apple.nsservicescache.plist",
                      "ms-playwright", "com.running.app.ShipIt", "Google", "Arc", "company.thebrowser.Browser", "Firefox",
                      "Microsoft Edge", "com.apple.Safari", "com.apple.Safari.SafeBrowsing", "Homebrew", "Yarn", "CocoaPods",
                      "org.swift.swiftpm"] {
            #expect(!plan.paths("user-caches").contains(c(never)), "\(never) must never be an app cache item")
        }
        // Folders named after a running app are skipped with the reason.
        #expect(Set(g.skipped.map(\.path)) == [c("com.running.app"), c("com.running.app.helper")])
        #expect(g.skipped.allSatisfy { $0.reason == .appRunning("com.running.app") })
        #expect(g.status == .ready)
    }

    @Test func symlinksAreNeverFollowed() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        // The link itself frees nothing (0 allocated bytes), so it isn't offered; its 512 KB target is never counted.
        #expect(!plan.allItems.contains { $0.path.hasSuffix("/linked") })
        let rules = RuleSet(rules: [rule("links", ["~/Library/Caches/linked", "~/Library/Caches/linked/*"])])
        #expect(try await f.plan(rules: rules).allItems.isEmpty)
        #expect(!plan.allItems.contains { $0.path.contains("linkedvol") || $0.path.contains("/outside") })
    }

    @Test func browserCachesOnly() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        #expect(plan.paths("chrome-cache") == [f.path("Library/Caches/Google/Chrome")])
        #expect(plan.paths("arc-cache") == [f.path("Library/Caches/Arc"), f.path("Library/Caches/company.thebrowser.Browser")])
        #expect(plan.paths("firefox-cache") == [f.path("Library/Caches/Firefox/Profiles/abc.default-release/cache2")])
        #expect(plan.paths("edge-cache") == [f.path("Library/Caches/Microsoft Edge")])
        #expect(plan.paths("safari-cache") == [f.path("Library/Caches/com.apple.Safari")])
        let all = Set(plan.allItems.map(\.path))
        for never in ["Library/Caches/Google/Chrome-headless", "Library/Caches/Firefox/Profiles/abc.default-release/settings",
                      "Library/Safari", "Library/Safari/History.db", "Library/Application Support/Google/Chrome",
                      "Library/Caches/com.apple.Safari.SafeBrowsing"] {
            #expect(!all.contains(f.path(never)), "\(never)")
        }
    }

    @Test func browserSkippedWhileRunning() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(running: ["com.google.Chrome", "org.mozilla.firefox"]))
        for id in ["chrome-cache", "firefox-cache"] {
            let g = try #require(plan.group(id: id))
            #expect(g.status != .ready && g.items.isEmpty && !g.selectedByDefault && !g.skipped.isEmpty, "\(id)")
        }
        #expect(plan.group(id: "chrome-cache")?.status == .appRunning("com.google.Chrome"))
        #expect(plan.group(id: "chrome-cache")?.skipped.map(\.path) == [f.path("Library/Caches/Google/Chrome")])
        #expect(plan.group(id: "arc-cache")?.status == .ready)
    }

    @Test func logsOlderThanSevenDays() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        #expect(plan.paths("user-logs") == [f.path("Library/Logs/OldApp"), f.path("Library/Logs/old-file.log")])
        #expect(plan.paths("crash-reports") == [f.path("Library/Logs/DiagnosticReports/Old-2026-09-01.ips")])
        let all = Set(plan.allItems.map(\.path))
        for never in ["Library/Logs/NewApp", "Library/Logs/MixedApp", "Library/Logs/DiagnosticReports",
                      "Library/Logs/DiagnosticReports/New-2026-10-21.ips", "Library/Logs"] {
            #expect(!all.contains(f.path(never)), "\(never)")
        }
    }

    @Test func installersInDownloadsTopLevel() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        #expect(plan.paths("downloads-installers") == Set(["a.dmg", "b.pkg", "c.xip", "d.mpkg"].map { f.path("Downloads/" + $0) }))
    }

    @Test func iosBackupsAreOptInWithDeviceInfo() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let g = try #require(plan.group(id: "ios-backups"))
        #expect(!g.selectedByDefault && g.status == .ready)
        let item = try #require(g.items.first)
        #expect(item.path == f.path("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E"))
        guard case .iosBackup(let info) = item.detail else { Issue.record("no backup detail"); return }
        #expect(info.deviceName == "Carlos’s iPhone")
        #expect(info.productVersion == "18.0" && info.productType == "iPhone16,1")
        #expect(info.lastBackupDate == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(info.isEncrypted == true)
    }

    @Test func languageFilesOnlyFromUnsignedApps() async throws {
        let f = try Fixture()
        let (planner, runner) = try f.planner()
        let plan = await planner.plan()
        let res = { (l: String) in f.path("Applications/Unsigned.app/Contents/Resources/\(l).lproj") }
        // en, es, Base, en_GB, Spanish always stay; de is a preferred language of the fixture user.
        #expect(plan.paths("unsigned-app-languages") == [res("fr"), res("ja")])
        #expect(plan.group(id: "unsigned-app-languages")?.selectedByDefault == false)
        let item = try #require(plan.group(id: "unsigned-app-languages")?.items.first)
        guard case .appLanguage(let appName, _, let language) = item.detail else { Issue.record("no language detail"); return }
        #expect(appName == "Unsigned" && ["fr", "ja"].contains(language))
        let codesigned = runner.calls.filter { $0.0 == "/usr/bin/codesign" }.compactMap(\.1.last)
        #expect(Set(codesigned) == [f.path("Applications/Unsigned.app"), f.path("Applications/Embedded.app")])
    }

    @Test func trashOnAllVolumesDeletesPermanently() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let g = try #require(plan.group(id: "trash"))
        #expect(g.deletesPermanently)
        #expect(plan.paths("trash") == [f.path(".Trash/old.txt"), f.path(".Trash/Folder"), f.path("Volumes/Ext/.Trashes/501/v.txt")])
    }

    @Test func fullDiskAccessMissing() async throws {
        let f = try Fixture()
        let plan = try await f.plan(env: f.environment(fda: false))
        for id in ["safari-cache", "ios-backups", "trash"] {
            let g = try #require(plan.group(id: id))
            #expect(g.status == .needsFullDiskAccess, "\(id)")
            #expect(g.items.isEmpty && g.bytes == 0 && !g.selectedByDefault)
        }
        #expect(plan.group(id: "user-caches")?.status == .ready)
    }

    @Test func defaultSelectionSkipsOptIn() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let selection = plan.defaultSelection()
        for g in plan.groups {
            let ids = Set(g.items.map(\.id))
            if g.rule.optIn { #expect(ids.isDisjoint(with: selection), "\(g.id)") }
            else if g.status == .ready { #expect(ids.isSubset(of: selection), "\(g.id)") }
        }
        #expect(plan.bytes(selected: selection) == plan.groups.filter(\.selectedByDefault).reduce(0) { $0 + $1.bytes })
        #expect(plan.bytes(selected: ["nope"]) == 0)
    }

    @Test func noOverlappingItems() async throws {
        let f = try Fixture()
        let plan = try await f.plan()
        let paths = plan.allItems.filter { !$0.isCommand }.map(\.path)
        #expect(Set(paths).count == paths.count)
        for a in paths { for b in paths where a != b { #expect(!PathGuard.isWithin(a, b), "\(a) is inside \(b)") } }
        #expect(Set(plan.allItems.map(\.id)).count == plan.allItems.count)
    }

    @Test func emptyItemsAreNotOfferedExceptInTheTrash() async throws {
        let f = try Fixture()
        try f.dir("Library/Caches/Yarn/empty-v7")
        try f.file("Library/Caches/com.example.zero", bytes: 0)
        try f.file(".Trash/zero.txt", bytes: 0)
        let plan = try await f.plan()
        #expect(!plan.paths("yarn-cache").contains(f.path("Library/Caches/Yarn/empty-v7")))
        #expect(!plan.paths("user-caches").contains(f.path("Library/Caches/com.example.zero")))
        #expect(plan.paths("trash").contains(f.path(".Trash/zero.txt")))
    }

    @Test func planningNeverRunsARemovalCommand() async throws {
        let f = try Fixture()
        let (planner, runner) = try f.planner()
        _ = await planner.plan()
        for (exe, args) in runner.calls {
            #expect(!args.contains("delete") && !args.contains("prune") && !args.contains("cleanup"), "\(exe) \(args)")
        }
        // Nothing moved.
        #expect(f.exists("Library/Developer/Xcode/DerivedData/ProjA-abc") && f.exists(".Trash/old.txt"))
    }
}
