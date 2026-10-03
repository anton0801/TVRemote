import XCTest

/// End-to-end UI flow without a TV (simulator has no local-network TVs).
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITestsResetState", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// Intro pages → Connect TV → skip connecting.
    private func skipToMainTabs(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["discovery.skip"].waitForExistence(timeout: 5))
        app.buttons["discovery.skip"].tap()
        XCTAssertTrue(app.tabBars.buttons["Remote"].waitForExistence(timeout: 5))
    }

    func testThreeIntroPagesThenConnectStep() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Your TV. One remote."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Step 1 of 3"].exists || app.otherElements["Step 1 of 3"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'plan'")).firstMatch.exists, "Paid plans are disclosed before connecting")
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.staticTexts["Your favorites. One tap."].waitForExistence(timeout: 5))
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.staticTexts["Small moments. Big screen."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'payment'")).firstMatch.exists, "Trying is free and says so")
        XCTAssertFalse(app.buttons["onboarding.skip"].exists, "The last page has one clear action")
        XCTAssertTrue(app.buttons["onboarding.connect"].label.contains("Connect my TV"))
        app.buttons["onboarding.connect"].tap()

        // Explanation first; the iOS Local Network prompt only follows the user's tap.
        XCTAssertTrue(app.navigationBars["Connect your TV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discovery.start"].exists)
        app.buttons["discovery.skip"].tap()
        XCTAssertTrue(app.tabBars.buttons["Remote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No TV yet"].exists)
    }

    func testHelpCenterAndIntroductionReplay() {
        let app = launch()
        skipToMainTabs(app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.help"].waitForExistence(timeout: 5))
        app.buttons["settings.help"].tap()
        XCTAssertTrue(app.staticTexts["How can we help?"].waitForExistence(timeout: 5))
        app.buttons["help.quick.tvNotFound"].tap()
        XCTAssertTrue(app.buttons["Search again"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let replay = app.buttons["help.introduction"]
        for _ in 0..<6 where !replay.isHittable { app.swipeUp() }
        replay.tap()
        XCTAssertTrue(app.staticTexts["Your TV. One remote."].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap() // "Close" in replay mode
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
    }

    func testSettingsBannerOpensPaywallWithoutPurchase() {
        let app = launch()
        skipToMainTabs(app)
        app.tabBars.buttons["Settings"].tap()
        let banner = app.buttons["settings.remotePro"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.label.contains("Explore Pro"))
        banner.tap()
        XCTAssertTrue(app.buttons["paywall.restore"].waitForExistence(timeout: 5), "Restore is always reachable")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Your TV.'")).firstMatch.exists)
        XCTAssertFalse(app.switches.containing(NSPredicate(format: "label CONTAINS[c] 'trial'")).firstMatch.exists, "No trial toggle on the paywall")
        app.buttons["paywall.close"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
    }

    func testNotificationTogglesAreUsable() {
        let app = launch()
        skipToMainTabs(app)
        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons["settings.notifications"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        for category in ["trialReminder", "service", "offers"] {
            let toggle = app.switches["notifications.\(category)"]
            XCTAssertTrue(toggle.exists, category)
            XCTAssertTrue(toggle.isEnabled, "\(category): before iOS is asked, every category can be switched")
        }
        XCTAssertEqual(app.switches["notifications.offers"].value as? String, "0", "Marketing is off by default")
    }

    /// Review N3: a paywall requested from inside one of the remote's own sheets must appear
    /// (SwiftUI can't stack it on top, so the sheet is closed first) — not be silently dropped.
    func testPaywallAppearsFromRemoteSheetWhenFreeCheckIsUsedUp() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITestsResetState", "-DemoTV", "-DemoFreeCheckUsed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let more = app.buttons["remote.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let digit = app.buttons.matching(NSPredicate(format: "label == '1'")).firstMatch
        XCTAssertTrue(digit.waitForExistence(timeout: 5))
        digit.tap()
        XCTAssertTrue(app.buttons["paywall.restore"].waitForExistence(timeout: 5), "The paywall replaced the sheet")
        app.buttons["paywall.close"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }
}
