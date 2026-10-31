import XCTest

/// M5: import → asked once → No → pick sherry → saved recipe shows sherry;
/// a second Shaoxing recipe shows swaps directly without asking.
final class ImportUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testShaoxingAskedOnceThenRemembered() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()

        // First recipe: asked about Shaoxing wine.
        app.importRecipe(url: StubPages.porkBelly)
        let card = app.descendants(matching: .any)["review.shaoxing-wine"]
        XCTAssertTrue(app.staticTexts["review.summary"].waitForExistence(timeout: 10))
        app.scrollTo(card)
        XCTAssertTrue(app.staticTexts["Do you have Shaoxing wine?"].exists)
        XCTAssertTrue(app.staticTexts["review.disclaimer"].exists || app.descendants(matching: .any)["review.disclaimer"].exists)
        let no = app.buttons["review.shaoxing-wine.no"]
        app.scrollTo(no)
        no.tap()

        // Swaps revealed; pick dry sherry.
        let sherry = app.buttons["swap.shaoxing-wine.dry-sherry"]
        XCTAssertTrue(sherry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["swap.shaoxing-wine.keep"].exists, "Keep original is always offered")
        app.scrollTo(sherry)
        sherry.tap()
        app.buttons["review.save"].tap()

        // Detail shows sherry in ingredients and steps.
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        let sherryIngredient = app.descendants(matching: .any).matching(identifier: "detail.ingredient")
            .matching(NSPredicate(format: "label CONTAINS[c] 'dry sherry'")).firstMatch
        app.scrollTo(sherryIngredient)
        XCTAssertTrue(sherryIngredient.exists)
        let sherryStep = app.descendants(matching: .any).matching(identifier: "detail.step")
            .matching(NSPredicate(format: "label CONTAINS 'add the dry sherry'")).firstMatch
        app.scrollTo(sherryStep)
        XCTAssertTrue(sherryStep.exists, "step text rewritten to sherry")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "detail.step")
            .matching(NSPredicate(format: "label CONTAINS[c] 'shaoxing'")).firstMatch.exists)
        let revision = app.descendants(matching: .any).matching(identifier: "detail.revision")
            .matching(NSPredicate(format: "label CONTAINS 'Swapped Shaoxing wine for dry sherry'")).firstMatch
        app.scrollTo(revision)
        XCTAssertTrue(revision.exists, "swap recorded as revision 1")

        // Back to the list; the second recipe uses "Chinese cooking wine" (same catalog entry).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.staticTexts["review.summary"].waitForExistence(timeout: 10))
        let wineCard = app.descendants(matching: .any)["review.shaoxing-wine"]
        app.scrollTo(wineCard)
        XCTAssertTrue(wineCard.exists)
        XCTAssertFalse(app.buttons["review.shaoxing-wine.no"].exists, "no second question")
        XCTAssertFalse(app.staticTexts["Do you have Chinese cooking wine?"].exists)
        XCTAssertTrue(app.staticTexts["Not in your pantry"].exists)
        XCTAssertTrue(app.buttons["swap.shaoxing-wine.dry-sherry"].exists, "swaps shown directly")
    }

    @MainActor
    func testParseFailureShowsError() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()
        app.importRecipe(url: StubPages.notARecipe)
        let error = app.descendants(matching: .any)["import.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("Couldn't find a recipe"))
    }
}
