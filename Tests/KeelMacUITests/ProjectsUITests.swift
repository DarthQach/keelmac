import XCTest

/// Projects with synthetic data: never runs git or gh, never moves anything.
final class ProjectsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(theme: String = "light", language: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-visual-fixtures", "-appearance", theme, "-fixture-size", "1180x780",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "es" ? "es_MX" : "en_US",
                               "-fixture-route", "projects"] + extra
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testProjectsScreen() {
        for (theme, language) in [("light", "en"), ("dark", "es")] {
            let app = launch(theme: theme, language: language)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.staticTexts["weather-widget"].firstMatch.waitForExistence(timeout: 5))
            attach(window, "projects-\(theme)-\(language)")
            window.staticTexts["game-prototype"].firstMatch.click()
            Thread.sleep(forTimeInterval: 0.3)
            attach(window, "projects-selected-\(theme)-\(language)")
            app.terminate()
        }
    }

    @MainActor
    func testTrashNeedsVerifiedSelection() {
        let app = launch()
        let window = app.windows.firstMatch
        let trash = window.buttons["projects.trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertFalse(trash.isEnabled)
        window.buttons["Select all safe"].click()
        XCTAssertTrue(trash.isEnabled)
        XCTAssertEqual(trash.label, "Move 2 projects to Trash")
        trash.click()
        let confirm = app.buttons["projects.trash.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.label.hasPrefix("Move ") && confirm.label.hasSuffix(" to Trash"))
        attach(window, "projects-trash-sheet")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["weather-widget"].exists)   // nothing was removed
        app.terminate()
    }

    @MainActor
    func testBackupSheetListsCommands() {
        for (theme, language) in [("light", "en"), ("dark", "es")] {
            let app = launch(theme: theme, language: language, extra: ["-fixture-projects-sheet", "backup"])
            let run = app.buttons["projects.backup.run"]
            XCTAssertTrue(run.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'repo create'")).firstMatch.exists)
            attach(app.windows.firstMatch, "projects-backup-sheet-\(theme)-\(language)")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            app.terminate()
        }
    }

    @MainActor
    func testBulkBackupSheetListsProjects() {
        for (theme, language) in [("light", "en"), ("dark", "es")] {
            let app = launch(theme: theme, language: language, extra: ["-fixture-projects-sheet", "bulkBackup"])
            let sheet = app.sheets.firstMatch
            let run = sheet.buttons["projects.backup.bulk.run"]
            XCTAssertTrue(run.waitForExistence(timeout: 5))
            XCTAssertTrue(run.isEnabled)
            if language == "en" { XCTAssertEqual(run.label, "Back up 4 projects") }
            XCTAssertTrue(sheet.staticTexts["invoice-scripts"].exists)
            let commands = sheet.buttons.matching(identifier: "projects.backup.bulk.commands")
            XCTAssertEqual(commands.count, 4)   // one Commands toggle per project
            attach(app.windows.firstMatch, "projects-bulk-backup-sheet-\(theme)-\(language)")
            // The first row (game-prototype) pushes to its existing repository; its commands are one click away.
            commands.firstMatch.click()
            XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'push --all'")).firstMatch.waitForExistence(timeout: 3))
            attach(app.windows.firstMatch, "projects-bulk-backup-commands-\(theme)-\(language)")
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            app.terminate()
        }
    }

    @MainActor
    func testNotBackedUpFilterBacksUpTheSelection() {
        let app = launch()
        let window = app.windows.firstMatch
        let segment = window.radioButtons.matching(NSPredicate(format: "label BEGINSWITH 'Not backed up'")).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        segment.click()
        let backUp = window.buttons["projects.backup"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 5))
        XCTAssertFalse(backUp.isEnabled)
        window.buttons["Select all"].click()
        XCTAssertTrue(backUp.isEnabled)
        XCTAssertEqual(backUp.label, "Back up 2 projects…")
        attach(window, "projects-not-backed-up-selected")
        backUp.click()
        XCTAssertTrue(app.sheets.firstMatch.buttons["projects.backup.bulk.run"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.terminate()
    }

    @MainActor
    func testStates() {
        for state in ["empty", "loading", "error", "unavailable"] {
            let app = launch(extra: ["-fixture-state", state])
            Thread.sleep(forTimeInterval: 0.3)
            attach(app.windows.firstMatch, "projects-state-\(state)")
            app.terminate()
        }
    }
}
