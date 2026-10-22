import XCTest

/// Opens the main screens with live data and keeps screenshots for design checks (scripts/shots.sh).
final class ScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testLiveScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        for (id, wait) in [("leftovers", 15.0), ("loginItems", 8.0), ("dashboard", 2.0), ("maintenance", 1.0)] {
            app.activate()
            let item = window.outlines.cells.containing(.any, identifier: "sidebar.\(id)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            Thread.sleep(forTimeInterval: wait)
            attach(window, "live-\(id)")
        }
    }

    /// Cleanup with its largest rule opened, so the nesting shows.
    @MainActor
    func testCleanup() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.outlines.cells.containing(.any, identifier: "sidebar.cleanup").firstMatch.click()
        let rule = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cleanup.rule.'")).firstMatch
        XCTAssertTrue(rule.waitForExistence(timeout: 60), "plan ready")
        rule.click()
        Thread.sleep(forTimeInterval: 1)
        attach(window, "live-cleanup")
    }
}
