import Foundation
import SafetyKit
import Testing
@testable import AppsKit

@Suite struct LaunchItemTests {
    let uid: UInt32 = 501

    func store(_ fx: Fixture, installed: [InstalledApp], runner: RecordingCommandRunner) -> LaunchItemStore {
        LaunchItemStore(home: fx.home, uid: uid, runner: runner, installed: installed,
                        globalAgentsFolder: fx.path("Library/LaunchAgents"),
                        globalDaemonsFolder: fx.path("Library/LaunchDaemons"))
    }

    static let guiOutput = """
    disabled services = {
    \t\t"com.user.disabled" => disabled
    \t\t"com.user.overridden" => enabled
    \t\t"com.old.style" => true
    \t}
    login item associations = {
    \t\t"com.something" => (null)
    \t}
    """
    static let systemOutput = """
    disabled services = {
    \t\t"com.vendor.daemon" => disabled
    \t}
    """

    func runner() -> RecordingCommandRunner {
        RecordingCommandRunner { exe, args in
            guard exe == "/bin/launchctl", args.first == "print-disabled" else { return CommandResult(exitCode: 0, stdout: "", stderr: "") }
            return CommandResult(exitCode: 0, stdout: args.last == "system" ? Self.systemOutput : Self.guiOutput, stderr: "")
        }
    }

    @Test func parsesEveryScheduleKind() {
        func schedule(_ dict: [String: Any]) -> LaunchSchedule { LaunchdPlist.parse(dict, fallbackLabel: "x").schedule }
        #expect(schedule(["RunAtLoad": true]) == .atLoad)
        #expect(schedule(["KeepAlive": true, "RunAtLoad": true]) == .keepAlive)
        #expect(schedule(["KeepAlive": ["SuccessfulExit": false]]) == .keepAlive)
        #expect(schedule(["KeepAlive": false, "RunAtLoad": true]) == .atLoad)
        #expect(schedule(["StartInterval": 3600, "RunAtLoad": true]) == .interval(3600))
        #expect(schedule(["StartCalendarInterval": ["Hour": 3, "Minute": 0]]) == .calendar)
        #expect(schedule(["StartCalendarInterval": [["Weekday": 1], ["Weekday": 4]]]) == .calendar)
        #expect(schedule(["WatchPaths": ["/tmp/x"]]) == .onDemand)
        #expect(schedule(["MachServices": ["com.x.xpc": true]]) == .onDemand)
        #expect(schedule([:]) == .onDemand)

        let job = LaunchdPlist.parse(["Label": "com.a.b", "ProgramArguments": ["/bin/sh", "-c", "x"],
                                      "AssociatedBundleIdentifiers": "com.a.app", "Disabled": true], fallbackLabel: "f")
        #expect(job.label == "com.a.b")
        #expect(job.executable == "/bin/sh")
        #expect(job.associatedBundleIDs == ["com.a.app"])
        #expect(job.disabledInPlist)
        #expect(LaunchdPlist.parse([:], fallbackLabel: "from.file").label == "from.file")
    }

    @Test func parsesPrintDisabledBothStyles() {
        let parsed = LaunchItemStore.parseDisabled(Self.guiOutput)
        #expect(parsed == ["com.user.disabled": true, "com.user.overridden": false, "com.old.style": true])
    }

    @Test func listsItemsWithOwnersSchedulesAndDisabledState() async throws {
        let fx = Fixture()
        let fooPath = fx.app("Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        let foo = InstalledApp(name: "Foo", path: fooPath, bundleID: "com.foo.app", version: nil, teamID: nil,
                               bytes: nil, lastUsed: nil, isApple: false)
        let barPath = fx.app("Applications/Bar.app", bundleID: "com.bar.app", name: "Bar")
        let bar = InstalledApp(name: "Bar", path: barPath, bundleID: "com.bar.app", version: nil, teamID: nil,
                               bytes: nil, lastUsed: nil, isApple: false)

        // User agents
        fx.plist("home/Library/LaunchAgents/byprogram.plist",
                 ["Label": "org.random.label", "ProgramArguments": [fooPath + "/Contents/MacOS/bin"], "RunAtLoad": true])
        fx.plist("home/Library/LaunchAgents/com.foo.app.updater.plist",
                 ["Label": "com.foo.app.updater", "Program": "/usr/bin/true", "StartInterval": 3600])
        fx.plist("home/Library/LaunchAgents/com.user.disabled.plist",
                 ["Label": "com.user.disabled", "Program": "/usr/bin/true", "KeepAlive": true])
        fx.plist("home/Library/LaunchAgents/com.user.overridden.plist",
                 ["Label": "com.user.overridden", "Program": "/usr/bin/true", "Disabled": true])
        fx.plist("home/Library/LaunchAgents/gone.plist",
                 ["Label": "com.gone.agent", "Program": "/Applications/GoneForever.app/Contents/MacOS/Gone"])
        fx.plist("home/Library/LaunchAgents/brew.plist",
                 ["Label": "homebrew.mxcl.thing", "ProgramArguments": ["/bin/sh", "-c", "true"], "WatchPaths": ["/tmp"]])
        fx.plist("home/Library/LaunchAgents/open.plist",
                 ["Label": "com.opener", "ProgramArguments": ["/usr/bin/open", "-a", "/Applications/GoneForever.app"]])
        fx.file("home/Library/LaunchAgents/notes.txt")
        // Global agents and daemons
        fx.plist("Library/LaunchAgents/assoc.plist",
                 ["Label": "net.helper.agent", "Program": "/usr/bin/true", "AssociatedBundleIdentifiers": ["com.bar.app"],
                  "StartCalendarInterval": ["Hour": 2]])
        let helperTool = fx.file("Library/PrivilegedHelperTools/com.vendor.daemon")
        fx.plist("Library/LaunchDaemons/com.vendor.daemon.plist",
                 ["Label": "com.vendor.daemon", "Program": helperTool])
        fx.plist("Library/LaunchDaemons/com.vendor2.daemon.plist",
                 ["Label": "com.vendor2.daemon", "Program": "/Library/PrivilegedHelperTools/com.vendor2.daemon.keelmac-test-missing"])

        let runner = runner()
        let items = await store(fx, installed: [foo, bar], runner: runner).list()
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })

        #expect(items.count == 10)
        #expect(runner.calls.map(\.1) == [["print-disabled", "gui/501"], ["print-disabled", "system"]])
        #expect(runner.calls.allSatisfy { $0.0 == "/bin/launchctl" })

        let byProgram = try #require(byLabel["org.random.label"])
        #expect(byProgram.ownerName == "Foo" && byProgram.ownerInstalled && byProgram.ownerBundleID == "com.foo.app")
        #expect(byProgram.schedule == .atLoad && byProgram.domain == .userAgent && !byProgram.isDisabled)

        #expect(byLabel["com.foo.app.updater"]?.ownerName == "Foo")
        #expect(byLabel["com.foo.app.updater"]?.schedule == .interval(3600))
        #expect(byLabel["com.user.disabled"]?.isDisabled == true)
        #expect(byLabel["com.user.disabled"]?.schedule == .keepAlive)
        #expect(byLabel["com.user.overridden"]?.isDisabled == false)   // override beats the plist's Disabled key

        let gone = try #require(byLabel["com.gone.agent"])
        #expect(!gone.ownerInstalled && gone.ownerName == "GoneForever" && !gone.programExists)

        let opener = try #require(byLabel["com.opener"])
        #expect(!opener.ownerInstalled && opener.ownerName == "GoneForever" && opener.programExists)

        let brew = try #require(byLabel["homebrew.mxcl.thing"])
        #expect(brew.ownerInstalled && brew.ownerName == nil && brew.schedule == .onDemand)

        let assoc = try #require(byLabel["net.helper.agent"])
        #expect(assoc.domain == .globalAgent && assoc.ownerName == "Bar" && assoc.schedule == .calendar)

        let daemon2 = try #require(byLabel["com.vendor2.daemon"])
        #expect(daemon2.domain == .globalDaemon && !daemon2.ownerInstalled)
        #expect(byLabel["com.vendor.daemon"]?.isDisabled == true)      // from the system domain
        #expect(byLabel["com.vendor.daemon"]?.needsHelper == true)

        // Sorted: user agents first.
        #expect(items.first?.domain == .userAgent && items.last?.domain == .globalDaemon)
    }

    @Test func standaloneToolIsNotAnOrphanButVendorHelperFoldersAre() {
        let fx = Fixture()
        let s = store(fx, installed: [], runner: runner())
        let job = LaunchdPlist.parse(["Label": "com.vendor.helper", "Program": "/bin/sh"], fallbackLabel: "x")
        #expect(s.item(job: job, plistPath: "/x.plist", domain: .globalDaemon, disabled: false).ownerInstalled)
        #expect(LaunchItemStore.isVendorHelperLocation("/Library/PrivilegedHelperTools/com.vendor.helper"))
        #expect(LaunchItemStore.isVendorHelperLocation("/Users/me/Library/Application Support/Vendor/agent"))
        #expect(!LaunchItemStore.isVendorHelperLocation("/opt/homebrew/bin/thing"))

        // A program inside an app that exists outside the Applications folders (a vendor support folder) is fine.
        let agentApp = fx.app("Library/Application Support/Vendor/Agent.app", bundleID: "com.othervendor.agent", name: "Agent")
        let inApp = LaunchdPlist.parse(["Label": "com.othervendor.agent", "Program": agentApp + "/Contents/MacOS/bin"], fallbackLabel: "x")
        let item = s.item(job: inApp, plistPath: "/y.plist", domain: .globalAgent, disabled: false)
        #expect(item.ownerInstalled && item.ownerName == "Agent" && item.programExists)
    }

    @Test func vendorOwnerPrefersTheShortestBundleID() {
        let fx = Fixture()
        func make(_ name: String, _ bid: String) -> InstalledApp {
            InstalledApp(name: name, path: fx.app("Applications/\(name).app", bundleID: bid, name: name), bundleID: bid,
                         version: nil, teamID: nil, bytes: nil, lastUsed: nil, isApple: false)
        }
        let apps = [make("Antigravity", "com.google.antigravity"), make("Google Chrome", "com.google.Chrome"),
                    make("Google Drive", "com.google.drivefs")]
        let s = store(fx, installed: apps, runner: runner())
        let job = LaunchdPlist.parse(["Label": "com.google.keystone.agent"], fallbackLabel: "x")
        #expect(s.ownerApp(for: job)?.name == "Google Chrome")
    }

    func userItem(_ fx: Fixture, label: String = "com.foo.agent") -> LaunchItem {
        LaunchItem(label: label, plistPath: fx.home + "/Library/LaunchAgents/\(label).plist", program: "/usr/bin/true",
                   domain: .userAgent, schedule: .atLoad, ownerName: nil, ownerInstalled: true, isDisabled: false)
    }

    @Test func disableRunsDisableThenBootout() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner()
        let item = userItem(fx)
        let outcome = await store(fx, installed: [], runner: runner).apply(item, enabled: false)
        #expect(outcome == .changed(CommandResult(exitCode: 0, stdout: "", stderr: "")))
        #expect(runner.calls.map(\.0) == ["/bin/launchctl", "/bin/launchctl"])
        #expect(runner.calls.map(\.1) == [["disable", "gui/501/com.foo.agent"], ["bootout", "gui/501/com.foo.agent"]])
    }

    @Test func enableRunsEnableThenBootstrap() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner()
        let item = userItem(fx)
        let result = await store(fx, installed: [], runner: runner).setEnabled(item, true)
        #expect(result.succeeded)
        #expect(runner.calls.map(\.1) == [["enable", "gui/501/com.foo.agent"], ["bootstrap", "gui/501", item.plistPath]])
    }

    @Test func alreadyLoadedBootstrapDoesNotFailTheChange() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner { _, args in
            args.first == "bootstrap" ? CommandResult(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5") : CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let outcome = await store(fx, installed: [], runner: runner).apply(userItem(fx), enabled: true)
        if case .changed = outcome {} else { Issue.record("expected .changed, got \(outcome)") }
    }

    @Test func failedDisableStopsBeforeBootout() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 1, stdout: "", stderr: "denied") }
        let outcome = await store(fx, installed: [], runner: runner).apply(userItem(fx), enabled: false)
        #expect(outcome == .failed(CommandResult(exitCode: 1, stdout: "", stderr: "denied")))
        #expect(runner.calls.count == 1)
    }

    @Test func systemItemsNeedTheHelperAndRunNothing() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner()
        let s = store(fx, installed: [], runner: runner)
        for domain in [LaunchDomain.globalAgent, .globalDaemon] {
            let item = LaunchItem(label: "com.vendor.daemon", plistPath: "/Library/LaunchDaemons/com.vendor.daemon.plist",
                                  program: nil, domain: domain, schedule: .keepAlive, ownerName: nil,
                                  ownerInstalled: false, isDisabled: false)
            #expect(await s.apply(item, enabled: false) == .needsHelper(label: "com.vendor.daemon", plistPath: item.plistPath))
            #expect(await s.setEnabled(item, false).exitCode == 77)
            #expect(await s.unload(item) == .needsHelper(label: "com.vendor.daemon", plistPath: item.plistPath))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func unloadToleratesNotLoaded() async {
        let fx = Fixture()
        let runner = RecordingCommandRunner { _, _ in CommandResult(exitCode: 3, stdout: "", stderr: "No such process") }
        let outcome = await store(fx, installed: [], runner: runner).unload(userItem(fx))
        if case .changed = outcome {} else { Issue.record("expected .changed") }
        #expect(runner.calls.map(\.1) == [["bootout", "gui/501/com.foo.agent"]])
    }
}
