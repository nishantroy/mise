import XCTest

/// Not a check: walks the main screens and saves screenshots to $MISE_SHOT_DIR (host path)
/// for design review. Skipped unless that variable is set (pass it as TEST_RUNNER_MISE_SHOT_DIR).
final class ScreenshotTour: XCTestCase {
    @MainActor
    func testTour() throws {
        guard let dir = ProcessInfo.processInfo.environment["MISE_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MISE_SHOT_DIR to capture screenshots")
        }
        let prefix = ProcessInfo.processInfo.environment["MISE_SHOT_PREFIX"] ?? "shot"
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
        let app = XCUIApplication()
        app.launchForTesting(reset: true, environment: StubPages.environment())
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 15))
        shot("01-onboarding")
        app.buttons["onboarding.next"].tap(); sleep(1); shot("02-onboarding-dislikes")
        app.buttons["onboarding.next"].tap(); sleep(1)
        app.buttons["onboarding.next"].tap(); sleep(1); shot("03-onboarding-pantry")
        app.buttons["pantry.pick.soy-sauce"].tap()
        app.buttons["pantry.pick.dry-sherry"].tap()
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
        shot("04-recipes-empty")

        app.importRecipe(url: StubPages.porkBelly)
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 10))
        sleep(1); shot("05-check")
        let no = app.buttons["review.shaoxing-wine.no"]
        app.scrollTo(no); no.tap(); sleep(1)
        shot("06-check-swaps")
        let sherry = app.buttons["swap.shaoxing-wine.dry-sherry"]
        app.scrollTo(sherry); sherry.tap()
        app.buttons["review.save"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        sleep(1); shot("07-detail")
        app.swipeUp(); sleep(1); shot("08-detail-steps")
        app.swipeUp(); app.swipeUp(); sleep(1); shot("09-detail-history")

        app.buttons["detail.madeThis"].tap()
        let text = app.textViews["adjust.text"].exists ? app.textViews["adjust.text"] : app.textFields["adjust.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Used light soy sauce instead of dark soy sauce, needed 10 more minutes")
        app.buttons["adjust.chip.Too salty"].tap()
        app.buttons["adjust.suggest"].tap()
        _ = app.switches["adjust.edit.0"].waitForExistence(timeout: 10)
        app.swipeUp(); sleep(1); shot("10-adjust")
        app.buttons["adjust.save"].tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1); shot("11-recipes")
        app.tabBars.buttons["Pantry"].tap(); sleep(1); shot("12-pantry")
        app.tabBars.buttons["Settings"].tap(); sleep(1); shot("13-settings")
    }
}
