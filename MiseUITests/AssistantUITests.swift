import XCTest

/// M7: Settings shows the active assistant and why; the force-rules toggle switches to rules;
/// the model path runs end to end when the simulator exposes the model.
final class AssistantUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func activeAssistant(_ app: XCUIApplication) -> String {
        app.tabBars.buttons["Settings"].tap()
        let row = app.descendants(matching: .any)["settings.activeAssistant"]
        app.scrollTo(row)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row.label + " " + ((row.value as? String) ?? "")
    }

    @MainActor
    func testSettingsShowsAssistantAndForceRulesToggle() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, forceRules: false)
        app.completeOnboarding()
        let active = activeAssistant(app)
        let status = app.descendants(matching: .any)["settings.assistantStatus"]
        app.scrollTo(status)
        print("MISE-LOG active assistant: \(active) | status: \(status.label)")
        XCTAssertFalse(status.label.isEmpty)

        let toggle = app.switches["settings.forceRules"]
        app.scrollTo(toggle)
        if (toggle.value as? String) == "0" { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        let row = app.descendants(matching: .any)["settings.activeAssistant"]
        XCTAssertTrue(row.label.contains("Built-in rules") || (row.value as? String ?? "").contains("Built-in rules"))
        XCTAssertTrue(app.descendants(matching: .any)["settings.assistantStatus"].label.contains("chosen the built-in rules"))
    }

    @MainActor
    func testModelPathWhenAvailable() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, forceRules: false, environment: StubPages.environment())
        app.completeOnboarding(pantryPicks: ["shaoxing-wine"])
        let active = activeAssistant(app)
        guard active.contains("Apple Intelligence") else {
            throw XCTSkip("On-device model not available in this simulator: \(active)")
        }
        app.tabBars.buttons["Recipes"].tap()
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 30))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        app.buttons["detail.madeThis"].tap()
        let text = app.textViews["adjust.text"].exists ? app.textViews["adjust.text"] : app.textFields["adjust.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("it was a bit flat, so I finished it with lime and more oyster sauce")
        app.buttons["adjust.suggest"].tap()
        let proposals = app.descendants(matching: .any)["adjust.proposals"]
        XCTAssertTrue(proposals.waitForExistence(timeout: 90))
        let toggles = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'adjust.edit.'"))
        let labels = (0..<toggles.count).map { toggles.element(boundBy: $0).label }
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Untick anything'")).firstMatch
        print("MISE-LOG model proposals (\(footer.exists ? footer.label : "no footer")): \(labels)")
        XCTAssertGreaterThan(labels.count, 0)
    }
}
