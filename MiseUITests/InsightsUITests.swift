import XCTest

/// Cuisine guess and realistic time estimate, end to end with the stubbed fetcher (rules path).
final class InsightsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Wikibooks Kung Pao has no cuisine and no stated time: the guess shows "Chinese" and the
    /// estimate becomes the displayed time. The guess can be changed, which is recorded.
    @MainActor
    func testKungPaoGetsGuessedCuisineAndEstimate() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()

        app.importRecipe(url: StubPages.kungPao)
        XCTAssertTrue(app.staticTexts["review.summary"].waitForExistence(timeout: 15))
        app.buttons["review.save"].tap()

        // Detail: guessed cuisine (shown like any other) and an estimated time.
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        let cuisine = app.descendants(matching: .any)["detail.cuisine"]
        XCTAssertTrue(cuisine.waitForExistence(timeout: 5))
        XCTAssertEqual(cuisine.label, "Cuisine: Chinese")

        let time = app.descendants(matching: .any)["detail.time"]
        XCTAssertTrue(time.exists)
        XCTAssertTrue(time.label.contains("estimated"), time.label)

        let estimate = app.descendants(matching: .any)["detail.timeEstimate"]
        XCTAssertTrue(estimate.exists)
        XCTAssertTrue(estimate.label.hasPrefix("Estimated ~"), estimate.label)
        XCTAssertTrue(estimate.label.contains("marinating"), estimate.label)
        estimate.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.timeReason"].waitForExistence(timeout: 3))
        // Default weeknight time (30 min) is shorter than the estimate.
        XCTAssertTrue(app.descendants(matching: .any)["detail.weeknightHint"].exists)

        // The list card shows the estimate with "~" and the cuisine without a guess marker.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let card = app.descendants(matching: .any).matching(identifier: "recipe.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Chinese"), card.label)
        XCTAssertFalse(card.label.contains("guess"), card.label)
        XCTAssertTrue(card.label.contains("~"), card.label)

        // Change the guess: it becomes the user's cuisine and is recorded in history.
        card.tap()
        XCTAssertTrue(cuisine.waitForExistence(timeout: 5))
        cuisine.tap()
        let korean = app.buttons["Korean"]
        XCTAssertTrue(korean.waitForExistence(timeout: 3))
        korean.tap()
        let picked = app.descendants(matching: .any)["detail.cuisine"]
        XCTAssertTrue(picked.waitForExistence(timeout: 3))
        XCTAssertEqual(picked.label, "Cuisine: Korean")
        let revision = app.descendants(matching: .any).matching(identifier: "detail.revision")
            .matching(NSPredicate(format: "label CONTAINS 'Cuisine set to Korean'")).firstMatch
        app.scrollTo(revision)
        XCTAssertTrue(revision.exists)
    }

    /// Chow mein says 15 min but marinates for 10 and has 15 ingredients: both times are shown,
    /// and the page's own cuisine is not marked as a guess. Re-check keeps the result.
    @MainActor
    func testChowMeinShowsRealisticTimeBesideStatedTime() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()

        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.staticTexts["review.summary"].waitForExistence(timeout: 15))
        app.buttons["review.save"].tap()

        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        let time = app.descendants(matching: .any)["detail.time"]
        XCTAssertEqual(time.label, "15 min", "stated time is kept")
        let cuisine = app.descendants(matching: .any)["detail.cuisine"]
        XCTAssertEqual(cuisine.label, "Cuisine: Chinese", "page cuisine, editable like a guess")

        let estimate = app.descendants(matching: .any)["detail.timeEstimate"]
        XCTAssertTrue(estimate.exists)
        XCTAssertTrue(estimate.label.contains("Realistically ~30 min"), estimate.label)
        XCTAssertTrue(estimate.label.contains("marinating"), estimate.label)
        XCTAssertTrue(estimate.label.contains("recipe says 15 min"), estimate.label)

        app.buttons["detail.menu"].tap()
        let recheck = app.buttons["Re-check time and cuisine"]
        XCTAssertTrue(recheck.waitForExistence(timeout: 3))
        recheck.tap()
        XCTAssertTrue(estimate.waitForExistence(timeout: 15))
        XCTAssertTrue(estimate.label.contains("recipe says 15 min"), estimate.label)
        XCTAssertEqual(app.descendants(matching: .any)["detail.cuisine"].label, "Cuisine: Chinese")
    }
}
