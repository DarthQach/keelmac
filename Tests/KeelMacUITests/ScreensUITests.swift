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
        for (id, wait) in [("cleanup", 14.0), ("dashboard", 3.0)] {
            let item = window.outlines.cells.containing(.any, identifier: "sidebar.\(id)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            Thread.sleep(forTimeInterval: wait)
            attach(window, "live-\(id)")
        }
    }
}
