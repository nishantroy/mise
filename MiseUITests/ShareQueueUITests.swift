import XCTest

/// M8: a URL queued in the App Group (as the share extension does) opens the import screen
/// with that URL when the app becomes active.
final class ShareQueueUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testQueuedURLOpensImportScreen() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, extra: ["-enqueueImport", StubPages.chowMein], environment: StubPages.environment())
        // Queue is drained only once onboarding is done.
        app.completeOnboarding()

        let field = app.textFields["import.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "import sheet appears")
        XCTAssertEqual(field.value as? String, StubPages.chowMein)
        app.buttons["import.go"].tap()
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Chow Mein"].exists)
    }

    /// Text shared from another app (e.g. claude.ai), queued next to an already saved original:
    /// the best title match is offered first and opens "Paste my version" already compared.
    @MainActor
    func testSharedTextAttachesAsMyVersion() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        app.completeOnboarding()
        app.importAndSave(url: StubPages.chowMein)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.importAndSave(url: StubPages.mongolianBeef)
        app.terminate()

        // As if the share extension had queued the text while Mise wasn't running.
        app.launchForTesting(reset: false, extra: ["-enqueueTextBase64", Data(StubPages.myVersionText.utf8).base64EncodedString()], environment: StubPages.environment())
        let best = app.buttons["share.attach.0"]
        XCTAssertTrue(best.waitForExistence(timeout: 15), "the shared-text choice appears")
        XCTAssertTrue(app.buttons["share.newRecipe"].exists)
        XCTAssertTrue(best.label.contains("Shortcut Mongolian Ground Beef"), best.label)
        XCTAssertTrue(best.label.contains("Best match"), best.label)
        XCTAssertTrue(app.buttons["share.attach.1"].label.contains("Chow Mein"))
        best.tap()
        // A tap can be dropped on a loaded machine; try once more if the screen didn't open.
        if !app.navigationBars["Paste my version"].waitForExistence(timeout: 8), best.exists {
            best.tap()
        }
        XCTAssertTrue(app.navigationBars["Paste my version"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.switches["myVersion.edit.0"].waitForExistence(timeout: 15), "compared straight away")
        XCTAssertTrue(app.proposal("Swapped Shaoxing wine for sherry").exists)
        app.buttons["myVersion.save"].tap()

        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Shortcut Mongolian Ground Beef")
        let revision = app.descendants(matching: .any).matching(identifier: "detail.revision")
            .matching(NSPredicate(format: "label CONTAINS 'Your version'")).firstMatch
        app.scrollTo(revision)
        XCTAssertTrue(revision.exists)
    }

    /// Shared text can also become a new recipe, through the import screen's Text tab.
    @MainActor
    func testSharedTextSavesAsNewRecipe() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, extra: ["-enqueueTextBase64", Data(StubPages.myVersionText.utf8).base64EncodedString()], environment: StubPages.environment())
        app.completeOnboarding()
        let newRecipe = app.buttons["share.newRecipe"]
        XCTAssertTrue(newRecipe.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["share.attach.0"].exists, "no saved recipes to attach to")
        newRecipe.tap()
        let go = app.buttons["import.go"]
        XCTAssertTrue(go.waitForExistence(timeout: 10))
        go.tap()
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 15))
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Mongolian Ground Beef")
        let rows = app.descendants(matching: .any).matching(identifier: "detail.ingredient")
        XCTAssertEqual(rows.count, 19)
    }

    @MainActor
    func testQueueIsDrainedOnce() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true, extra: ["-enqueueImport", StubPages.porkBelly], environment: StubPages.environment())
        app.completeOnboarding()
        XCTAssertTrue(app.textFields["import.url"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()

        // Background and foreground: nothing new in the queue, so no sheet.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["import.url"].waitForExistence(timeout: 3))
    }
}
