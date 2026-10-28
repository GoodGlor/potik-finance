import XCTest

final class OnboardingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(extra: [String] = ["-stubMonobank"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-lang", "uk"] + extra
        app.launch()
        return app
    }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    /// PIN → confirm → (Face ID skips itself under `-noBiometrics`) → pick
    /// monobank → «Далі», landing on the token screen. Every test that needs
    /// a token screen starts here rather than repeating the walk.
    /// `onBankPicker` runs after the picker appears but before monobank is
    /// tapped, for the one test that also asserts something about that screen.
    private func walkToTokenScreen(_ app: XCUIApplication, onBankPicker: (() -> Void)? = nil) {
        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        onBankPicker?()
        // Board #19: the tap IS the choice — there is no «Далі» to confirm it.
        mono.tap()
        XCTAssertTrue(app.buttons["bank.token.connect"].waitForExistence(timeout: 3))
    }

    /// Board #19. The picker was a radio button plus a «Далі» — two taps to
    /// answer a two-item question — and the «Далі» was the biggest control on
    /// the screen while being *disabled* until a row was picked, so the eye
    /// landed on a dead button.
    func testTappingABankRowGoesStraightOnWithNothingToConfirm() {
        let app = launch()
        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bank.next"].exists, "there is nothing left to confirm")
        // The row goes somewhere, and says so the way every other row-shaped
        // button in this app does. Asserted rather than assumed: board #9
        // dumped the tree and found a chevron survives inside a merged Button
        // label as an `Image` of its own.
        XCTAssertTrue(mono.images["chevron.right"].exists,
                      "a row that navigates must carry the app's own affordance for it")

        mono.tap()
        XCTAssertTrue(app.buttons["bank.token.connect"].waitForExistence(timeout: 3),
                      "one tap must reach the token screen")
    }

    /// Board #18. Step 1 named an address and gave no way to reach it, so the
    /// person left the app, found a browser and retyped `api.monobank.ua` by
    /// hand — on the one screen where a typo hands a live banking token to
    /// whoever registered the near-miss domain.
    ///
    /// **This test genuinely leaves the app**, which is why it is the only one
    /// that does: `TokenPortalTests` pins WHICH address, and nothing but a real
    /// tap can say the row reaches a browser at all. Safari is terminated
    /// afterwards so it cannot sit in front of the next test.
    func testTheTokenStepOpensMonobanksPageInABrowser() {
        let app = launch()
        walkToTokenScreen(app)

        let portal = app.buttons["bank.token.portal"]
        XCTAssertTrue(portal.waitForExistence(timeout: 3), "step 1 must be the link, not prose about one")
        XCTAssertTrue(portal.isHittable, "a link below the fold is the prose it replaced")
        XCTAssertTrue(portal.label.contains("api.monobank.ua"),
                      "the row must show the address it opens: \(portal.label)")

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        portal.tap()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20),
                      "tapping step 1 must reach a browser")
        safari.terminate()
    }

    /// The other half of #18: the picker introduced monobank «через особистий
    /// токен» — a developer's word for it. A person choosing a bank has not met
    /// a token yet, and what they want to know is whether the bank sanctions
    /// this at all.
    func testThePickerSaysTheAccessIsOfficialRatherThanNamingAToken() {
        let app = launch()
        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        XCTAssertTrue(mono.label.contains("офіційний доступ monobank"),
                      "the row must say whose access it is, in words: \(mono.label)")
        XCTAssertFalse(mono.label.contains("токен"), "…and must not lead with the jargon")
    }

    /// Board #16. The very first thing the app ever said to anybody was
    /// «Придумайте код» — a demand, before a word about what the app is for,
    /// from something they had just installed and had no reason yet to trust.
    func testTheFirstScreenSaysWhatTheAppIsForBeforeAskingForAnything() {
        let app = launch()

        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "the welcome screen comes first")
        assertLive(start)
        XCTAssertFalse(app.buttons["pin.key.1"].exists,
                       "nothing may be demanded before the app has said what it is")
        // Board #130 — «Потік», in Cyrillic because this launch is `-lang uk`.
        // The name is transliterated, not translated: an English launch of the
        // same screen reads «Potik», which `CategoryLabelLanguageTests`' sibling
        // `AppNameTests` pins at the catalogue.
        XCTAssertTrue(app.staticTexts["Потік"].exists, "the app names itself")

        start.tap()
        XCTAssertTrue(app.staticTexts["Придумайте код"].waitForExistence(timeout: 3))
        // And the PIN screen now answers the question it used to provoke.
        XCTAssertTrue(
            app.staticTexts["Чотири цифри. Ваші фінанси бачитимете лише ви."].exists,
            "the subtitle must say WHY a code, not only how many digits")
    }

    func testMismatchedConfirmationReturnsToSetPin() {
        let app = launch()
        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("2222", in: app)
        XCTAssertTrue(app.staticTexts["Придумайте код"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["pin.message"].label.contains("не збігаються"))
        // Board #16 put a screen in front of the PIN pad, and the mismatch
        // path got back to it by EMPTYING the navigation path — which now
        // lands on the welcome screen instead, silently dropping the message
        // that explains why the second attempt vanished.
        XCTAssertFalse(app.buttons["welcome.start"].exists,
                       "a mismatch must return to the PIN pad, not to the start of onboarding")
    }

    func testDeleteRemovesTheLastDigit() {
        let app = launch()
        app.startOnboarding()
        // Type 1,1,2 (three digits — not yet complete, so nothing has fired
        // or been scheduled), delete the 2, then 1,1. If delete works the
        // stored PIN is "1111". If delete were a no-op, the entry would
        // still be "112" when the next tap ("1") completes it as "1121",
        // and the final "1" is silently swallowed (four digits already).
        // Confirming with "1111" tells the two apart: it advances past
        // confirmation only when the stored PIN really is "1111".
        app.buttons["pin.key.1"].tap()
        app.buttons["pin.key.1"].tap()
        app.buttons["pin.key.2"].tap()
        app.buttons["pin.delete"].tap()
        app.buttons["pin.key.1"].tap()
        app.buttons["pin.key.1"].tap()
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)
        XCTAssertTrue(app.buttons["bank.row.monobank"].waitForExistence(timeout: 3),
                      "delete should have left the stored PIN as 1111")
    }

    func testFirstRunEndsOnTheTabsWithMonobankConnected() {
        let app = launch()
        walkToTokenScreen(app) {
            XCTAssertTrue(app.buttons["bank.row.privatbank"].isEnabled,
                          "PrivatBank is a statement-import bank now, selectable straight from the picker")
        }

        let connect = app.buttons["bank.token.connect"]
        assertLive(connect, "connect must be pinned above the fold")
        connect.tap()
        XCTAssertTrue(app.staticTexts["bank.token.error"].waitForExistence(timeout: 2), "empty token must be refused")

        let field = app.secureTextFields["bank.token.field"]
        field.tap()
        field.typeText("uXyZ123token")
        connect.tap()

        // Task 11 inserted the card-selection step between the token screen
        // and the sync-depth choice.
        let cardsNext = app.buttons["cards.next"]
        XCTAssertTrue(cardsNext.waitForExistence(timeout: 5), "cards screen after the mock validation")
        cardsNext.tap()

        let depth = app.buttons["depth.3"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5), "depth screen after cards")
        depth.tap()

        let start = app.buttons["bank.connected.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        assertLive(start)
        start.tap()                                       // «Далі» → picker, not tabs

        // The connected screen no longer ends onboarding by itself — it
        // returns to the picker, which now offers «Готово» since at
        // least one bank (monobank) is connected.
        let finish = app.buttons["bank.done"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "«Готово» must appear now that monobank is connected")
        // Board #17: the word, not just the identifier. This is the ONLY way
        // out of onboarding and it is offered exactly when the user has
        // already done what onboarding asked — «Пропустити» told them their
        // finished setup was something they had skipped.
        XCTAssertEqual(finish.label, "Готово",
                       "the way out of onboarding must not call itself skipping")
        finish.tap()
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 3))

        // Board #60, now board #107's walkthrough. It runs HERE and not inside
        // onboarding: it points at the five tabs, and until this moment there
        // were no tabs to point at. **This is the only test that reaches it
        // the way a person does** — every other UI test passes
        // `-skipOnboarding`, which stamps it seen.
        //
        // What it teaches is `WalkthroughTests`' business. What matters here is
        // that a first run ends with something rather than in silence, and
        // that #17's rule survived the change of shape.
        let guide = app.otherElements["walkthrough.step.0"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5),
                      "a first run must end with the walkthrough, not in silence")

        // Board #17's rule, applied to a second control: the way out of a
        // thing somebody is allowed to be finished with must not tell them
        // they are missing something.
        let close = app.buttons["walkthrough.close"]
        XCTAssertTrue(close.exists)
        XCTAssertEqual(close.label, "Закрити")
        XCTAssertFalse(app.buttons["Пропустити"].exists)
        close.tap()

        XCTAssertFalse(guide.waitForExistence(timeout: 2), "«Закрити» must close it")
        // And it is done with: a tour that reappeared on every launch would
        // be the app not listening.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-noBiometrics", "-stubMonobank", "-lang", "uk"]
        again.launch()
        for d in "1111" { again.buttons["pin.key.\(d)"].tap() }
        XCTAssertTrue(again.tabBars.buttons["Головна"].waitForExistence(timeout: 5))
        XCTAssertFalse(again.otherElements["walkthrough.step.0"].waitForExistence(timeout: 2),
                       "the walkthrough must not come back once it has been closed")
    }

    func testRelaunchAfterOnboardingShowsTheLockNotOnboarding() {
        let app = launch()
        walkToTokenScreen(app)
        let field = app.secureTextFields["bank.token.field"]
        field.tap()
        // "t1" not "t": XCUITest's synthesized typeText only commits into the
        // SwiftUI binding once the keyboard leaves its starting letters page —
        // a bare letter never round-trips through Observation in this
        // simulator, and the guard then reports an empty token. Any input
        // that touches the digits page (as this one does) commits reliably.
        field.typeText("t1")
        app.buttons["bank.token.connect"].tap()

        let cardsNext = app.buttons["cards.next"]
        XCTAssertTrue(cardsNext.waitForExistence(timeout: 5), "cards screen after the mock validation")
        cardsNext.tap()

        XCTAssertTrue(app.buttons["depth.3"].waitForExistence(timeout: 5))
        app.buttons["depth.3"].tap()
        _ = app.buttons["bank.connected.start"].waitForExistence(timeout: 5)
        app.buttons["bank.connected.start"].tap()          // «Далі» → picker, not tabs

        let skip = app.buttons["bank.done"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "«Готово» must appear now that monobank is connected")
        skip.tap()
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 3),
                      "onboarding must actually finish before the relaunch assertion below can mean anything")

        // Second launch WITHOUT -resetState: persisted state must take over.
        let again = XCUIApplication()
        again.launchArguments = ["-noBiometrics", "-stubMonobank", "-lang", "uk"]
        again.launch()
        XCTAssertTrue(again.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        for d in "1111" { again.buttons["pin.key.\(d)"].tap() }
        XCTAssertTrue(again.tabBars.buttons["Головна"].waitForExistence(timeout: 3))
    }

    func testABadTokenIsRefusedAndNothingIsConnected() {
        let app = launch(extra: ["-stubMonobank", "fail403"])
        walkToTokenScreen(app)
        app.secureTextFields["bank.token.field"].tap()
        app.typeText("token1")
        app.buttons["bank.token.connect"].tap()
        assertLive(app.staticTexts["bank.token.error"])
        // The card-selection step (Task 11) is now the very next screen after
        // the token screen — a refused token must not reach it.
        XCTAssertFalse(app.buttons["cards.next"].waitForExistence(timeout: 2))
    }

    func testAGoodTokenReachesTheDepthScreenAndListsTheRealCards() {
        let app = launch(extra: ["-stubMonobank"])
        walkToTokenScreen(app)
        app.secureTextFields["bank.token.field"].tap()
        app.typeText("token1")
        app.buttons["bank.token.connect"].tap()

        // Task 11 inserted the card-selection step here: it must actually
        // list the real accounts, not merely offer a Далі button.
        let cardsNext = app.buttons["cards.next"]
        assertLive(cardsNext)
        XCTAssertTrue(app.buttons.matching(identifier: "cards.row").firstMatch.waitForExistence(timeout: 3),
                      "the cards screen must list the real accounts")
        cardsNext.tap()

        assertLive(app.buttons["depth.3"])
        app.buttons["depth.3"].tap()
        assertLive(app.staticTexts["bank.account"].firstMatch)
    }
}
