import XCTest

/// The Assistant panel in every state, with the fixture backend (no Ollama, no network).
final class AssistantUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(theme: String, language: String, state: String, route: String = "largeOld") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-visual-fixtures", "-appearance", theme, "-fixture-size", "1180x780",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "es" ? "es_MX" : "en_US",
                               "-mapHighlight", "none", "-fixture-route", route, "-fixture-assistant", state]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testStatesLightEnglish() { captureStates(theme: "light", language: "en") }
    @MainActor
    func testStatesDarkSpanish() { captureStates(theme: "dark", language: "es") }

    @MainActor
    private func captureStates(theme: String, language: String) {
        for state in ["ready", "empty", "disabled", "unreachable", "noModel", "error"] {
            let app = launch(theme: theme, language: language, state: state)
            let window = app.windows.firstMatch
            let title = window.descendants(matching: .any)["assistant.title"].firstMatch
            let present = title.waitForExistence(timeout: 5)
            Thread.sleep(forTimeInterval: 0.4)
            attach(window, "assistant-\(state)-\(theme)-\(language)")
            XCTAssertTrue(present, state)
            app.terminate()
        }
    }

    @MainActor
    func testAskAndToggle() {
        let app = launch(theme: "light", language: "en", state: "empty", route: "dashboard")
        let window = app.windows.firstMatch
        let input = window.descendants(matching: .any)["assistant.input"].firstMatch
        let present = input.waitForExistence(timeout: 5)
        attach(window, "assistant-empty-before-ask")
        XCTAssertTrue(present)
        input.click()
        input.typeText("How is my Mac doing?")
        window.descendants(matching: .any)["assistant.send"].firstMatch.click()
        let answer = window.staticTexts.containing(NSPredicate(format: "value CONTAINS 'good shape' OR label CONTAINS 'good shape'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.3)
        attach(window, "assistant-asked-light-en")
        window.descendants(matching: .any)["assistant.toggle"].firstMatch.click()
        XCTAssertTrue(waitForDisappearance(of: input, timeout: 5))
        attach(window, "assistant-hidden-light-en")
        app.terminate()
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !element.exists
    }
}
