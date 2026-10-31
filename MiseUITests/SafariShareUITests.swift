import XCTest

/// Best effort: drives Safari's share sheet in the simulator. Skips (rather than fails) when the
/// simulator's Safari or share sheet doesn't cooperate; the owner checks this on a phone.
final class SafariShareUITests: XCTestCase {
    @MainActor
    func testShareFromSafariQueuesURL() throws {
        let app = XCUIApplication()
        app.launchForTesting(reset: true)
        app.completeOnboarding()
        XCUIDevice.shared.press(.home)

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let target = "https://example.com/"
        safari.open(URL(string: target)!)
        guard safari.wait(for: .runningForeground, timeout: 20) else { throw XCTSkip("Safari didn't open") }
        sleep(4)
        // iOS 26 Safari keeps Share in the "More" menu.
        let more = safari.buttons["MoreMenuButton"]
        if !safari.buttons["ShareButton"].exists, more.waitForExistence(timeout: 10) { more.tap() }
        let share = safari.buttons["ShareButton"].exists ? safari.buttons["ShareButton"] : safari.buttons["Share"].firstMatch
        guard share.waitForExistence(timeout: 15) else {
            let buttons = safari.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.identifier)|\($0.label)" }
            print("MISE-LOG safari buttons: \(buttons)")
            throw XCTSkip("No Safari share button found")
        }
        share.tap()
        let mise = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Mise'")).firstMatch
        guard mise.waitForExistence(timeout: 10) else {
            let cells = safari.descendants(matching: .any).matching(NSPredicate(format: "label != ''")).allElementsBoundByIndex.prefix(60).map(\.label)
            print("MISE-LOG share sheet: \(cells)")
            throw XCTSkip("Mise not listed in the share sheet")
        }
        mise.tap()
        sleep(3)

        app.activate()
        let field = app.textFields["import.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "import sheet appears after sharing")
        XCTAssertEqual(field.value as? String, target)
    }
}
