import XCTest

final class NavigationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testEverySidebarDestinationOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        for id in ["dashboard", "monitor", "storageMap", "largeOld", "systemData", "duplicates", "snapshots",
                   "cleanup", "apps", "leftovers", "loginItems", "maintenance", "projects", "operationLog"] {
            let item = window.outlines.cells.containing(.any, identifier: "sidebar.\(id)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "sidebar item \(id)")
            item.click()
            attach(window, id)
        }
    }
}

extension XCTestCase {
    /// Keeps a screenshot in the result bundle; scripts/shots.sh exports them to build/shots for design checks.
    @MainActor
    func attach(_ element: XCUIElement, _ name: String) {
        let a = XCTAttachment(screenshot: element.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
