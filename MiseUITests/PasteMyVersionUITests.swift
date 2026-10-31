import XCTest

/// "Paste my version" on the stubbed Woks of Life original: the expected edits and pantry
/// toggles appear, an unticked change isn't applied, and history shows "Your version".
final class PasteMyVersionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPasteMyVersionAppliesOnlyTickedChanges() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()
        app.importAndSave(url: StubPages.mongolianBeef)
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Shortcut Mongolian Ground Beef")

        app.buttons["detail.menu"].tap()
        let entry = app.buttons["Paste my version"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        app.enterMyVersion(StubPages.myVersionText)
        app.tapCompare()
        for label in [
            "Swapped ginger and garlic for ginger garlic paste",
            "Swapped Shaoxing wine for sherry",
            "Leave out dark soy sauce",
            "Add 1 tbsp Lao Gan Ma",
            "Use your steps (11 steps)",
            "Serves 4 (was 6)",
            "Pantry: Shaoxing wine → don't have",
            "Pantry: Lao Gan Ma → have",
        ] {
            XCTAssertTrue(app.proposal(label).exists, "missing toggle: \(label)")
        }
        let rename = app.proposal("Rename to “Mongolian Ground Beef”")
        XCTAssertEqual(rename.value as? String, "0", "the title is kept unless the user opts in")

        // Untick "Leave out dark soy sauce".
        let darkSoy = app.proposal("Leave out dark soy sauce")
        app.scrollTo(darkSoy)
        darkSoy.switches.firstMatch.exists ? darkSoy.switches.firstMatch.tap() : darkSoy.tap()
        XCTAssertEqual(darkSoy.value as? String, "0")
        app.buttons["myVersion.save"].tap()

        // Back on the detail: the revision lists the ticked changes, not the unticked one.
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Shortcut Mongolian Ground Beef")
        let revision = app.descendants(matching: .any).matching(identifier: "detail.revision")
            .matching(NSPredicate(format: "label CONTAINS 'Your version'")).firstMatch
        app.scrollTo(revision)
        XCTAssertTrue(revision.waitForExistence(timeout: 5))
        XCTAssertTrue(revision.label.contains("Swapped Shaoxing wine for sherry"), revision.label)
        XCTAssertTrue(revision.label.contains("Use your steps (11 steps)"), revision.label)
        XCTAssertFalse(revision.label.contains("dark soy"), revision.label)

        // The recipe: dark soy sauce kept (unticked), paste in, the user's steps.
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let rows = app.descendants(matching: .any).matching(identifier: "detail.ingredient")
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Dark soy sauce'")).firstMatch.exists)
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Ginger garlic paste'")).firstMatch.exists)
        XCTAssertFalse(rows.matching(NSPredicate(format: "label CONTAINS 'Shaoxing'")).firstMatch.exists)
        let firstStep = app.descendants(matching: .any).matching(identifier: "detail.step")
            .matching(NSPredicate(format: "label CONTAINS 'Slice ½ onion'")).firstMatch
        app.scrollTo(firstStep)
        XCTAssertTrue(firstStep.exists, "the user's steps replaced the originals")
    }
}

extension XCUIApplication {
    /// From the Recipes tab: import a stubbed URL and save it without answering the check.
    func importAndSave(url: String) {
        importRecipe(url: url)
        XCTAssertTrue(buttons["review.save"].waitForExistence(timeout: 15))
        buttons["review.save"].tap()
        XCTAssertTrue(staticTexts["detail.title"].waitForExistence(timeout: 10))
    }

    /// Taps Compare once it's enabled and hittable, and again if no proposals appear (a tap
    /// during layout after a paste can be dropped on a loaded machine).
    func tapCompare() {
        let compare = buttons["myVersion.compare"]
        let ready = NSPredicate(format: "isEnabled == true AND hittable == true")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: compare)], timeout: 10)
        compare.tap()
        if !switches["myVersion.edit.0"].waitForExistence(timeout: 10) {
            compare.tap()
        }
        XCTAssertTrue(switches["myVersion.edit.0"].waitForExistence(timeout: 15), "proposals appear after Compare")
    }

    /// A toggle on the "my version" screen, by its label.
    func proposal(_ label: String) -> XCUIElement {
        switches.matching(NSPredicate(format: "identifier BEGINSWITH 'myVersion.' AND label == %@", label)).firstMatch
    }

    /// Fills the "my version" text box: through the clipboard and the PasteButton (fast and
    /// reliable on a loaded machine), falling back to typing.
    func enterMyVersion(_ text: String) {
        let editor = textViews["myVersion.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        UIPasteboard.general.string = text
        let paste = buttons["Paste"].firstMatch
        if paste.waitForExistence(timeout: 5) {
            paste.tap()
        }
        let filled = NSPredicate(format: "value CONTAINS 'Mongolian Ground Beef'")
        if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: filled, object: editor)], timeout: 5) != .completed {
            editor.tap()
            editor.typeText(text)
        }
    }
}
