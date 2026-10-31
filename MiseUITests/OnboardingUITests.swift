import XCTest

/// M4: fresh install shows onboarding, relaunch skips it, Settings edits every preference.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingGateRelaunchAndSettings() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true)

        // Fresh install: onboarding.
        XCTAssertTrue(app.staticTexts["What do you eat?"].waitForExistence(timeout: 15))
        app.buttons["avoid.alcohol"].tap()
        app.buttons["onboarding.next"].tap()

        XCTAssertTrue(app.staticTexts["Anything you'd rather skip?"].waitForExistence(timeout: 5))
        let dislike = app.textFields["prefs.dislikeField"]
        dislike.tap()
        dislike.typeText("olives\n")
        XCTAssertTrue(app.staticTexts["olives"].waitForExistence(timeout: 5))
        app.buttons["onboarding.next"].tap()

        XCTAssertTrue(app.staticTexts["How do you cook?"].waitForExistence(timeout: 5))
        app.buttons["cuisine.Chinese"].tap()
        app.buttons["onboarding.next"].tap()

        XCTAssertTrue(app.staticTexts["What's in your pantry?"].waitForExistence(timeout: 5))
        app.buttons["pantry.pick.soy-sauce"].tap()
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))

        // Relaunch without resetting: onboarding is skipped.
        app.terminate()
        app.launchForTesting(reset: false)
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["What do you eat?"].exists)

        // Pantry pick was saved.
        app.tabBars.buttons["Pantry"].tap()
        let soy = app.descendants(matching: .any)["pantry.row.soy-sauce"]
        XCTAssertTrue(soy.waitForExistence(timeout: 5))
        XCTAssertEqual(soy.value as? String, "Have")

        // Settings shows the onboarding answers and can change every preference.
        app.tabBars.buttons["Settings"].tap()
        let alcohol = app.buttons["avoid.alcohol"]
        XCTAssertTrue(alcohol.waitForExistence(timeout: 5))
        XCTAssertEqual(alcohol.value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["olives"].exists)

        let list = app.collectionViews.firstMatch
        func tap(_ id: String) {
            let el = app.buttons[id]
            el.scrollIntoView(in: list)
            el.tap()
        }
        tap("diet.vegetarian")
        tap("avoid.gluten")
        let field = app.textFields["prefs.dislikeField"]
        field.scrollIntoView(in: list)
        field.tap()
        field.typeText("mushrooms\n")
        tap("spice.4")
        tap("cuisine.Thai")
        tap("weeknight.45")
        let stepper = app.steppers["prefs.servings"]
        stepper.scrollIntoView(in: list)
        stepper.buttons.element(boundBy: 1).tap()

        // Relaunch and confirm the changes persisted.
        app.terminate()
        app.launchForTesting(reset: false)
        app.tabBars.buttons["Settings"].tap()
        let list2 = app.collectionViews.firstMatch
        func value(_ id: String) -> String? {
            let el = app.buttons[id]
            el.scrollIntoView(in: list2)
            return el.value as? String
        }
        XCTAssertTrue(app.buttons["diet.vegetarian"].waitForExistence(timeout: 10))
        XCTAssertEqual(value("diet.vegetarian"), "Selected")
        XCTAssertEqual(value("diet.omnivore"), "Not selected")
        XCTAssertEqual(value("avoid.gluten"), "Selected")
        XCTAssertTrue(app.staticTexts["mushrooms"].exists)
        XCTAssertEqual(value("spice.4"), "Selected")
        XCTAssertEqual(value("cuisine.Thai"), "Selected")
        XCTAssertEqual(value("weeknight.45"), "Selected")
        let servings = app.staticTexts["prefs.servingsValue"]
        servings.scrollIntoView(in: list2)
        XCTAssertEqual(servings.label, "3")
    }
}
