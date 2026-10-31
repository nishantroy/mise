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
