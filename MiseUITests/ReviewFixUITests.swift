import XCTest

/// Regression tests for the code-review findings that live in the app target.
final class ReviewFixUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// #7: an ingredient listed twice is asked about once; answering updates both cards.
    /// Also: the "Leave it out" row doesn't repeat its title as the note.
    @MainActor
    func testDuplicateIngredientAskedOnce() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()
        app.importRecipe(url: StubPages.twiceWine)
        XCTAssertTrue(app.staticTexts["review.summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["review.shaoxing-wine.no"].exists)
        XCTAssertTrue(app.buttons["review.shaoxing-wine-2.no"].exists, "unique identifiers per card")
        app.buttons["review.shaoxing-wine.no"].tap()

        // Both cards now show swaps and neither asks again.
        XCTAssertTrue(app.buttons["swap.shaoxing-wine.dry-sherry"].waitForExistence(timeout: 5))
        let second = app.buttons["swap.shaoxing-wine-2.dry-sherry"]
        app.scrollTo(second)
        XCTAssertTrue(second.exists)
        XCTAssertFalse(app.buttons["review.shaoxing-wine.no"].exists)
        XCTAssertFalse(app.buttons["review.shaoxing-wine-2.no"].exists)
        XCTAssertFalse(app.staticTexts["Do you have Shaoxing wine?"].exists)

        let leave = app.buttons["swap.shaoxing-wine-2.leave-out"]
        app.scrollTo(leave)
        XCTAssertEqual(leave.label, "Leave it out")
    }

    /// #10: a shared URL survives the app being killed while its import sheet is open,
    /// and is removed once the sheet is closed.
    @MainActor
    func testSharedURLSurvivesKillMidSheet() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, extra: ["-enqueueImport", StubPages.chowMein], environment: StubPages.environment())
        app.completeOnboarding()
        XCTAssertTrue(app.textFields["import.url"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchForTesting(reset: false, environment: StubPages.environment())
        let field = app.textFields["import.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "sheet shown again after relaunch")
        XCTAssertEqual(field.value as? String, StubPages.chowMein)
        app.buttons["Cancel"].tap()

        app.terminate()
        app.launchForTesting(reset: false, environment: StubPages.environment())
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["import.url"].waitForExistence(timeout: 3), "removed once the sheet closed")
    }

    /// #11: deselecting a thumb clears the saved rating.
    @MainActor
    func testRatingCanBeCleared() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding(pantryPicks: ["shaoxing-wine"])
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))

        app.buttons["detail.madeThis"].tap()
        XCTAssertTrue(app.buttons["adjust.thumbsDown"].waitForExistence(timeout: 5))
        app.buttons["adjust.thumbsDown"].tap()
        app.buttons["adjust.save"].tap()
        XCTAssertTrue(app.images["Disliked"].waitForExistence(timeout: 5))

        app.buttons["detail.madeThis"].tap()
        XCTAssertTrue(app.buttons["adjust.thumbsDown"].waitForExistence(timeout: 5))
        app.buttons["adjust.thumbsDown"].tap()  // deselect
        app.buttons["adjust.save"].tap()
        XCTAssertTrue(app.staticTexts["Cooked 2×"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["Disliked"].exists)
    }

    /// #5: a typed pantry item isn't collapsed onto a shorter catalog name.
    @MainActor
    func testPantryKeepsUnknownCompoundName() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true)
        app.completeOnboarding()
        app.tabBars.buttons["Pantry"].tap()
        let field = app.textFields["pantry.addField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("almond butter\n")
        field.tap()
        field.typeText("soy milk\n")
        XCTAssertTrue(app.descendants(matching: .any)["pantry.row.almond butter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pantry.row.soy-milk"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pantry.row.butter"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pantry.row.milk"].exists)
    }
}
