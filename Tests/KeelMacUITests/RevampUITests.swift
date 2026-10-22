import XCTest

/// Every screen uses synthetic data; these tests never scan the Mac or execute a removal.
final class RevampUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(theme: String = "light", language: String = "en", size: String = "1180x780", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-visual-fixtures", "-appearance", theme, "-fixture-size", size,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "es" ? "es_MX" : "en_US",
                               "-mapHighlight", "none"] + extra
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testAllScreensLightEnglish() { captureRoutes(theme: "light", language: "en") }
    @MainActor
    func testAllScreensDarkEnglish() { captureRoutes(theme: "dark", language: "en") }
    @MainActor
    func testAllScreensLightSpanish() { captureRoutes(theme: "light", language: "es") }
    @MainActor
    func testAllScreensDarkSpanish() { captureRoutes(theme: "dark", language: "es") }

    @MainActor
    private func captureRoutes(theme: String, language: String) {
        let app = launch(theme: theme, language: language)
        let window = app.windows.firstMatch
        for route in ["dashboard", "monitor", "cleanup", "apps", "storageMap", "largeOld", "systemData", "duplicates", "snapshots", "leftovers", "loginItems", "maintenance", "operationLog"] {
            let item = window.outlines.cells.containing(.any, identifier: "sidebar.\(route)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), route)
            item.click()
            if route == "cleanup" {
                let rule = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cleanup.disclosure.'")).firstMatch
                XCTAssertTrue(rule.waitForExistence(timeout: 5))
                rule.click()
            }
            if route == "apps" { window.staticTexts["Affinity Photo"].firstMatch.click() }
            Thread.sleep(forTimeInterval: 0.35)
            attach(window, "revamp-\(route)-\(theme)-\(language)")
        }
        app.terminate()
    }

    @MainActor
    func testRepresentativeSizes() {
        for (theme, language) in [("light", "en"), ("dark", "es")] {
          for size in ["960x640", "1600x1000"] {
            let app = launch(theme: theme, language: language, size: size)
            let window = app.windows.firstMatch
            for route in ["dashboard", "cleanup", "apps", "monitor"] {
                window.outlines.cells.containing(.any, identifier: "sidebar.\(route)").firstMatch.click()
                if route == "apps" { window.staticTexts["Affinity Photo"].firstMatch.click() }
                Thread.sleep(forTimeInterval: 0.3)
                attach(window, "revamp-\(route)-\(size)-\(theme)-\(language)")
            }
            app.terminate()
          }
        }
    }

    @MainActor
    func testSecondarySurfaces() {
        for theme in ["light", "dark"] {
            for language in ["en", "es"] {
              for surface in ["settings", "welcome", "about", "menuBar", "uninstall", "result"] {
                let app = launch(theme: theme, language: language, extra: ["-fixture-surface", surface])
                Thread.sleep(forTimeInterval: 0.3)
                attach(app.windows.firstMatch, "revamp-\(surface)-\(theme)-\(language)")
                if surface == "settings" {
                    let tabs = [("menuBar", "Menu bar", "Barra de menús"), ("alerts", "Alerts", "Alertas"), ("cleanup", "Cleanup and safety", "Limpieza y seguridad"), ("helper", "Helper", "Asistente"), ("updates", "Updates", "Actualizaciones")]
                    for (tab, english, spanish) in tabs {
                        app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", language == "es" ? spanish : english)).firstMatch.click()
                        attach(app.windows.firstMatch, "revamp-settings-\(tab)-\(theme)-\(language)")
                    }
                }
                app.terminate()
              }
            }
        }
    }

    @MainActor
    func testPresentationStates() {
        for (route, state) in [("storageMap", "empty"), ("cleanup", "empty"), ("cleanup", "loading"), ("cleanup", "error"), ("dashboard", "permission"), ("monitor", "unavailable"), ("apps", "empty"), ("apps", "loading"), ("snapshots", "empty"), ("snapshots", "error"), ("duplicates", "empty"), ("leftovers", "empty"), ("loginItems", "empty")] {
            let app = launch(extra: ["-fixture-route", route, "-fixture-state", state])
            Thread.sleep(forTimeInterval: 0.3)
            attach(app.windows.firstMatch, "revamp-\(route)-\(state)")
            app.terminate()
        }
    }

    @MainActor
    func testSelectionAndSafetyPreview() {
        let app = launch(extra: ["-fixture-route", "cleanup"])
        let window = app.windows.firstMatch
        let rule = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cleanup.disclosure.'")).firstMatch
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
        rule.click()
        let check = window.checkBoxes.firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        let oldValue = (check.value as? NSNumber)?.boolValue
        XCTAssertNotNil(oldValue)
        check.click()
        XCTAssertNotEqual((check.value as? NSNumber)?.boolValue, oldValue)
        let remove = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move ' AND label ENDSWITH 'to Trash'")).firstMatch
        XCTAssertTrue(remove.exists)
        remove.click()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        attach(window, "revamp-cleanup-confirmation")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(remove.isEnabled)
        app.terminate()
    }
    @MainActor
    func testKeyboardNavigationAndAppPreview() {
        let app = launch()
        let window = app.windows.firstMatch
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(window.staticTexts["Top processes"].waitForExistence(timeout: 5))
        app.typeKey("8", modifierFlags: .command)
        XCTAssertTrue(window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move ' AND label ENDSWITH 'to Trash'")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("9", modifierFlags: .command)
        window.staticTexts["Affinity Photo"].firstMatch.click()
        window.buttons["Uninstall…"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        attach(window, "revamp-apps-uninstall-sheet")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(window.buttons["Uninstall…"].isEnabled)
        app.typeKey("3", modifierFlags: .command)
        window.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sunburst'")).firstMatch.click()
        attach(window, "revamp-storageMap-sunburst")
        app.terminate()
    }

}
