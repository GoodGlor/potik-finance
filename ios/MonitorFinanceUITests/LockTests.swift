import XCTest

final class LockTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "locked", "-lang", "uk"] + extra
        app.launch()
        return app
    }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    func testCorrectPinUnlocksToTheTabs() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Головна"].isHittable, "tabs must be covered while locked")
        type("1111", in: app)
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 3))
        assertLive(app.tabBars.buttons["Головна"])
    }

    func testWrongPinStaysLockedAndSaysSo() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        type("9999", in: app)
        XCTAssertTrue(app.staticTexts["pin.message"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["pin.message"].label.contains("Невірний"))
        XCTAssertFalse(app.tabBars.buttons["Головна"].exists)
    }

    func testFifthWrongAttemptLocksTheKeypad() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        for _ in 0..<5 {
            type("9999", in: app)
            usleep(500_000)   // let the shake clear the dots
        }
        let msg = app.staticTexts["pin.message"]
        XCTAssertTrue(msg.waitForExistence(timeout: 2))
        XCTAssertTrue(msg.label.contains("Забагато спроб"), msg.label)
        XCTAssertFalse(app.buttons["pin.key.1"].isEnabled)
    }

    func testFaceIdButtonIsHiddenWhenBiometricsAreUnavailable() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lock.faceid"].exists)
    }

    // MARK: the grace period (board #21)

    /// Really backgrounds the app and really brings it back — the only way to
    /// exercise this, since the whole behaviour is a `scenePhase` round trip.
    /// The unit tests own the arithmetic (`LockGraceTests`); these two own the
    /// wiring, which is the half no amount of injected `now` can reach.
    private func leaveAndReturn(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5),
                      "the app never actually backgrounded, so this proves nothing")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    /// Board #21's whole point: the app's own core flow sends a person to
    /// another app for a statement, and it used to charge them a code on the
    /// way back.
    func testComingStraightBackDoesNotAskForTheCodeAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-lang", "uk"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 5))

        leaveAndReturn(app)

        XCTAssertFalse(app.staticTexts["Введіть код"].waitForExistence(timeout: 2),
                       "a return inside the minute must not ask for the code")
        assertLive(app.tabBars.buttons["Головна"])
    }

    /// «Блокувати одразу» is the other half of the acceptance: the old
    /// behaviour has to remain available to anyone who wants it.
    func testImmediateModeStillLocksOnTheWayBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-lang", "uk"]
        app.launch()

        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        let toggle = app.switches["settings.lockImmediately"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "the grace is the default")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")

        leaveAndReturn(app)

        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5),
                      "«Блокувати одразу» must still lock on every return")
    }
}
