import XCTest

/// Synthetic scan trees only. Never scans, removes files or invokes the helper.
final class StorageMapRevampUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(theme: String = "light", language: String = "en", size: String = "1600x1000", state: String = "map") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-visual-fixtures", "-appearance", theme, "-fixture-size", size,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "es" ? "es_MX" : "en_US",
                               "-mapHighlight", "none", "-fixture-route", "storageMap", "-fixture-state", state]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "storage.folder").firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func expectLabel(_ value: String, id: String, in window: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let element = window.descendants(matching: .any).matching(identifier: id).firstMatch
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 3), .completed, "Expected \(id) to show \(value), got \(element.label)", file: file, line: line)
    }

    @MainActor
    private func sunburst(in window: XCUIElement, language: String = "en") {
        let control = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", language == "es" ? "Anillos" : "Sunburst")).firstMatch
        control.click()
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1 OR value == '1'"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        // Let native control and view transitions finish before capturing pixels.
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    func testMapSizesAndThemes() {
        for theme in ["light", "dark"] {
            for language in ["en", "es"] {
                for size in ["960x640", "1180x780", "1600x1000"] {
                    let app = launch(theme: theme, language: language, size: size)
                    let window = app.windows.firstMatch
                    attach(window, "revamp-map-treemap-\(size)-\(theme)-\(language)")
                    sunburst(in: window, language: language)
                    attach(window, "revamp-map-sunburst-\(size)-\(theme)-\(language)")
                    XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "storage.actions").firstMatch.isHittable)
                    app.terminate()
                }
            }
        }
    }

    @MainActor
    func testMapEdgeCases() {
        for state in ["map-dense", "map-dominant", "map-emptyFolder", "map-permission"] {
            let app = launch(theme: "dark", size: "1180x780", state: state)
            let window = app.windows.firstMatch
            attach(window, "revamp-\(state)-treemap")
            sunburst(in: window)
            attach(window, "revamp-\(state)-sunburst")
            XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "storage.actions").firstMatch.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testSelectionBarAtMinimumWidthSpanish() {
        let app = launch(theme: "dark", language: "es", size: "960x640")
        let window = app.windows.firstMatch
        let canvas = window.descendants(matching: .any).matching(identifier: "storage.map").firstMatch
        canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 16)).click()
        expectLabel("Library", id: "storage.selection", in: window)
        XCTAssertTrue(window.buttons["storage.open"].isHittable)
        XCTAssertTrue(window.buttons["storage.showContents"].isHittable)
        attach(window, "revamp-map-selection-960x640-dark-es")
        app.terminate()
    }

    @MainActor
    func testOtherItemsRemainBrowsable() {
        let app = launch(size: "1180x780", state: "map-grouped")
        let window = app.windows.firstMatch
        let canvas = window.descendants(matching: .any).matching(identifier: "storage.map").firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.3)).click()
        expectLabel("Other items", id: "storage.selection", in: window)
        window.descendants(matching: .any).matching(identifier: "storage.actions").firstMatch.click()
        XCTAssertTrue(app.menuItems["Reveal containing folder"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Quick Look"].exists)
        XCTAssertFalse(app.menuItems["Move to Trash…"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.menuItems["Reveal containing folder"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        window.buttons["storage.showContents"].click()
        // The grouped nodes remain normal, selectable rows in the full list.
        let row = window.descendants(matching: .any).matching(identifier: "storage.row.node-25").firstMatch
        XCTAssertTrue(row.exists)
        row.click()
        expectLabel("Small project 10", id: "storage.selection", in: window)
        XCTAssertTrue(window.buttons["storage.open"].isEnabled)
        attach(window, "revamp-map-other-items-list")
        app.terminate()
    }

    @MainActor
    func testMapListNavigationAndSyntheticSafety() {
        let app = launch()
        let window = app.windows.firstMatch
        let canvas = window.descendants(matching: .any).matching(identifier: "storage.map").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        // Parent header, then its child preview. Both must select the matching list node.
        canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 16)).click()
        expectLabel("Library", id: "storage.selection", in: window)
        canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 65)).click()
        expectLabel("Developer", id: "storage.selection", in: window)
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "storage.row.node-2").firstMatch.exists)
        attach(window, "revamp-map-nested-selection")
        sunburst(in: window)
        expectLabel("Developer", id: "storage.selection", in: window)
        window.buttons["storage.open"].click()
        expectLabel("Developer", id: "storage.folder", in: window)
        window.buttons["storage.up"].click()
        expectLabel("Library", id: "storage.folder", in: window)
        let small = window.descendants(matching: .any).matching(identifier: "storage.row.small-1").firstMatch
        XCTAssertTrue(small.waitForExistence(timeout: 5))
        small.click()
        expectLabel("Small files", id: "storage.selection", in: window)
        window.descendants(matching: .any).matching(identifier: "storage.actions").firstMatch.click()
        XCTAssertTrue(app.menuItems["Reveal containing folder"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Quick Look"].exists)
        XCTAssertFalse(app.menuItems["Move to Trash…"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.menuItems["Reveal containing folder"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        attach(window, "revamp-map-small-files")
        // Open a second-level directory with Return, then navigate back with Escape.
        window.descendants(matching: .any).matching(identifier: "storage.row.node-2").firstMatch.click()
        expectLabel("Developer", id: "storage.selection", in: window)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        expectLabel("Developer", id: "storage.folder", in: window)
        window.descendants(matching: .any).matching(identifier: "storage.row.node-3").firstMatch.click()
        expectLabel("Xcode Archives", id: "storage.selection", in: window)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        expectLabel("Library", id: "storage.folder", in: window)
        app.terminate()
    }
}
