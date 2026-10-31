import XCTest

/// "What can I cook?" on the Recipes tab, rules path (stubbed pages, `-forceRules`).
final class WhatCanICookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func save(_ app: XCUIApplication, url: String) {
        app.importRecipe(url: url)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 15))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Two recipes saved; a dictation-style question finds the noodle one with a "why" line,
    /// tapping it opens the recipe, and an impossible limit shows close matches.
    @MainActor
    func testAskFindsRecipeAndRelaxesWhenNothingFits() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()
        save(app, url: StubPages.chowMein)
        save(app, url: StubPages.porkBelly)

        let field = app.textViews["cook.ask.field"].exists ? app.textViews["cook.ask.field"] : app.textFields["cook.ask.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("i want noodles with chicken no pork")
        app.buttons["cook.ask.submit"].tap()

        let understood = app.descendants(matching: .any)["cook.understood"]
        XCTAssertTrue(understood.waitForExistence(timeout: 5))
        XCTAssertTrue(understood.label.contains("no pork"), understood.label)
        let result = app.descendants(matching: .any).matching(identifier: "cook.result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Chow Mein"), result.label)
        XCTAssertTrue(result.label.contains("Uses chicken"), result.label)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cook.result")
            .matching(NSPredicate(format: "label CONTAINS 'Pork Belly'")).firstMatch.exists)

        result.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Nothing is ready in 5 minutes: close matches with what was relaxed.
        app.buttons["cook.ask.clear"].tap()
        field.tap()
        field.typeText("something in 5 minutes")
        app.buttons["cook.ask.submit"].tap()
        let relaxed = app.descendants(matching: .any)["cook.relaxed"]
        XCTAssertTrue(relaxed.waitForExistence(timeout: 5))
        XCTAssertTrue(relaxed.label.contains("under 5 min"), relaxed.label)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cook.close").firstMatch.exists)

        // Clearing brings back the full list.
        app.buttons["cook.ask.clear"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recipe.card").firstMatch.waitForExistence(timeout: 5))
    }
}
