import XCTest

/// Cook mode end to end on the stubbed chow mein: Start cooking → prep list → steps with
/// "For this step" and a timer chip → a running timer in the bar → Done opens "I made this".
final class CookModeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCookModeFromPrepListToIMadeThis() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding(pantryPicks: ["shaoxing-wine"])
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))

        // Double the servings (2 → 4): cook mode shows scaled amounts.
        let stepper = app.steppers["detail.servings"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons.element(boundBy: 1).tap()
        stepper.buttons.element(boundBy: 1).tap()

        app.buttons["detail.startCooking"].tap()

        // The prep list comes first.
        XCTAssertTrue(app.descendants(matching: .any)["cook.prep"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["cook.pageTitle"].label, "Mise en place")
        let items = app.buttons.matching(identifier: "cook.prep.item")
        XCTAssertGreaterThan(items.count, 5)
        let chicken = items.matching(NSPredicate(format: "label CONTAINS 'Thinly slice 400 g chicken'")).firstMatch
        XCTAssertTrue(chicken.exists, "the prep list uses the doubled amount")
        chicken.tap()
        XCTAssertTrue(chicken.isSelected, "ticked")

        // Step 1, then on to step 3 (marinate for 10 minutes).
        app.buttons["cook.next"].tap()
        XCTAssertTrue(app.staticTexts["cook.pageTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cook.pageTitle"].label, "Step 1 of 11")
        XCTAssertTrue(app.descendants(matching: .any)["cook.forThisStep"].waitForExistence(timeout: 5))
        app.buttons["cook.next"].tap()
        app.buttons["cook.next"].tap()
        XCTAssertEqual(app.staticTexts["cook.pageTitle"].label, "Step 3 of 11")
        let forThisStep = app.descendants(matching: .any)["cook.forThisStep"]
        XCTAssertTrue(forThisStep.waitForExistence(timeout: 5))
        let ingredient = forThisStep.descendants(matching: .any).matching(identifier: "cook.ingredient").firstMatch
        XCTAssertTrue(ingredient.label.contains("400 g"), ingredient.label)
        XCTAssertTrue(ingredient.label.contains("Chicken breast"), ingredient.label)

        let chip = app.buttons["cook.timer.0"]
        XCTAssertTrue(chip.exists)
        XCTAssertEqual(chip.label, "Start 10 min timer")
        chip.tap()

        // First timer: iOS asks for notification permission. Allow it if asked.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }

        XCTAssertTrue(app.buttons["cook.timer.0"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["cook.timer.0"].label, "Stop 10 min timer")
        // The step's own row shows it, so the strip stays hidden on this page...
        let bar = app.descendants(matching: .any)["cook.timerBar"]
        XCTAssertFalse(bar.exists)

        // ...and appears once you move on.
        app.buttons["cook.next"].tap()
        XCTAssertEqual(app.staticTexts["cook.pageTitle"].label, "Step 4 of 11")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))

        // On to the last step; Done (with a timer running, after confirming) opens "I made this".
        var taps = 0
        while !app.buttons["cook.done"].exists && taps < 12 {
            app.buttons["cook.next"].tap()
            taps += 1
        }
        XCTAssertEqual(app.staticTexts["cook.pageTitle"].label, "Step 11 of 11")
        app.buttons["cook.done"].tap()
        // The dialog's button may not carry its identifier (its label is "Finish"), and when it
        // does, more than one element matches it, so take the first.
        let byID = app.buttons.matching(identifier: "cook.confirmExit").firstMatch
        let confirm = byID.waitForExistence(timeout: 5) ? byID : app.buttons["Finish"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.buttons["adjust.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["I made this"].exists)
    }
}
