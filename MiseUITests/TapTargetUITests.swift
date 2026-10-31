import XCTest

/// A fill-scaled photo overflows its card's image frame. Tapping a card's title must open that
/// card, not the one below whose (clipped but still hit-testable) photo overflowed over it.
final class TapTargetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTappingCardTitleOpensThatRecipe() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()

        for url in [StubPages.tallPhotoA, StubPages.tallPhotoB] {
            app.importRecipe(url: url)
            let save = app.buttons["review.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            save.tap()
            XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Newest first: "Tall Photo Two" is on top, "Tall Photo One" below it.
        let cards = app.buttons.matching(identifier: "recipe.card")
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 10))
        for (index, title) in ["Tall Photo Two", "Tall Photo One"].enumerated() {
            let card = cards.element(boundBy: index)
            app.scrollTo(card)
            // The title sits in the card's lower part, just under the image frame.
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.88)).tap()
            let detailTitle = app.staticTexts["detail.title"]
            XCTAssertTrue(detailTitle.waitForExistence(timeout: 10))
            XCTAssertEqual(detailTitle.label, title, "tapping the title of card \(index) opened the wrong recipe")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}
