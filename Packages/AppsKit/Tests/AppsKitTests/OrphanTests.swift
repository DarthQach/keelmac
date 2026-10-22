import Foundation
import Testing
@testable import AppsKit

@Suite struct OrphanTests {
    /// Fixture files are brand new; evaluate as if a month had passed so the idle rule doesn't hide them.
    func options(_ fx: Fixture, running: Set<String> = [], inUse: Set<String> = [],
                 registered: Set<String> = [], launchd: [String] = [], now: Date = Date().addingTimeInterval(30 * 86_400)) -> OrphanFinder.Options {
        let reg = registered
        return OrphanFinder.Options(runningBundleIDs: running, pathsInUse: inUse,
                                    isRegisteredApp: { reg.contains($0) }, launchdFolders: launchd, now: now)
    }

    func app(_ fx: Fixture, _ rel: String, _ bid: String, teamID: String? = nil) -> InstalledApp {
        let path = fx.app(rel, bundleID: bid, name: BundleReader.stem(of: rel))
        return InstalledApp(name: BundleReader.stem(of: rel), path: path, bundleID: bid, version: nil, teamID: teamID,
                            bytes: nil, lastUsed: nil, isApple: false)
    }

    func ids(_ groups: [LeftoverGroup]) -> Set<String> { Set(groups.map(\.id)) }

    @Test func groupsLeftoversByBundleID() throws {
        let fx = Fixture()
        fx.file("home/Library/Containers/com.gone.app/Data/x", bytes: 20_000)
        fx.plist("home/Library/Preferences/com.gone.app.plist", ["a": 1])
        fx.plist("home/Library/Preferences/ByHost/com.gone.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B.plist", ["a": 1])
        fx.file("home/Library/Caches/com.gone.app/x")
        fx.file("home/Library/Caches/com.gone.app.ShipIt/x")
        fx.file("home/Library/Saved Application State/com.gone.app.savedState/x")
        fx.file("home/Library/Application Support/com.gone.app/x")
        fx.file("home/Library/Group Containers/group.com.gone.app/x")

        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx))
        #expect(ids(groups) == ["com.gone.app"])
        let group = try #require(groups.first)
        #expect(group.files.count == 8)
        #expect(group.displayName == "Gone")
        #expect(group.bytes == group.files.reduce(0) { $0 + $1.bytes })
        #expect(group.bytes >= 20_000)
        #expect(Set(group.files.map(\.location)) == [.containers, .preferences, .caches, .savedState,
                                                     .applicationSupport, .groupContainers])
    }

    @Test func neverListsAppleIDs() {
        let fx = Fixture()
        fx.file("home/Library/Containers/com.apple.Notes/x")
        fx.plist("home/Library/Preferences/com.apple.finder.plist", ["a": 1])
        fx.file("home/Library/Group Containers/group.com.apple.notes/x")
        fx.file("home/Library/Group Containers/74J34U3R6X.com.apple.iWork/x")
        fx.file("home/Library/Group Containers/com.apple.Home.group/x")
        fx.file("home/Library/Caches/com.apple.Safari/x")
        fx.file("home/Library/Saved Application State/com.apple.Terminal.savedState/x")
        #expect(OrphanFinder.find(home: fx.home, installed: [], options: options(fx)).isEmpty)
    }

    @Test func neverListsInstalledIDsTheirSubIDsOrTheirPrefixes() {
        let fx = Fixture()
        let installed = [app(fx, "Applications/Foo Pro.app", "com.foo.app.pro"),
                         app(fx, "Applications/Bar.app", "net.bar.editor")]
        fx.file("home/Library/Containers/com.foo.app.pro/x")              // exact
        fx.file("home/Library/Containers/com.foo.app.pro.ShareExt/x")     // sub-id
        fx.file("home/Library/Containers/com.foo.app/x")                  // prefix of an installed id
        fx.file("home/Library/Containers/net.bar.editor-LoginHelper/x")   // login item style
        fx.file("home/Library/Containers/net.bar.updater/x")              // same vendor
        fx.file("home/Library/Containers/org.unrelated.tool/x")
        let groups = OrphanFinder.find(home: fx.home, installed: installed, options: options(fx))
        #expect(ids(groups) == ["org.unrelated.tool"])
    }

    @Test func embeddedBundlesCountAsInstalled() {
        let fx = Fixture()
        let host = app(fx, "Applications/Host.app", "com.host.main")
        fx.app("Applications/Host.app/Contents/Library/LoginItems/Launcher.app", bundleID: "io.other.launcher", name: "Launcher")
        _ = host
        fx.file("home/Library/Containers/io.other.launcher/x")
        #expect(OrphanFinder.find(home: fx.home, installed: [host], options: options(fx)).isEmpty)
    }

    @Test func neverListsRunningRegisteredOrInUse() {
        let fx = Fixture()
        fx.file("home/Library/Containers/com.running.app/x")
        fx.file("home/Library/Containers/com.registered.app/x")
        let open = fx.file("home/Library/Containers/com.busy.app/db.sqlite")
        fx.file("home/Library/Containers/com.gone.app/x")
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(
            fx, running: ["com.running.app"], inUse: [open], registered: ["com.registered.app"]))
        #expect(ids(groups) == ["com.gone.app"])
    }

    @Test func neverListsRecentlyModified() {
        let fx = Fixture()
        fx.file("home/Library/Containers/com.fresh.app/x")
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx, now: Date()))
        #expect(groups.isEmpty)
    }

    @Test func oneRecentFileKeepsTheWholeGroup() {
        let fx = Fixture()
        let old = Date().addingTimeInterval(-60 * 86_400)
        fx.dir("home/Library/Caches/com.mixed.app")
        fx.setModified(fx.path("home/Library/Caches/com.mixed.app"), old)
        fx.plist("home/Library/Preferences/com.mixed.app.plist", ["a": 1])   // written now
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx, now: Date()))
        #expect(groups.isEmpty)
    }

    @Test func neverListsSharedSDKAndToolchainIDs() {
        let fx = Fixture()
        fx.file("home/Library/Caches/com.crashlytics.data/x")
        fx.file("home/Library/Caches/com.plausiblelabs.crashreporter.data/x")
        fx.file("home/Library/Caches/org.swift.swiftpm/x")
        fx.file("home/Library/Caches/com.google.Keystone/x")
        fx.file("home/Library/Caches/io.sentry/x")
        #expect(OrphanFinder.find(home: fx.home, installed: [], options: options(fx)).isEmpty)
    }

    @Test func launchdLabelsKeepIDsOwned() {
        let fx = Fixture()
        fx.plist("launchd/com.agent.thing.plist", ["Label": "com.agent.thing", "Program": "/usr/bin/true"])
        fx.plist("home/Library/Preferences/com.agent.thing.plist", ["a": 1])
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx, launchd: [fx.path("launchd")]))
        #expect(groups.isEmpty)
    }

    @Test func teamGroupContainersFollowInstalledTeams() {
        let fx = Fixture()
        fx.file("home/Library/Group Containers/ABCDE12345.shared/x")
        fx.file("home/Library/Group Containers/ZZZZZ99999.data/x")
        let installed = [app(fx, "Applications/Foo.app", "com.foo.app", teamID: "ABCDE12345")]
        let groups = OrphanFinder.find(home: fx.home, installed: installed, options: options(fx))
        #expect(ids(groups) == ["ZZZZZ99999.data"])
        #expect(groups.first?.displayName == "Data")
    }

    @Test func ignoresNamesThatAreNotBundleIDs() {
        let fx = Fixture()
        fx.file("home/Library/Application Support/Some App/x")
        fx.file("home/Library/Caches/com.short/x")
        fx.file("home/Library/Caches/Homebrew/x")
        fx.plist("home/Library/Preferences/loginwindow.plist", ["a": 1])
        fx.file("home/Library/Preferences/com.not.a.folder.plist/x")         // a folder named like a plist
        #expect(OrphanFinder.find(home: fx.home, installed: [], options: options(fx)).isEmpty)
    }

    @Test func toolFoldersWithoutAppTracesAreNotOffered() {
        let fx = Fixture()
        // A CLI's config and cache (Application Support + Caches only) look like bundle ids but aren't apps.
        fx.file("home/Library/Application Support/com.vercel.cli/auth.json")
        fx.file("home/Library/Caches/com.vercel.cli/x")
        fx.file("home/Library/Caches/dev.biomejs.biome/x")
        // The same id with an app trace is offered.
        fx.file("home/Library/Application Support/com.gone.app/x")
        fx.file("home/Library/Saved Application State/com.gone.app.savedState/x")
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx))
        #expect(ids(groups) == ["com.gone.app"])
        #expect(groups.first?.files.count == 2)
    }

    @Test func bareGroupContainersAreNeverOffered() {
        let fx = Fixture()
        fx.file("home/Library/Group Containers/com.facebook.family/x")
        fx.file("home/Library/Group Containers/is.workflow.my.app/x")
        fx.file("home/Library/Group Containers/group.com.gone.thing/x")
        let groups = OrphanFinder.find(home: fx.home, installed: [], options: options(fx))
        #expect(ids(groups) == ["com.gone.thing"])
    }

    @Test func vendorWordsOfInstalledAppsKeepIDsOwned() {
        let fx = Fixture()
        let dji = app(fx, "Applications/DJI Assistant 2.app", "DJI.Assistant")
        fx.plist("home/Library/Preferences/com.dji-dji-assistant-2-consumer.Accounts.plist", ["a": 1])
        fx.plist("home/Library/Preferences/com.unrelated-vendor.thing.plist", ["a": 1])
        let groups = OrphanFinder.find(home: fx.home, installed: [dji], options: options(fx))
        #expect(ids(groups) == ["com.unrelated-vendor.thing"])
    }

    @Test func appleLikeNamespacesAreNeverOffered() {
        let fx = Fixture()
        fx.plist("home/Library/Preferences/org.cups.PrintingPrefs.plist", ["a": 1])
        fx.file("home/Library/Containers/org.webkit.Playwright/x")
        fx.file("home/Library/Caches/com.onevcat.Kingfisher.ImageCache.default/x")
        #expect(OrphanFinder.find(home: fx.home, installed: [], options: options(fx)).isEmpty)
    }

    @Test func displayNames() {
        #expect(OrphanFinder.displayName(for: "com.raycast.macos", files: []) == "Raycast")
        #expect(OrphanFinder.displayName(for: "com.knollsoft.Rectangle", files: []) == "Rectangle")
        #expect(OrphanFinder.displayName(for: "group.com.foo.app", files: []) == "Foo")
    }
}
