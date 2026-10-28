import XCTest

final class SettingsTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-skipOnboarding",
                               "-lang", "uk"] + extra
        app.launch()
        return app
    }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    /// Turn «Блокувати одразу» on. Call it standing on the Безпека screen.
    ///
    /// Board #21 gave a return inside a minute a grace period, so
    /// `press(.home)` + `activate()` — which two tests here used purely as a
    /// cheap way to reach the lock screen — no longer reaches it. This is the
    /// app's own answer to "ask me every time", and using it keeps those two
    /// tests testing what their names say instead of testing the grace.
    private func lockImmediately(_ app: XCUIApplication) {
        let toggle = app.switches["settings.lockImmediately"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

    func testChangePinRequiresTheOldOneAndTheNewOneUnlocks() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        lockImmediately(app)     // so the background round trip below reaches the lock
        app.buttons["settings.changePin"].tap()

        XCTAssertTrue(app.staticTexts["Поточний код"].waitForExistence(timeout: 3))
        type("9999", in: app)
        XCTAssertTrue(app.staticTexts["pin.message"].label.contains("Невірний"))
        usleep(500_000)   // the pad clears its dots 0.35 s after the shake; do not race it
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Новий код"].waitForExistence(timeout: 3))
        type("2222", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть новий код"].waitForExistence(timeout: 3))
        type("2222", in: app)
        XCTAssertTrue(app.staticTexts["Код змінено"].waitForExistence(timeout: 3))

        // Background → foreground re-locks; the new PIN must open it.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5))
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["pin.message"].label.contains("Невірний"))
        usleep(500_000)
        type("2222", in: app)
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 3))
    }

    func testFaceIdToggleIsDisabledWhenUnavailable() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        let toggle = app.switches["settings.faceid"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertFalse(toggle.isEnabled)
    }

    func testBanksListShowsMonobankAndDisconnectRemovesIt() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        let mono = app.buttons["banks.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 3))
        mono.tap()
        // By identifier, not by the card suffix itself — that is the owner's
        // real card, and it used to be spelled out here as a literal.
        XCTAssertTrue(app.staticTexts["bank.account"].firstMatch.waitForExistence(timeout: 3),
                      "the bank's accounts must be listed")
        app.buttons["bank.disconnect"].tap()
        app.buttons["bank.disconnect.confirm"].firstMatch.tap()
        XCTAssertFalse(app.buttons["banks.row.monobank"].waitForExistence(timeout: 2))
        assertLive(app.buttons["banks.add"])
    }

    /// **Board #157 — the choice the owner asked for.**
    ///
    /// «I think you need to ask the user when he deletes the bank whether to
    /// delete transactions as well.» Two named answers, neither preselected,
    /// and the cost stated BEFORE the tap rather than reported after it —
    /// board #148's shape, copied.
    func testDisconnectingABankOffersBothAnswersAndSaysWhatTheyCost() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()

        let keep = app.buttons["bank.disconnect.confirm"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bank.disconnect.withTransactions"].firstMatch.exists,
                      "the other answer must be offered, not implied")

        // The dialog may render as a POPOVER, in which case its texts are not
        // inside `app.sheets` — `StatementListTests` records why. Read the
        // count off the app instead.
        let counted = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Можна прибрати"))
        XCTAssertTrue(counted.firstMatch.exists, "the cost must be stated before the tap")
        let message = counted.firstMatch.label
        XCTAssertFalse(message.contains("операцій,"),
                       "Ukrainian takes three plural forms and 2-4 is «операції» — \(message)")
    }

    /// The destructive answer takes the bank's rows; the other one takes none.
    ///
    /// **Both halves in one walk**, because a test that only proved the
    /// removal would pass just as happily if BOTH buttons removed everything —
    /// which is exactly what a mis-wired dialog looks like.
    ///
    /// The demo seed is ONE bank with 772 rows, so removing monobank's
    /// transactions empties the app: `home.empty` is the signal, and it is the
    /// screen's own, not a count this test would have to keep in step.
    func testOnlyTheSecondAnswerRemovesTheTransactions() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()
        app.buttons["bank.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["banks.add"].waitForExistence(timeout: 3))

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["home.empty"].exists,
                       "«Відключити банк» alone must leave every transaction")
    }

    /// The other answer, walked separately: one app launch cannot disconnect
    /// the same bank twice.
    func testDisconnectingWithTransactionsEmptiesTheHistory() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()
        app.buttons["bank.disconnect.withTransactions"].firstMatch.tap()
        XCTAssertTrue(app.buttons["banks.add"].waitForExistence(timeout: 3))

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["home.empty"].waitForExistence(timeout: 5),
                      "the rows the bank delivered must be gone")
    }

    /// **Board #166 — the door stops locking behind the person.**
    ///
    /// The owner disconnected every bank and found their transactions still in
    /// the feed, the queue, Home and statistics, with nothing anywhere offering
    /// to remove them. The rows are theirs and stay by design (board #157, at
    /// their own request); what was broken is that «Відключити разом з
    /// операціями» lives on one screen, and `BanksSettingsView` listed only
    /// `connectedBanks` — so the choice was offered once, at the instant of
    /// disconnecting, and the only route back was «Скинути додаток».
    ///
    /// Walked end to end, because the value of this card is entirely in the
    /// route: the store already had `removeTransactions(ofBank:)`.
    func testADisconnectedBankStaysReachableUntilItsRowsAreGone() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()
        // The answer that KEEPS the history — the default, and the one the
        // owner took.
        app.buttons["bank.disconnect.confirm"].firstMatch.tap()

        let past = app.buttons["banks.past.monobank"]
        XCTAssertTrue(past.waitForExistence(timeout: 5),
                      "a disconnected bank that still owns rows must stay reachable")
        XCTAssertFalse(app.buttons["banks.row.monobank"].exists,
                       "it is past, not connected — the two sections do not overlap")
        past.tap()

        XCTAssertTrue(app.staticTexts["bank.past.status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bank.disconnect"].exists,
                       "a bank already off has nothing left to disconnect")
        // Caught by a screenshot, not by an assertion: this screen led with
        // «Картки» — balances frozen at the moment of disconnection, above live
        // toggles choosing which cards to download, for a bank that downloads
        // nothing. Same shape board #165 fixed on Home.
        XCTAssertFalse(app.staticTexts["bank.account"].firstMatch.exists,
                       "a disconnected bank has no live card list to offer")

        app.buttons["bank.past.removeRows"].tap()
        // An alert, not a dialog: board #170's lesson, so «Залишити» is on
        // screen beside the destructive answer rather than dropped by a popover.
        XCTAssertTrue(app.buttons["Залишити"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["bank.past.removeRows.confirm"].firstMatch.tap()

        // Nothing left to act on, so the section is gone — and the demo seed is
        // ONE bank, so the app is now empty, which is the owner's expectation
        // reached the honest way.
        XCTAssertTrue(app.buttons["banks.add"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["banks.past.monobank"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["home.empty"].waitForExistence(timeout: 5))
    }

    /// Reproduces the authentication bypass: the disconnect confirmation
    /// dialog is UIKit-presented above `RootView`'s ZStack, so it used to
    /// stay on screen — and tappable — over the lock overlay after the app
    /// re-locked in the background. `BankDetailView` must dismiss it as soon
    /// as `store.isUnlocked` goes false.
    func testDisconnectDialogClosesWhenAppLocks() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        lockImmediately(app)     // the bypass is about the LOCK; reach it deliberately
        app.navigationBars.buttons.firstMatch.tap()   // back to Налаштування
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()
        XCTAssertTrue(app.buttons["bank.disconnect.confirm"].firstMatch.waitForExistence(timeout: 3))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 5), "lock must be showing")
        XCTAssertFalse(app.buttons["bank.disconnect.confirm"].exists, "the confirm action must not survive behind the lock")
    }

    /// The route that did not exist. `SyncDepthView` was reachable only from
    /// onboarding, so a user who picked «1 місяць» and later wanted a year had
    /// exactly one way there: «Скинути додаток», which deletes the PIN, the
    /// token and every categorisation they have ever made. This test is what
    /// stops the row disappearing again without anyone noticing.
    func testSyncDepthIsReachableFromSettingsAndTheChoiceSticks() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.data"].tap()
        let row = app.buttons["settings.data.depth"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        assertLive(row)
        row.tap()

        let year = app.buttons["depth.12"]
        XCTAssertTrue(year.waitForExistence(timeout: 3), "the depth screen must open from Дані")
        // The starting point, asserted rather than assumed — without it the
        // check after the tap would pass against a screen that never changed.
        XCTAssertEqual(chosen(app, 3), "обрано", "3 місяці is the default")
        XCTAssertEqual(chosen(app, 12), "")
        assertLive(year)
        year.tap()

        // Choosing pops back to Дані…
        XCTAssertTrue(app.buttons["settings.data.export"].waitForExistence(timeout: 3),
                      "choosing a depth must return to Дані")
        // …and the app remembers it, which is the whole point of the route.
        app.buttons["settings.data.depth"].tap()
        XCTAssertTrue(app.buttons["depth.12"].waitForExistence(timeout: 3))
        XCTAssertEqual(chosen(app, 12), "обрано", "the new depth must be the one marked")
        XCTAssertEqual(chosen(app, 3), "")
    }

    /// The categorization log's switch, which is the consent gate for the
    /// only thing in the app that can send anything anywhere. Two halves that
    /// matter equally: it starts OFF on a fresh launch, and the address field
    /// and the export only exist once somebody has turned it on.
    ///
    /// Debug-only, like the card itself — a Release build has no such screen,
    /// and the UI suite only ever runs against Debug.
    func testTheCategorizationLogIsOffUntilTurnedOnAndThenOffersItsFile() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.data"].tap()

        let toggle = app.switches["settings.data.log.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        assertLive(toggle)
        XCTAssertEqual(toggle.value as? String, "0", "collection must start off")
        XCTAssertFalse(app.textFields["settings.data.log.webhook"].exists,
                       "nowhere to send anything until somebody opts in")
        XCTAssertFalse(app.buttons["settings.data.log.export"].exists)

        toggle.tap()

        XCTAssertTrue(app.textFields["settings.data.log.webhook"].waitForExistence(timeout: 3))
        // Both counts, because there are two logs behind this line — the
        // spending decisions and the receipt product groups — and a status
        // that quietly stopped reporting one of them would look identical.
        let status = app.staticTexts["settings.data.log.status"].label
        XCTAssertTrue(status.contains("0 покупок"), "a fresh log has nothing in it: " + status)
        XCTAssertTrue(status.contains("0 товарів"), "the product log is reported too: " + status)
        // Expanding the card pushes its buttons past the fold; `assertLive`
        // means hittable, so the screen has to be scrolled first. Safe here
        // in a way it is not in a sheet — this is a `ScrollView`, and a swipe
        // on a sheet's list dismisses it.
        app.swipeUp()
        assertLive(app.buttons["settings.data.log.export"])
        assertLive(app.buttons["settings.data.log.clear"])

        // Left as it was found. `-resetState` now erases the switch too, so
        // this is belt and braces rather than the only thing standing between
        // this test and the next one.
        app.swipeDown()
        let again = app.switches["settings.data.log.toggle"]
        XCTAssertTrue(again.waitForExistence(timeout: 3))
        again.tap()
        XCTAssertEqual(again.value as? String, "0")
    }

    /// `accessibilityValue` on the depth row: «обрано» for the current choice,
    /// empty for the rest. The checkmark itself is drawn at `.opacity(0)` when
    /// unselected, and XCUITest cannot tell that from visible.
    private func chosen(_ app: XCUIApplication, _ months: Int) -> String {
        (app.buttons["depth.\(months)"].value as? String) ?? ""
    }

    /// Disconnect, then add the same bank back from Настройки.
    ///
    /// **Board #22 put the card selection into the middle of this walk.** It
    /// went token → «Підключено», skipping the «Які картки синхронізувати?»
    /// that onboarding always shows — so a second card was enrolled without
    /// anybody being asked, on the same connection, differing only in where it
    /// was made from. The step is asserted here rather than merely walked
    /// through: skipping it again would otherwise leave this test green.
    ///
    /// The other half of #22 — that the run starts here instead of waiting for
    /// the next app activation — is guarded in pytest. A reconnect re-reads
    /// windows the app has already seen, so a sync that starts brings no new
    /// rows to look at.
    func testAddBankFromSettingsAsksWhichCardsAndReconnects() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.monobank"].tap()
        app.buttons["bank.disconnect"].tap()
        app.buttons["bank.disconnect.confirm"].firstMatch.tap()

        app.buttons["banks.add"].tap()
        // Board #19 applies to the settings picker too, not just onboarding.
        app.buttons["bank.row.monobank"].tap()
        let field = app.secureTextFields["bank.token.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // A bare-letter string never round-trips through the SwiftUI binding
        // on this simulator's keyboard (see OnboardingTests) — it only commits
        // once typing visits the digits page, hence "again1" not "again".
        field.tap(); field.typeText("again1")
        app.buttons["bank.token.connect"].tap()

        XCTAssertTrue(app.staticTexts["Які картки синхронізувати?"].waitForExistence(timeout: 10),
                      "the card selection must not be skipped just because this is Settings")
        assertLive(app.buttons["cards.next"])
        app.buttons["cards.next"].tap()

        let done = app.buttons["bank.connected.start"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["banks.row.monobank"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["banks.row.monobank"].label.contains("картк"),
                      "the row must show the cards it came back with: \(app.buttons["banks.row.monobank"].label)")
    }

    /// Board #11: the rules the app taught itself, listed and retractable.
    ///
    /// No merchant is named anywhere in this test. Every rule the demo ships is
    /// keyed by a merchant off the owner's own statement, so naming one would
    /// put it in Swift source — which the privacy guard refuses, correctly. The
    /// rows are found by the prefix of their identifier instead, which is also
    /// what keeps this green when the seed's rules change shape again.
    private func openRules(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.categories"].tap()
        XCTAssertTrue(app.marker("settings.categories").waitForExistence(timeout: 3))
        app.buttons["settings.open.rules"].tap()
        XCTAssertTrue(app.marker("settings.rules").waitForExistence(timeout: 3))
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.rules.row.'"))
    }

    /// Board #81's acceptance line: one merchant, two rules, and the screen
    /// says which kind each is about.
    ///
    /// Without the qualifier the two rows are identical but for their answer —
    /// the same merchant name above «Техніка» and above «Зарплата» — and the
    /// screen reads as the app contradicting itself. The seed cannot produce
    /// the state (no merchant has a pending row of both kinds), hence
    /// `-twoKindRules`; see `Launch`.
    func testAMerchantWithARulePerKindSaysWhichRowIsWhich() {
        let app = launch(["-twoKindRules"])
        let rows = openRules(app)

        XCTAssertEqual(rows.count, 3, "two rules must be two rows, not one id drawn twice")

        let scopes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.rules.scope.'"))
        XCTAssertEqual(scopes.count, 2, "each of the shared merchant's rows says which kind")
        assertLive(app.staticTexts["для витрат"].firstMatch)
        assertLive(app.staticTexts["для надходжень"].firstMatch)
        assertLive(app.staticTexts["Техніка"].firstMatch)
        assertLive(app.staticTexts["Зарплата"].firstMatch)
    }

    /// The other half, and the reason the qualifier is conditional: a merchant
    /// with one rule gains nothing from being told it applies to spending. It
    /// would read as a limitation the person never chose.
    ///
    /// **Same fixture as the test above, deliberately.** Run against the plain
    /// seed this proved nothing: all five of `demo.json`'s rules are unscoped,
    /// `scopeNote` returns nil for every one of them, and "no qualifier
    /// appeared" was true however the condition was written — forcing it
    /// permanently on left the test green. `-twoKindRules` plants a lone
    /// SCOPED rule beside the shared merchant so exactly two qualifiers are
    /// possible and the third row's silence is a decision.
    func testAMerchantWithOneRuleIsNotQualifiedEvenWhenItsRuleIsScoped() {
        let app = launch(["-twoKindRules"])
        let rows = openRules(app)
        XCTAssertEqual(rows.count, 3, "precondition: two shared rules and one lone scoped rule")

        let scopes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.rules.scope.'"))
        XCTAssertEqual(scopes.count, 2,
                       "the lone rule is scoped and still says nothing — three would mean it did")
        XCTAssertEqual(app.staticTexts.matching(identifier: "для витрат").count, 1,
                       "only the shared merchant's spending row is qualified")
    }

    func testTheRulesScreenListsWhatTheAppHasLearnedAndCanForgetOne() {
        let app = launch()
        let rows = openRules(app)
        let before = rows.count
        XCTAssertGreaterThan(before, 0, "the demo seed ships rules; the screen must show them")

        // Two of the seeded rules are keyed by a merchant `applyingRule`
        // refuses on sight, and the screen has to say so rather than present
        // them as working.
        let inert = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.rules.inert.'"))
        XCTAssertGreaterThan(inert.count, 0,
                             "a rule that can never fire must be marked, not listed as live")

        let first = rows.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.swipeLeft()
        let forget = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'settings.rules.forget.'")).firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 3))
        forget.tap()
        app.buttons["settings.rules.forgetConfirm"].firstMatch.tap()

        // One fewer rule, and the row is gone rather than merely re-labelled.
        var after = rows.count
        for _ in 0..<10 where after == before {
            usleep(200_000)
            after = rows.count
        }
        XCTAssertEqual(after, before - 1)
    }

    /// Forgetting a rule is a statement about future rows. Nothing already
    /// sorted moves — the store half is pinned by
    /// `testForgettingARuleLeavesEveryRowItAlreadyDecidedExactlyAsItWas`; this
    /// is the promise the screen makes to the person before they tap.
    func testForgettingARuleSaysWhatSurvivesBeforeItHappens() {
        let app = launch()
        let rows = openRules(app)
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 3))
        let before = rows.count
        rows.element(boundBy: 0).swipeLeft()
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'settings.rules.forget.'")).firstMatch.tap()

        let warning = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'залишаться як є'")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 3),
                      "the dialog must say the already-sorted rows stay put")

        // Dismissed by tapping outside it, not by a «Скасувати» button: this
        // renders as a popover-style dialog whose only button is the
        // destructive one, and its cancel is the tap-away. Asserting the count
        // afterwards is what makes backing out mean something.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertFalse(warning.waitForExistence(timeout: 2))
        XCTAssertEqual(rows.count, before, "backing out of the dialog must forget nothing")
    }

    // MARK: the guide, re-opened (board #60)

    /// The half a person actually needs later: they read it once, closed it,
    /// and now want it back. Under «Про додаток», which is already the screen
    /// answering "what is this and what does it do".
    ///
    /// This launch passes `-skipOnboarding`, so the guide has been stamped
    /// seen — which is exactly the state this test wants, and is why it can
    /// assert the sheet was raised by the ROW rather than by the first run.
    func testTheGuideCanBeOpenedAgainFromAboutAndDoesNotAppearOnItsOwn() {
        let app = launch()
        XCTAssertFalse(app.otherElements["guide.title"].waitForExistence(timeout: 2),
                       "precondition: a run that has already seen it opens clean")

        app.buttons["home.settings"].tap()
        app.buttons["settings.open.about"].tap()
        let row = app.buttons["about.guide"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        assertLive(row)
        row.tap()

        XCTAssertTrue(app.otherElements["guide.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Операції приходять самі"].exists,
                      "it must reopen at the first page, not where it was left")
        app.buttons["guide.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "closing must land back on Про додаток")
    }

    /// «Про додаток» said the budget and fiscal receipts were not built, two
    /// taps from a guide that explains both. The card that added the guide is
    /// the one that had to reconcile them.
    func testAboutNoLongerCallsShippedFeaturesUnbuilt() {
        let app = launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.about"].tap()
        XCTAssertTrue(app.staticTexts["Що вже справжнє"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Що ще ні"].exists,
                       "nothing on that list is still missing")
        XCTAssertTrue(app.staticTexts["Бюджет за частками доходу"].exists)
    }

    // MARK: appearance (board #58)

    /// Three states, the default one selected, and the choice surviving a
    /// relaunch — which is the half that would rot silently, since a picker
    /// that forgets still looks right for the rest of the session.
    func testTheAppearanceChoiceIsOfferedAndRemembered() {
        let app = launch()
        app.buttons["home.settings"].tap()

        let picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.swipeUp()                       // the card sits below the five rows
        assertLive(picker)

        let system = picker.buttons["Як у системі"]
        XCTAssertTrue(system.isSelected, "a fresh install must follow the phone")
        XCTAssertTrue(picker.buttons["Світла"].exists)

        let dark = picker.buttons["Темна"]
        assertLive(dark)
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        XCTAssertFalse(system.isSelected)

        // Relaunch WITHOUT -resetState, or the choice would be wiped along
        // with everything else and this would prove nothing.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-lang", "uk"]
        again.launch()
        again.buttons["home.settings"].tap()
        let reopened = again.segmentedControls["settings.appearance"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        again.swipeUp()
        XCTAssertTrue(reopened.buttons["Темна"].isSelected,
                      "the appearance must survive a relaunch")

        // Put it back, so a shared simulator does not hand the next test in
        // the run an app in a scheme it did not ask for.
        reopened.buttons["Як у системі"].tap()
    }

    // MARK: a file that could not be read (board #68)

    /// The card's second criterion — "a corrupt file is noticed by somebody" —
    /// and the only way to reach the state from a test: `-corruptFile` plants
    /// valid JSON of the wrong shape before `AppStore.init` runs.
    ///
    /// The warning has to be visible from the settings ROOT, not only inside
    /// Дані. Somebody whose history has gone quiet has no reason to go
    /// looking in a screen labelled «Експорт і скидання», so a card buried one
    /// level down is not noticing — it is a record for whoever already knows.
    func testAFileThatCouldNotBeReadIsSaidSoOnTheSettingsRootAndExplainedInside() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-skipOnboarding", "-corruptFile", "transactions", "-lang", "uk"]
        app.launch()

        app.buttons["home.settings"].tap()
        let data = app.buttons["settings.open.data"]
        XCTAssertTrue(data.waitForExistence(timeout: 5))
        XCTAssertTrue(data.label.contains("Не вдалося прочитати"),
                      "the settings root must say something is wrong: " + data.label)
        XCTAssertTrue(data.label.contains("Помилка"),
                      "…and say it as a warning, not only as a colour: " + data.label)

        data.tap()
        XCTAssertTrue(app.marker("settings.data.loadFailures").waitForExistence(timeout: 3),
                      "Дані must explain which data and what happened to it")

        // Read off the text rather than the container's merged label: a
        // `Card` stamps its identifier onto its descendants, so `firstMatch`
        // is whichever of them the tree yields — an assertion on ITS label
        // would be an assertion about tree order (board #24).
        func says(_ phrase: String) -> Bool {
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", phrase)).firstMatch.exists
        }
        XCTAssertTrue(says("операції"), "the app's own word for the file, not its storage key")
        XCTAssertFalse(says("transactions"),
                       "a storage key is not a report anybody can act on")
        XCTAssertTrue(says("не перезаписано"),
                      "the one reassurance here that is actually true")
        XCTAssertTrue(says("Не скидайте"),
                      "…and the one action that would destroy what is left")
    }

    /// The other half, and the one that would rot silently: an ordinary launch
    /// must say NOTHING. A warning every fresh install saw would be worse than
    /// no warning at all.
    func testAnOrdinaryLaunchSaysNothingAboutUnreadableData() {
        let app = launch()
        app.buttons["home.settings"].tap()
        let data = app.buttons["settings.open.data"]
        XCTAssertTrue(data.waitForExistence(timeout: 5))
        XCTAssertEqual(data.label, "Дані, Експорт і скидання",
                       "no warning word, and no warning icon announced either")

        data.tap()
        XCTAssertTrue(app.buttons["settings.data.export"].waitForExistence(timeout: 3),
                      "precondition: Дані really did open")
        XCTAssertFalse(app.otherElements["settings.data.loadFailures"].exists)
    }
}
