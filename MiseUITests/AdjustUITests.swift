import XCTest

/// M6: the mixed feedback sentence gives 3 proposed edits; unticking one leaves it out;
/// history shows the revision.
final class AdjustUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMixedFeedbackProposesThreeEditsAndUntickedOneIsSkipped() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        // Have the wine already, so the chow mein check needs no answers.
        app.completeOnboarding(pantryPicks: ["shaoxing-wine"])
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))

        app.buttons["detail.madeThis"].tap()
        let text = app.textViews["adjust.text"].exists ? app.textViews["adjust.text"] : app.textFields["adjust.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Used chicken thighs instead of breast and it was too salty, needed 10 more minutes")
        app.buttons["adjust.thumbsUp"].tap()
        app.buttons["adjust.suggest"].tap()

        let toggles = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'adjust.edit.'"))
        XCTAssertTrue(app.switches["adjust.edit.0"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggles.count, 3)
        XCTAssertTrue(app.switches["adjust.edit.0"].label.contains("Swapped chicken breast"))
        XCTAssertTrue(app.switches["adjust.edit.1"].label.contains("Less soy sauce"))
        XCTAssertTrue(app.switches["adjust.edit.2"].label.contains("Needed about 10 more minutes"))

        // Untick the soy sauce change.
        let soy = app.switches["adjust.edit.1"]
        app.scrollTo(soy)
        soy.switches.firstMatch.exists ? soy.switches.firstMatch.tap() : soy.tap()
        XCTAssertEqual(soy.value as? String, "0")
        app.buttons["adjust.save"].tap()

        // History shows the revision with the two kept edits and not the unticked one.
        let revision = app.descendants(matching: .any).matching(identifier: "detail.revision")
            .matching(NSPredicate(format: "label CONTAINS 'Cooked it'")).firstMatch
        app.scrollTo(revision)
        XCTAssertTrue(revision.waitForExistence(timeout: 5))
        XCTAssertTrue(revision.label.contains("Swapped chicken breast or thigh fillets for chicken thighs"))
        XCTAssertTrue(revision.label.contains("Needed about 10 more minutes"))
        XCTAssertFalse(revision.label.contains("soy sauce"))

        // The recipe itself changed: thighs in, a note added, soy sauce untouched.
        let note = app.descendants(matching: .any).matching(identifier: "detail.note").firstMatch
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("Needed about 10 more minutes than written"))
        app.swipeDown()
        let thighs = app.descendants(matching: .any).matching(identifier: "detail.ingredient")
            .matching(NSPredicate(format: "label CONTAINS 'Chicken thighs'")).firstMatch
        XCTAssertTrue(thighs.exists)
        let soyRow = app.descendants(matching: .any).matching(identifier: "detail.ingredient")
            .matching(NSPredicate(format: "label CONTAINS 'Soy sauce'")).firstMatch
        XCTAssertTrue(soyRow.label.hasPrefix("1 ½ tbsp"), soyRow.label)
        XCTAssertTrue(app.staticTexts["Cooked 1×"].exists)
    }

    @MainActor
    func testResetToOriginalIsRecordedInHistory() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding(pantryPicks: ["shaoxing-wine"])
        app.importRecipe(url: StubPages.chowMein)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))

        app.buttons["detail.madeThis"].tap()
        let text = app.textViews["adjust.text"].exists ? app.textViews["adjust.text"] : app.textFields["adjust.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Skipped the bean sprouts")
        app.buttons["adjust.suggest"].tap()
        XCTAssertTrue(app.switches["adjust.edit.0"].waitForExistence(timeout: 10))
        app.buttons["adjust.save"].tap()

        app.buttons["detail.menu"].tap()
        app.buttons["Reset to original"].tap()
        app.buttons["Reset to original"].firstMatch.tap()

        let revisions = app.descendants(matching: .any).matching(identifier: "detail.revision")
        let reset = revisions.matching(NSPredicate(format: "label CONTAINS 'Reset to original'")).firstMatch
        app.scrollTo(reset)
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertEqual(revisions.count, 3, "import, cooked, reset all kept")
    }
}
