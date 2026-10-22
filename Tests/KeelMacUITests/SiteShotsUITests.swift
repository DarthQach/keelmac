import XCTest

/// Light-mode product shots for the website, and a Spanish pass (scripts/shots.sh exports them).
final class SiteShotsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func visit(_ app: XCUIApplication, _ window: XCUIElement, _ id: String, wait: Double, name: String) {
        app.activate()
        let item = window.outlines.cells.containing(.any, identifier: "sidebar.\(id)").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), id)
        item.click()
        Thread.sleep(forTimeInterval: wait)
        attach(window, name)
    }

    @MainActor
    func testLightShots() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-appearance", "light"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        visit(app, window, "dashboard", wait: 6, name: "site-dashboard")
        visit(app, window, "storageMap", wait: 4, name: "site-storage")
        visit(app, window, "cleanup", wait: 14, name: "site-cleanup")
        visit(app, window, "monitor", wait: 10, name: "site-menubar")
        visit(app, window, "maintenance", wait: 2, name: "site-maintenance")
    }

    @MainActor
    func testSpanish() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-AppleLanguages", "(es)", "-AppleLocale", "es_MX"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        visit(app, window, "dashboard", wait: 5, name: "es-dashboard")
        visit(app, window, "cleanup", wait: 14, name: "es-cleanup")
    }
}
