import XCTest

extension XCUIApplication {
    /// Launches with a fresh store (fresh-install behaviour) unless `reset` is false.
    func launchForTesting(reset: Bool = true, extra: [String] = [], environment: [String: String] = [:]) {
        launchArguments = ["-uiTesting", "-forceRules"] + (reset ? ["-resetData"] : []) + extra
        launchEnvironment = environment
        launch()
    }

    /// Runs through onboarding with defaults (plus whatever `configure` does on step 1).
    func completeOnboarding(pantryPicks: [String] = []) {
        XCTAssertTrue(buttons["onboarding.next"].waitForExistence(timeout: 15))
        buttons["onboarding.next"].tap()
        buttons["onboarding.next"].tap()
        buttons["onboarding.next"].tap()
        for id in pantryPicks { buttons["pantry.pick.\(id)"].tap() }
        buttons["onboarding.finish"].tap()
        XCTAssertTrue(tabBars.buttons["Recipes"].waitForExistence(timeout: 10))
    }
}

extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Scrolls the enclosing scroll view until the element is hittable.
    func scrollIntoView(in container: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !isHittable && swipes < maxSwipes {
            container.swipeUp()
            swipes += 1
        }
    }
}
