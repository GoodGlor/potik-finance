import XCTest

/// "Onboarded, bank connected, but no PIN" — the state a restore from backup
/// leaves (Application Support is included in iCloud/iTunes backups, but the
/// Keychain PIN deliberately is not), and the state any device left behind by
/// a build predating the "never strand the user" fix would already be in.
/// RootView.phase already routes this back into onboarding; this proves the
/// user can actually get through it — specifically past BankPickerView,
/// which without `allowConnected` would show monobank as connected-and-
/// disabled with PrivatBank still comingSoon, leaving no row selectable and
/// completeOnboarding() forever unreachable.
final class RecoveryTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    func testForgottenPinAfterOnboardingRecoversThroughAnAlreadyConnectedBank() {
        // First launch: establish "onboarded, monobank connected" via the
        // normal skip-onboarding path.
        let first = XCUIApplication()
        first.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-skipOnboarding", "-lang", "uk"]
        first.launch()
        XCTAssertTrue(first.tabBars.buttons["Головна"].waitForExistence(timeout: 5))
        first.terminate()

        // Second launch: forget only the PIN, leave Application Support
        // (banks, settings.onboarded) alone — no -resetState.
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-noBiometrics", "-stubMonobank", "-forgetPin", "-lang", "uk"]
        app.launch()

        // Stranded no more: routed back into onboarding, not a dead lock screen.
        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)
        // -noBiometrics → the Face ID offer skips itself.

        // The picker: monobank is already connected from the first run, and
        // must still be selectable during re-onboarding.
        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        XCTAssertTrue(mono.isEnabled, "an already-connected bank must stay selectable while re-onboarding")
        // Board #19: tapping the row goes straight on. The assertion above —
        // that an already-connected bank stays ENABLED while re-onboarding —
        // is what this walk is really about, and it now carries the whole
        // weight, since there is no «Далі» left to be enabled instead.
        mono.tap()

        let connect = app.buttons["bank.token.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        let field = app.secureTextFields["bank.token.field"]
        field.tap()
        field.typeText("again1")
        connect.tap()

        // Task 11 inserted the card-selection step between the token screen
        // and the sync-depth choice — see OnboardingTests.
        let cardsNext = app.buttons["cards.next"]
        XCTAssertTrue(cardsNext.waitForExistence(timeout: 5), "cards screen after the mock validation")
        cardsNext.tap()

        // Task 11 inserted the sync-depth choice between the cards screen
        // and the connected screen — see OnboardingTests.
        let depth = app.buttons["depth.3"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5), "depth screen after the mock validation")
        depth.tap()

        let start = app.buttons["bank.connected.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()                                    // «Далі» → picker, not tabs

        // The connected screen no longer ends onboarding by itself — the
        // picker's «Готово» does, once a bank is connected.
        let skip = app.buttons["bank.done"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5),
                      "«Готово» must appear now that the already-connected bank is reconnected")
        skip.tap()

        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 3),
                      "completeOnboarding() must be reachable again")
    }
}
