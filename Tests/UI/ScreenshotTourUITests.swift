import StoreKitTest
import XCTest

/// Visual QA tour with the DEBUG simulated TV. Runs only when `SCREENSHOT_DIR` is provided
/// (xcodebuild: `TEST_RUNNER_SCREENSHOT_DIR=/path`, optional `TEST_RUNNER_SCREENSHOT_LANG=ru`
/// and `TEST_RUNNER_SCREENSHOT_TEXT=accessibilityL` for large Dynamic Type).
/// These are QA images of the real UI with a simulated TV — not App Store screenshots,
/// which must be taken with a physical TV (see Documentation/APP_STORE.md).
final class ScreenshotTourUITests: XCTestCase {
    private var directory: URL!
    private var language = "en"
    private var prefix = "en"
    private var textSize: String?
    private var storeSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR not set")
        }
        language = environment["SCREENSHOT_LANG"] ?? "en"
        textSize = environment["SCREENSHOT_TEXT"].flatMap { $0.isEmpty ? nil : $0 }
        prefix = [language, textSize].compactMap { $0 }.joined(separator: "_")
        directory = URL(fileURLWithPath: path)
        // Local StoreKit test products so the paywall shows real test prices.
        storeSession = try? SKTestSession(configurationFileNamed: "RemotePro")
        storeSession?.resetToDefaultState()
        storeSession?.clearTransactions()
        storeSession?.disableDialogs = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let data = app.screenshot().pngRepresentation
        try? data.write(to: directory.appendingPathComponent("\(prefix)_\(name).png"))
    }

    /// Paywall without a TV, for the App Review screenshot of each in-app purchase.
    func testReviewScreenshot() {
        let app = launch(demoTV: false)
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10))
        app.buttons["onboarding.skip"].tap()
        if app.buttons["discovery.skip"].waitForExistence(timeout: 5) { app.buttons["discovery.skip"].tap() }
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.buttons["settings.remotePro"].waitForExistence(timeout: 5))
        app.buttons["settings.remotePro"].tap()
        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 10))
        sleep(2)
        snap(app, "review_paywall")
    }

    func testDesignStates() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITestsResetState", "-DesignStates", "-AppleLanguages", "(\(language))"]
        app.launch()
        for (id, name) in [("states.pending", "30_purchase_pending"), ("states.unavailable", "34_plans_unavailable"),
                           ("states.unconfirmed", "43_purchase_unconfirmed"), ("states.noTV", "28_no_tv"),
                           ("states.network", "29_network_blocked"), ("states.success", "20_purchase_success"),
                           ("states.quality", "45_mirroring_quality")] {
            let link = app.buttons[id]
            guard link.waitForExistence(timeout: 5) else { continue }
            link.tap()
            sleep(1)
            snap(app, "states_\(name)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
    }

    private func launch(demoTV: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        let region = ["en": "US", "es": "ES", "ru": "RU", "de": "DE", "fr": "FR"][language] ?? "US"
        app.launchArguments += ["-UITests", "-UITestsResetState", "-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_\(region)"]
        if demoTV { app.launchArguments.append("-DemoTV") }
        if let textSize {
            let category = ["large": "UICTContentSizeCategoryXXL", "accessibilityL": "UICTContentSizeCategoryAccessibilityL"][textSize] ?? textSize
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launch()
        return app
    }

    func testOnboarding() {
        let app = launch(demoTV: false)
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10))
        sleep(1)
        snap(app, "01_onboarding_1")
        app.buttons["onboarding.next"].tap()
        sleep(1)
        snap(app, "02_onboarding_2")
        app.buttons["onboarding.next"].tap()
        sleep(1)
        snap(app, "03_onboarding_3")
        app.buttons["onboarding.connect"].tap()
        sleep(1)
        snap(app, "04_connect")
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    func testTour() {
        let app = launch(demoTV: true)
        sleep(3)
        snap(app, "05_remote_buttons")

        // Touchpad mode (design 04), then back to buttons.
        let touchpad = app.buttons.matching(identifier: "remote.inputStyle").firstMatch
        if app.buttons["Touchpad"].exists { app.buttons["Touchpad"].tap() } else if touchpad.exists { touchpad.tap() }
        sleep(1)
        snap(app, "05b_remote_touchpad")

        if app.buttons["remote.more"].waitForExistence(timeout: 3) {
            app.buttons["remote.more"].tap()
            sleep(2)
            snap(app, "06_more_controls")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }

        if app.buttons["remote.keyboard"].waitForExistence(timeout: 3) {
            app.buttons["remote.keyboard"].tap()
            sleep(2)
            snap(app, "06b_keyboard")
            back(app)
        }

        let allApps = app.buttons["remote.apps.all"]
        if allApps.waitForExistence(timeout: 3) {
            allApps.tap()
            sleep(2)
            snap(app, "06c_apps")
            back(app)
        }

        // Compatibility results from the TV card menu (design 09).
        let card = app.buttons["remote.tvCard"]
        if card.exists {
            card.tap()
            sleep(1)
            let check = app.buttons["tvCard.compatibility"]
            if check.waitForExistence(timeout: 2) {
                check.tap()
                sleep(3)
                snap(app, "06d_compatibility")
                if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.swipeDown(velocity: .fast) }
                sleep(1)
            } else {
                app.tap()
            }
        }

        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        snap(app, "07_cast")
        if app.buttons["cast.mirroring"].waitForExistence(timeout: 3) {
            app.buttons["cast.mirroring"].tap()
            sleep(2)
            snap(app, "07b_mirroring_setup")
            app.swipeUp()
            sleep(1)
            snap(app, "07c_mirroring_setup_bottom")
            back(app)
        }

        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(1)
        snap(app, "08_settings")
        app.swipeUp()
        sleep(1)
        snap(app, "08b_settings_bottom")
        app.swipeDown()
        sleep(1)

        app.buttons["settings.language"].tap()
        sleep(1)
        snap(app, "08c_language")
        back(app)

        app.buttons["settings.savedTVs"].tap()
        sleep(1)
        snap(app, "08d_saved_tvs")
        back(app)

        app.buttons["settings.help"].tap()
        sleep(2)
        snap(app, "08e_help")
        if app.buttons["help.quick.tvNotFound"].exists {
            app.buttons["help.quick.tvNotFound"].tap()
            sleep(1)
            snap(app, "08f_help_article")
        }
        app.swipeDown(velocity: .fast)
        sleep(1)
        if app.buttons["Done"].exists { app.buttons["Done"].tap(); sleep(1) }

        app.buttons["settings.notifications"].tap()
        sleep(1)
        snap(app, "09_notifications")
        back(app)

        app.buttons["settings.privacy"].tap()
        sleep(1)
        snap(app, "09b_privacy")
        back(app)

        app.buttons["settings.contact"].tap()
        sleep(2)
        snap(app, "10_support")
        app.swipeUp()
        sleep(1)
        snap(app, "11_support_bottom")
        back(app)

        app.buttons["settings.remotePro"].tap()
        XCTAssertTrue(app.buttons["paywall.purchase"].waitForExistence(timeout: 10))
        sleep(1)
        snap(app, "12_paywall")
        app.buttons["paywall.plan.lifetime"].tap()
        app.swipeUp()
        sleep(1)
        snap(app, "13_paywall_lifetime")
        app.buttons["paywall.close"].tap()
    }
}
