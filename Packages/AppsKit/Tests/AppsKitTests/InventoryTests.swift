import Foundation
import Testing
@testable import AppsKit

@Suite struct InventoryTests {
    @Test func scansBundlesAndOneLevelOfSubfolders() async throws {
        let fx = Fixture()
        fx.app("Applications/Foo.app", bundleID: "com.foo.app", name: "FooName", displayName: "Foo Display", version: "2.3")
        fx.app("Applications/Bar.app", bundleID: "com.bar.app", name: "Bar")
        fx.dir("Applications/NoPlist.app/Contents")
        fx.app("Applications/Utilities/Tool.app", bundleID: "com.tools.tool", name: "Tool")
        fx.app("Applications/Vendor/Suite.app", bundleID: "com.vendor.suite", name: "Suite")
        fx.app("Applications/Vendor/Deeper/TooDeep.app", bundleID: "com.vendor.deep", name: "TooDeep")
        fx.app("Applications/Pages.app", bundleID: "com.apple.iWork.Pages", name: "Pages")
        fx.app("Elsewhere/Real.app", bundleID: "com.real.app", name: "Real")
        try FileManager.default.createSymbolicLink(atPath: fx.path("Applications/Linked.app"), withDestinationPath: fx.path("Elsewhere/Real.app"))
        fx.app("Applications/Thing.bundle/Inner.app", bundleID: "com.bundle.inner", name: "Inner")
        fx.app("User/Applications/Mine.app", bundleID: "com.mine.app", name: "Mine")

        let apps = await AppInventory.scan(folders: [fx.path("Applications"), fx.path("User/Applications")])
        let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["Foo Display", "Bar", "NoPlist", "Tool", "Suite", "Pages", "Mine"])
        let foo = try #require(byName["Foo Display"])
        #expect(foo.bundleID == "com.foo.app")
        #expect(foo.version == "2.3")
        #expect(foo.id == foo.path)
        #expect(foo.path == fx.path("Applications/Foo.app"))
        #expect((foo.bytes ?? 0) >= 64 * 1024)
        #expect(foo.teamID == nil)          // unsigned fixture
        #expect(!foo.isApple)
        #expect(byName["Pages"]?.isApple == true)
        #expect(byName["NoPlist"]?.bundleID == nil)
        #expect(byName["Tool"]?.path == fx.path("Applications/Utilities/Tool.app"))
    }

    @Test func fastScanSkipsMeasuring() async {
        let fx = Fixture()
        fx.app("Applications/Foo.app", bundleID: "com.foo.app", name: "Foo")
        let apps = await AppInventory.scan(folders: [fx.path("Applications")], measure: false)
        #expect(apps.count == 1)
        #expect(apps.first?.bytes == nil)
        let measured = AppInventory.measure(apps[0])
        #expect((measured.bytes ?? 0) > 0)
    }

    @Test func neverListsSystemApplications() async {
        let apps = await AppInventory.scan(folders: ["/System/Applications"], measure: false)
        #expect(apps.isEmpty)
    }

    @Test func defaultFolders() {
        #expect(AppInventory.defaultFolders(home: "/Users/x") == ["/Applications", "/Users/x/Applications"])
    }

    @Test func appAtPathReadsBundle() {
        let fx = Fixture()
        let path = fx.app("Trash/Gone.app", bundleID: "com.gone.app", name: "Gone")
        let app = AppInventory.app(at: path)
        #expect(app?.bundleID == "com.gone.app")
        #expect(app?.name == "Gone")
        #expect(AppInventory.app(at: fx.path("Trash/missing.app")) == nil)
    }

    @Test func allocatedSizeCountsHardLinksOnce() throws {
        let fx = Fixture()
        let a = fx.file("sizes/a.bin", bytes: 100_000)
        try FileManager.default.linkItem(atPath: a, toPath: fx.path("sizes/b.bin"))
        let single = FileSizer.allocatedSize(of: a)
        let folder = FileSizer.allocatedSize(of: fx.path("sizes"))
        #expect(single >= 100_000)
        #expect(folder < single * 2)
        #expect(FileSizer.allocatedSize(of: fx.path("nothing")) == 0)
    }

    @Test func identifierRules() {
        #expect(Identifiers.looksLikeBundleID("com.foo.app"))
        #expect(Identifiers.looksLikeBundleID("us.zoom.xos"))
        #expect(!Identifiers.looksLikeBundleID("com.foo"))
        #expect(!Identifiers.looksLikeBundleID("Google Chrome"))
        #expect(!Identifiers.looksLikeBundleID("1.2.3"))
        #expect(Identifiers.containsOnBoundary("group.com.foo.app", "com.foo.app"))
        #expect(Identifiers.containsOnBoundary("ABCDE12345.com.foo.app.shared", "com.foo.app"))
        #expect(!Identifiers.containsOnBoundary("group.com.foo.application", "com.foo.app"))
        #expect(Identifiers.vendorKey("com.google.Chrome") == "com.google")
        #expect(Identifiers.vendorKey("com.github.user.tool") == "com.github.user")
        #expect(Identifiers.vendorKey("com.github.tool") == nil)
        #expect(Identifiers.strippingByHostSuffix("com.foo.app.0E5F2A4B-1C2D-3E4F-5A6B-7C8D9E0F1A2B") == "com.foo.app")
        #expect(Identifiers.isApple("group.com.apple.notes"))
        #expect(Identifiers.isApple("74J34U3R6X.com.apple.iWork"))
        #expect(!Identifiers.isApple("com.applesauce.app"))
    }
}
