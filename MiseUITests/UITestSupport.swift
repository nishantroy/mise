import XCTest

extension XCUIApplication {
    /// Launches with a fresh store (fresh-install behaviour) unless `reset` is false.
    func launchForTesting(reset: Bool = true, forceRules: Bool = true, extra: [String] = [], environment: [String: String] = [:]) {
        launchArguments = ["-uiTesting"] + (forceRules ? ["-forceRules"] : []) + (reset ? ["-resetData"] : []) + extra
        launchEnvironment = environment
        launch()
    }

    /// Runs through onboarding with defaults (plus whatever `configure` does on step 1).
    func completeOnboarding(pantryPicks: [String] = []) {
        XCTAssertTrue(buttons["onboarding.next"].waitForExistence(timeout: 15))
        // Tap Continue until the last page; taps during the page animation can be dropped.
        var taps = 0
        while !buttons["onboarding.finish"].waitForExistence(timeout: 1) && taps < 8 {
            if buttons["onboarding.next"].isHittable { buttons["onboarding.next"].tap() }
            taps += 1
        }
        XCTAssertTrue(buttons["onboarding.finish"].exists)
        for id in pantryPicks {
            let chip = buttons["pantry.pick.\(id)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            chip.scrollIntoView(in: scrollViews.firstMatch)
            chip.tap()
        }
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

enum StubPages {
    static let porkBelly = "https://example.test/red-braised-pork-belly"
    static let chowMein = "https://example.test/chow-mein"
    static let notARecipe = "https://example.test/not-a-recipe"
    /// Shaoxing wine listed twice (marinade and sauce).
    static let twiceWine = "https://example.test/twice-wine"

    /// Launch environment serving fixture HTML for the stub URLs.
    static func environment() -> [String: String] {
        let bundle = Bundle(for: BundleToken.self)
        func html(_ name: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("missing fixture \(name)")
                return ""
            }
            return text
        }
        let pages = [
            porkBelly: html("woksoflife-red-braised-pork-belly"),
            chowMein: html("recipetineats-chow-mein"),
            notARecipe: "<html><head><title>Hello</title></head><body><p>No recipe here.</p></body></html>",
            twiceWine: """
            <html><head><script type="application/ld+json">
            {"@type":"Recipe","name":"Drunken Chicken","recipeYield":"4",
             "recipeIngredient":["500 g chicken thighs","2 tbsp Shaoxing wine","1 tbsp soy sauce","1 tbsp Shaoxing wine"],
             "recipeInstructions":["Marinate the chicken in the Shaoxing wine and soy sauce.","Cook, then splash in the rest of the Shaoxing wine."]}
            </script></head><body></body></html>
            """,
        ]
        let data = try! JSONEncoder().encode(pages)
        return ["MISE_STUB_PAGES": String(decoding: data, as: UTF8.self)]
    }
}

private final class BundleToken {}

extension XCUIApplication {
    /// From the Recipes tab: open the import sheet, enter a URL and import it.
    func importRecipe(url: String) {
        let importButton = buttons["recipes.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        let field = textFields["import.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(url)
        buttons["import.go"].tap()
    }

    /// Scrolls the main scroll view until `element` is hittable.
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 12) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            let container = scrollViews.firstMatch.exists ? scrollViews.firstMatch : collectionViews.firstMatch
            container.swipeUp()
            swipes += 1
        }
    }
}
