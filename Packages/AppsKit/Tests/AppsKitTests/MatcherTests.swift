import Foundation
import SafetyKit
import Testing
@testable import AppsKit

@Suite struct MatcherTests {
    func installed(_ fx: Fixture, _ rel: String, bundleID: String?, name: String, teamID: String? = nil) -> InstalledApp {
        let path = fx.app(rel, bundleID: bundleID, name: name)
        return InstalledApp(name: name, path: path, bundleID: bundleID, version: "1", teamID: teamID,
                            bytes: nil, lastUsed: nil, isApple: false)
    }

    func find(_ app: InstalledApp, _ fx: Fixture, _ all: [InstalledApp], guard g: PathGuard? = nil) -> [String: RelatedFile] {
        let files = RelatedFileMatcher.find(for: app, home: fx.home, installed: all, systemLibrary: nil, pathGuard: g)
        return Dictionary(uniqueKeysWithValues: files.map { (String($0.path.dropFirst(fx.library.count + 1)), $0) })
    }

    @Test func matchesBundleIDExactlyAndAsPrefix() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        fx.file("home/Library/Containers/com.foo.app/Data/x", bytes: 10_000)
        fx.file("home/Library/Containers/com.foo.app.ShareExtension/Data/x")
        fx.file("home/Library/Containers/com.foo.application/Data/x")      // different app
        fx.file("home/Library/Containers/com.foo.ap/Data/x")               // shorter id
        fx.plist("home/Library/Preferences/com.foo.app.plist", ["a": 1])
        fx.plist("home/Library/Preferences/com.foo.app.helper.plist", ["a": 1])
        fx.plist("home/Library/Preferences/com.foo.apple.plist", ["a": 1])
        fx.plist("home/Library/Preferences/ByHost/com.foo.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B.plist", ["a": 1])
        fx.file("home/Library/Caches/com.foo.app/cache.db")
        fx.file("home/Library/Saved Application State/com.foo.app.savedState/windows.plist")
        fx.file("home/Library/HTTPStorages/com.foo.app/x")
        fx.file("home/Library/HTTPStorages/com.foo.app.binarycookies")
        fx.file("home/Library/WebKit/com.foo.app/x")
        fx.file("home/Library/Logs/com.foo.app/log.txt")
        fx.file("home/Library/Application Scripts/com.foo.app/x")
        fx.file("home/Library/Application Support/com.foo.app/data")

        let found = find(app, fx, [app])
        #expect(Set(found.keys) == [
            "Containers/com.foo.app", "Containers/com.foo.app.ShareExtension",
            "Preferences/com.foo.app.plist", "Preferences/com.foo.app.helper.plist",
            "Preferences/ByHost/com.foo.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B.plist",
            "Caches/com.foo.app", "Saved Application State/com.foo.app.savedState",
            "HTTPStorages/com.foo.app", "HTTPStorages/com.foo.app.binarycookies", "WebKit/com.foo.app",
            "Logs/com.foo.app", "Application Scripts/com.foo.app", "Application Support/com.foo.app",
        ])
        #expect(found["Containers/com.foo.app"]?.location == .containers)
        #expect(found["Preferences/ByHost/com.foo.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B.plist"]?.location == .preferences)
        #expect(found["Containers/com.foo.app"]?.isShared == false)
        #expect((found["Containers/com.foo.app"]?.bytes ?? 0) >= 10_000)
        #expect(found.values.allSatisfy { !$0.needsHelper && $0.reason == .bundleID && $0.modified != nil })
    }

    @Test func matchesNameOnlyWhenEqualNeverSubstring() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Code.app", bundleID: "com.microsoft.VSCode", name: "Code")
        fx.file("home/Library/Application Support/Code/User/settings.json")
        fx.file("home/Library/Application Support/Xcode/x")
        fx.file("home/Library/Application Support/CodeRunner/x")
        fx.file("home/Library/Application Support/Code Helper/x")
        fx.file("home/Library/Caches/code/x")                       // case-insensitive equality
        fx.file("home/Library/Logs/Code/x")
        fx.file("home/Library/Logs/Xcode/x")
        fx.file("home/Library/Containers/Code/x")                   // name rule doesn't apply to Containers
        fx.file("home/Library/Preferences/Code.plist")              // nor Preferences

        let found = find(app, fx, [app])
        #expect(Set(found.keys) == ["Application Support/Code", "Caches/code", "Logs/Code"])
        #expect(found.values.allSatisfy { $0.reason == .name && !$0.isShared })
    }

    @Test func matchesNameByFileNameAndBundleName() {
        let fx = Fixture()
        let path = fx.app("Applications/Google Chrome.app", bundleID: "com.google.Chrome", name: "Chrome",
                          displayName: "Google Chrome")
        let app = InstalledApp(name: "Google Chrome", path: path, bundleID: "com.google.Chrome", version: nil,
                               teamID: nil, bytes: nil, lastUsed: nil, isApple: false)
        fx.file("home/Library/Caches/Chrome/x")
        fx.file("home/Library/Caches/Google Chrome/x")
        let found = find(app, fx, [app])
        #expect(Set(found.keys) == ["Caches/Chrome", "Caches/Google Chrome"])
    }

    @Test func longerBundleIDOfAnotherAppWins() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        let pro = installed(fx, "Applications/Foo Pro.app", bundleID: "com.foo.app.pro", name: "Foo Pro")
        fx.file("home/Library/Containers/com.foo.app/x")
        fx.file("home/Library/Containers/com.foo.app.pro/x")
        fx.plist("home/Library/Preferences/com.foo.app.pro.plist", ["a": 1])

        let found = find(app, fx, [app, pro])
        #expect(Set(found.keys) == ["Containers/com.foo.app"])
        let proFound = find(pro, fx, [app, pro])
        #expect(Set(proFound.keys) == ["Containers/com.foo.app.pro", "Preferences/com.foo.app.pro.plist"])
    }

    @Test func subIDThatIsASeparateRegisteredAppIsLeftOut() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Google Chrome.app", bundleID: "com.google.Chrome", name: "Chrome")
        fx.plist("home/Library/Preferences/com.google.Chrome.plist", ["a": 1])
        fx.plist("home/Library/Preferences/com.google.chrome.for.testing.plist", ["a": 1])
        fx.plist("home/Library/Preferences/com.google.Chrome.helper.plist", ["a": 1])
        let appPath = app.path
        let files = RelatedFileMatcher.find(for: app, home: fx.home, installed: [app], systemLibrary: nil, pathGuard: nil,
                                            registeredAppPaths: { id in
            switch id.lowercased() {
            case "com.google.chrome.for.testing": ["/Users/x/Library/Caches/ms-playwright/Google Chrome for Testing.app"]
            case "com.google.chrome.helper": [appPath + "/Contents/Frameworks/Helper.app"]   // inside the bundle
            default: []
            }
        })
        let names = Set(files.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["com.google.Chrome.plist", "com.google.Chrome.helper.plist"])
    }

    @Test func secondCopyOfTheSameAppMakesEverythingShared() {
        let fx = Fixture()
        let a = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        let b = installed(fx, "home/Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        fx.file("home/Library/Containers/com.foo.app/x")
        fx.file("home/Library/Application Support/Foo/x")
        let found = find(a, fx, [a, b])
        #expect(found.count == 2)
        #expect(found.values.allSatisfy { $0.isShared })
    }

    @Test func sharedVendorFolderIsFlagged() {
        let fx = Fixture()
        let ps = installed(fx, "Applications/Adobe Photoshop.app", bundleID: "com.adobe.Photoshop", name: "Adobe Photoshop")
        let ai = installed(fx, "Applications/Adobe Illustrator.app", bundleID: "com.adobe.Illustrator", name: "Adobe Illustrator")
        fx.file("home/Library/Application Support/Adobe/Adobe Photoshop/prefs", bytes: 8192)
        fx.file("home/Library/Application Support/Adobe/Common/shared.db")
        fx.file("home/Library/Application Support/Adobe/Adobe Illustrator/prefs")

        let found = find(ps, fx, [ps, ai])
        #expect(Set(found.keys) == ["Application Support/Adobe", "Application Support/Adobe/Adobe Photoshop"])
        #expect(found["Application Support/Adobe"]?.isShared == true)
        #expect(found["Application Support/Adobe"]?.reason == .vendorFolder)
        #expect(found["Application Support/Adobe/Adobe Photoshop"]?.isShared == false)
        #expect(found["Application Support/Adobe/Common"] == nil)
    }

    @Test func vendorFolderWithOnlyThisAppIsNotShared() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Widget.app", bundleID: "com.acme.widget", name: "Widget")
        fx.file("home/Library/Application Support/Acme/Widget/x")
        let found = find(app, fx, [app])
        #expect(Set(found.keys) == ["Application Support/Acme"])
        #expect(found["Application Support/Acme"]?.isShared == false)

        // Something else in the vendor folder: shared, and the app's own folder listed separately.
        fx.file("home/Library/Application Support/Acme/Licensing/x")
        let again = find(app, fx, [app])
        #expect(again["Application Support/Acme"]?.isShared == true)
        #expect(again["Application Support/Acme/Widget"]?.isShared == false)
    }

    @Test func groupContainersByTeamIDAndGroupID() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo", teamID: "ABCDE12345")
        fx.file("home/Library/Group Containers/ABCDE12345.shared/x")
        fx.file("home/Library/Group Containers/group.ABCDE12345.sync/x")
        fx.file("home/Library/Group Containers/group.com.foo.app/x")
        fx.file("home/Library/Group Containers/ABCDE12345.com.foo.app.widgets/x")
        fx.file("home/Library/Group Containers/ZZZZZ99999.other/x")
        fx.file("home/Library/Group Containers/group.com.foo.application/x")

        let alone = find(app, fx, [app])
        #expect(Set(alone.keys) == ["Group Containers/ABCDE12345.shared", "Group Containers/group.ABCDE12345.sync",
                                    "Group Containers/group.com.foo.app", "Group Containers/ABCDE12345.com.foo.app.widgets"])
        #expect(alone.values.allSatisfy { !$0.isShared })
        #expect(alone["Group Containers/ABCDE12345.shared"]?.reason == .teamID)

        // Another installed app from the same team: team-only containers become shared; ones naming us stay ours.
        let sibling = installed(fx, "Applications/Bar.app", bundleID: "com.foo.bar", name: "Bar", teamID: "ABCDE12345")
        let withSibling = find(app, fx, [app, sibling])
        #expect(withSibling["Group Containers/ABCDE12345.shared"]?.isShared == true)
        #expect(withSibling["Group Containers/group.ABCDE12345.sync"]?.isShared == true)
        #expect(withSibling["Group Containers/group.com.foo.app"]?.isShared == false)
        #expect(withSibling["Group Containers/ABCDE12345.com.foo.app.widgets"]?.isShared == false)
    }

    @Test func launchAgentsByLabelAndProgram() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        fx.plist("home/Library/LaunchAgents/com.foo.app.updater.plist", ["Label": "com.foo.app.updater"])
        fx.plist("home/Library/LaunchAgents/helper.plist",
                 ["Label": "org.somebody.helper", "ProgramArguments": [app.path + "/Contents/MacOS/bin", "--agent"]])
        fx.plist("home/Library/LaunchAgents/unrelated.plist",
                 ["Label": "org.other.thing", "Program": "/usr/bin/true"])
        let found = find(app, fx, [app])
        #expect(Set(found.keys) == ["LaunchAgents/com.foo.app.updater.plist", "LaunchAgents/helper.plist"])
        #expect(found["LaunchAgents/helper.plist"]?.reason == .program)
        #expect(found["LaunchAgents/helper.plist"]?.location == .launchAgents)
    }

    @Test func everyPathPassesPathGuard() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        // ~/Library/Cookies is a protected subtree in SafetyKit: matched, then dropped.
        fx.file("home/Library/Cookies/com.foo.app.binarycookies")
        fx.file("home/Library/Containers/com.foo.app/x")
        fx.file("home/Library/Caches/com.foo.app/x")
        let whitelist = PathGuard(home: fx.home, whitelist: Whitelist(["~/Library/Caches/com.foo.app"]))
        let found = find(app, fx, [app], guard: whitelist)
        #expect(Set(found.keys) == ["Containers/com.foo.app"])
    }

    @Test func appWithoutBundleIDMatchesByNameOnly() {
        let fx = Fixture()
        let app = installed(fx, "Applications/Plain.app", bundleID: nil, name: "Plain")
        fx.file("home/Library/Application Support/Plain/x")
        fx.file("home/Library/Containers/Plain/x")
        let found = find(app, fx, [app])
        #expect(Set(found.keys) == ["Application Support/Plain"])
    }

    @Test func systemLibraryItemsNeedTheHelper() {
        // Reads the real /Library (read-only) for an id that can't exist: nothing comes back, nothing is touched.
        let fx = Fixture()
        let app = installed(fx, "Applications/Foo.app", bundleID: "mx.keelmac.test.nonexistent", name: "KeelMacNope")
        let files = RelatedFileMatcher.find(for: app, home: fx.home, installed: [app])
        #expect(files.isEmpty)
    }
}
