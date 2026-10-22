import XCTest

/// Scans the real disk (read-only metadata) and keeps screenshots of the storage screens.
final class StorageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testScanAndExplore() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.outlines.cells.containing(.any, identifier: "sidebar.storageMap").firstMatch.click()
        let scan = window.buttons["Scan disk"].firstMatch
        if scan.waitForExistence(timeout: 3) { scan.click() }
        let rescan = window.buttons["Rescan"].firstMatch
        XCTAssertTrue(rescan.waitForExistence(timeout: 120), "scan finished")
        Thread.sleep(forTimeInterval: 1)
        attach(window, "live-storageMap")
        window.radioButtons["Sunburst"].firstMatch.click()
        Thread.sleep(forTimeInterval: 1)
        attach(window, "live-sunburst")
        window.radioButtons["Treemap"].firstMatch.click()
        window.outlines.cells.containing(.any, identifier: "sidebar.largeOld").firstMatch.click()
        Thread.sleep(forTimeInterval: 6)
        attach(window, "live-largeOld")
        window.outlines.cells.containing(.any, identifier: "sidebar.systemData").firstMatch.click()
        Thread.sleep(forTimeInterval: 20)
        attach(window, "live-systemData")
    }

    /// The map with AI models highlighted, then Review filtered to AI models (from the cached scan).
    @MainActor
    func testHighlightAndReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-mapHighlight", "aiModel", "-reviewKind", "aiModel", "-reviewMonths", "0", "-largeMinBytes", "100000000"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.outlines.cells.containing(.any, identifier: "sidebar.storageMap").firstMatch.click()
        let scan = window.buttons["Scan disk"].firstMatch
        if scan.waitForExistence(timeout: 3) { scan.click() }
        XCTAssertTrue(window.buttons["Rescan"].firstMatch.waitForExistence(timeout: 120), "scan ready")
        Thread.sleep(forTimeInterval: 8)
        attach(window, "live-storageMap-highlight")
        window.outlines.cells.containing(.any, identifier: "sidebar.largeOld").firstMatch.click()
        Thread.sleep(forTimeInterval: 10)
        attach(window, "live-review")
    }
}
