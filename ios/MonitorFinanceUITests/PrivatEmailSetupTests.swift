import XCTest

/// Board #91 — the screens that make board #90's email source reachable.
///
/// `PrivatEmailSyncTests` already proves a letter reaches the feed through the
/// ordinary activation trigger. This is the other half: that a person can get
/// the address, see the forwarding code, and disconnect again — none of which
/// existed while #90's client had no UI at all.
final class PrivatEmailSetupTests: XCTestCase {
    /// The state a real registration leaves: credentials in the Keychain and
    /// PrivatBank flagged connected. `-noDemoData` because
    /// `syncPrivatEmailIfConnected` refuses to run against a bundled dataset,
    /// and `-stubStatementDelay 600` for the same reason `EmptyStateTests`
    /// raises it — monobank's own stub must not answer inside these tests.
    private func connected() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail",
                               "-stubStatementDelay", "600"]
        return app
    }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    /// The whole point of the card: a first-run person reaches the address and
    /// the forwarding confirmation code without leaving the app.
    @MainActor
    func testOnboardingCanConnectEmailAndSeesTheConfirmationCode() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-noGuide", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail"]
        app.launch()

        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let privat = app.buttons["bank.row.privatbank"]
        XCTAssertTrue(privat.waitForExistence(timeout: 5))
        privat.tap()

        let email = app.buttons["privat.source.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5),
                      "PrivatBank must offer letters beside the statement import")
        assertLive(email)
        email.tap()

        // Board #113: arriving offers, it does not act. The address cannot
        // exist yet, because nothing has been created yet.
        let connect = app.buttons["email.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5),
                      "the screen must offer to create the address, not create it")
        XCTAssertFalse(app.staticTexts["email.address"].exists,
                       "an address on screen here means an account was minted by arriving")
        assertLive(connect)
        connect.tap()

        // The stub's invented address, which can only be on screen if a
        // registration went through the store to get here.
        let address = app.staticTexts["email.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10),
                      "registering must put the issued address on screen")
        XCTAssertEqual(address.label, "u-stub@in.example.test")

        // The forwarding code is the half a person cannot reach any other way:
        // the letter carrying it is delivered to an address only the backend
        // can read.
        XCTAssertTrue(app.staticTexts["email.confirmation"].waitForExistence(timeout: 10),
                      "the forwarding confirmation letter must be shown in full")

        let done = app.buttons["email.done"]
        assertLive(done)
        done.tap()

        // Back on the picker with the bank now connected — so onboarding's exit
        // is offered, which is the flip `registerPrivatEmail` performs and the
        // only visible proof it happened.
        let finish = app.buttons["bank.done"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5),
                      "connecting email must flag the bank connected, the way an import does")
        finish.tap()
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 5))
    }

    /// **Board #113, the owner's own words:** «I didn't add the mail, I just
    /// clicked done, and the mail is already tied.» This walks that exact path
    /// and asserts the opposite.
    ///
    /// The proof is an ABSENCE, and it has to be one the app cannot fake: the
    /// picker's «Готово» appears only when some bank is connected, and flagging
    /// PrivatBank connected is precisely what a successful `registerPrivatEmail`
    /// does. The test above uses that same flip as its proof that an account WAS
    /// created — so the two read the same signal in opposite directions, and no
    /// change can satisfy both while breaking the feature.
    @MainActor
    func testArrivingAtTheEmailScreenAndLeavingCreatesNothing() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-noGuide", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail"]
        app.launch()

        app.startOnboarding()
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let privat = app.buttons["bank.row.privatbank"]
        XCTAssertTrue(privat.waitForExistence(timeout: 5))
        privat.tap()

        // The source choice is a destination, not a confirmation — it has always
        // created nothing. Passing through it is half the card's first criterion.
        let email = app.buttons["privat.source.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()

        XCTAssertTrue(app.buttons["email.connect"].waitForExistence(timeout: 5),
                      "the screen must be offering, which is what makes leaving free")

        // «Далі» — the tap the owner made. Not the back gesture: a person who
        // reads a screen and moves on has not agreed to anything either.
        let done = app.buttons["email.done"]
        assertLive(done)
        done.tap()

        XCTAssertTrue(privat.waitForExistence(timeout: 5), "«Далі» returns to the picker")
        XCTAssertFalse(app.buttons["bank.done"].exists,
                       "no bank is connected, so onboarding has no exit to offer — "
                       + "«Готово» here means an account was created by a screen appearing")
    }

    /// The other half of the card: a device that already has an account is
    /// **not asked a second time**. A consent screen that reappears on every
    /// visit is a consent screen people learn to tap through.
    @MainActor
    func testAConnectedDeviceIsNeverAskedToConsentAgain() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        // `-stubPrivatEmail` seeds the Keychain, so this device is registered
        // before the first frame — the state a returning person is in.
        XCTAssertTrue(app.staticTexts["bank.email.address"].waitForExistence(timeout: 5))

        // Board #158: «Відключити пошту» keeps the address now, so reaching a
        // genuinely unconnected state takes the one button that ends one.
        app.buttons["bank.email.changeAddress"].tap()
        app.buttons["bank.email.changeAddress.confirm"].firstMatch.tap()

        // The old address is gone, so this visit gets the offer…
        let offer = app.buttons["email.connect"]
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        offer.tap()
        XCTAssertTrue(app.staticTexts["email.address"].waitForExistence(timeout: 10))

        // …and the next one does not. Leaving and coming back must land on the
        // address, with nothing left to agree to.
        app.buttons["email.done"].tap()
        XCTAssertTrue(app.buttons["banks.row.privatbank"].waitForExistence(timeout: 5))
        app.buttons["banks.row.privatbank"].tap()
        XCTAssertTrue(app.staticTexts["bank.email.address"].waitForExistence(timeout: 5),
                      "the account survived, so the bank screen names its address")
        XCTAssertFalse(app.buttons["bank.email.connect"].exists,
                       "a connected device must not be offered the connection again")
    }

    /// Settings' side of the same connection: the section exists, names the
    /// address, and offers the check.
    @MainActor
    func testTheBankScreenShowsTheEmailConnection() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        let row = app.buttons["banks.row.privatbank"]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "an email-connected PrivatBank belongs in Банки")
        row.tap()

        let address = app.staticTexts["bank.email.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.label, "u-stub@in.example.test")
        assertLive(app.buttons["bank.email.check"])
    }

    /// Disconnecting is the decision this card made explicit: the server
    /// account goes with it, and the screen said so first.
    @MainActor
    func testDisconnectingEmailKeepsTheAddressAndOffersToResume() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let address = app.staticTexts["bank.email.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let issued = address.label

        let disconnect = app.buttons["bank.email.disconnect"]
        disconnect.tap()
        app.buttons["bank.email.disconnect.confirm"].firstMatch.tap()

        // Board #158 turned this test's assertion inside out. It used to
        // require «Підключити пошту» here — proof the account had been
        // deleted. That was the behaviour the owner asked us to remove: the
        // address cannot be reissued, so losing it is not recoverable.
        XCTAssertEqual(app.staticTexts["bank.email.address"].label, issued,
                       "a disconnect must not change the address")
        XCTAssertFalse(app.buttons["bank.email.connect"].exists,
                       "nothing was disconnected in the sense that word used to mean")
        XCTAssertEqual(app.staticTexts["bank.email.status"].label,
                       "Імпорт вимкнено. Адреса жива й далі приймає листи.")

        let resume = app.buttons["bank.email.disconnect"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        assertLive(resume)
        resume.tap()
        app.buttons["bank.email.disconnect.confirm"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["bank.email.address"].label, issued,
                       "resuming reuses the same address, with no registration")
    }

    // MARK: - Board #170 — ending the mailbox on purpose

    /// The gap board #168 left: «Змінити адресу» swaps one address for another
    /// and «Відключити пошту» pauses, so a person giving the phone away could
    /// not end their mailbox at all. Now they can, from the screen that already
    /// owns deliberate acts on the address.
    ///
    /// **An `.alert`, not a `.confirmationDialog`, and a screenshot is why** —
    /// the dialog rendered as a popover, where iOS drops the cancel button and
    /// the only answer on screen was the red one. On a permanent deletion.
    @MainActor
    func testTheAddressCanBeDeletedForGoodFromTheMailScreen() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        XCTAssertTrue(app.staticTexts["bank.email.address"].waitForExistence(timeout: 5))

        // The cost is on the screen BEFORE the tap, not only inside the
        // confirm: a consequence somebody reads after choosing is not what let
        // them choose.
        XCTAssertTrue(app.staticTexts["bank.email.deleteAddress.cost"].exists)

        let delete = app.buttons["bank.email.deleteAddress"]
        assertLive(delete)
        delete.tap()

        // Both answers, and the safe one reachable — the whole reason this is
        // an alert. A popover would have shown «Видалити» alone.
        XCTAssertTrue(app.buttons["bank.email.deleteAddress.confirm"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Скасувати"].firstMatch.exists,
                      "an irreversible action must offer a way out of its own confirm")
        app.buttons["bank.email.deleteAddress.confirm"].firstMatch.tap()

        // No address, and the offer that follows is an ordinary FIRST one:
        // board #111's «Ключ до адреси не зберігся» describes a phone that lost
        // its secret, and this phone did not lose anything — it ended it.
        XCTAssertTrue(app.buttons["bank.email.connect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["bank.email.address"].exists)
        XCTAssertEqual(app.staticTexts["bank.email.status"].label, "Не підключено")
    }

    /// Board #158's shape, restored by #170: a request that fails **asks**
    /// rather than proceeding anyway, and the escape it offers is the one that
    /// matches the action — «видати нову адресу» is no answer at all to
    /// somebody who asked for none.
    @MainActor
    func testAFailedDeleteOffersTheLocalOnlyEscapeAndNamesItsCost() {
        // Built rather than appended: `Launch.emailStubMode` reads the FIRST
        // `-stubPrivatEmail`, so a second one appended to `connected()`'s
        // arguments is silently ignored and the test would run against `ok`.
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "offline",
                               "-stubStatementDelay", "600"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        XCTAssertTrue(app.staticTexts["bank.email.address"].waitForExistence(timeout: 5))

        app.buttons["bank.email.deleteAddress"].tap()
        app.buttons["bank.email.deleteAddress.confirm"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["bank.email.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bank.email.address"].exists,
                      "nothing local may change until the person answers")

        let escape = app.buttons["bank.email.forgetAnyway"]
        XCTAssertTrue(escape.exists)
        XCTAssertEqual(escape.label, "Видалити лише з телефона",
                       "the offer follows the action that failed")
        XCTAssertTrue(app.staticTexts["bank.email.forgetAnyway.cost"].exists,
                      "the orphan it leaves is named before it is taken")

        escape.tap()
        XCTAssertTrue(app.buttons["bank.email.connect"].waitForExistence(timeout: 5))
    }

    // MARK: - Board #145 — PrivatBank emails a link, not a file

    /// The person meets the link, sees where it goes, and can put it away.
    ///
    /// **What is NOT here is the point:** no button fetches anything. The app
    /// opens the URL in the system browser and stops, so the card's constraint
    /// — «check that if anything no other links are torn off» — is met by
    /// there being no fetcher on either side rather than by guarding one.
    func testAStatementLinkIsOfferedWithItsHostAndCanBeDismissed() {
        let app = connected()
        app.launchArguments += ["-stubStatementLink"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let host = app.first(withPrefix: "bank.statementLink.host")
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        XCTAssertFalse(host.label.isEmpty,
                       "the person has to see WHERE the link goes, not just that one exists")
        XCTAssertTrue(app.buttons["bank.statementLink.open"].exists)

        app.buttons["bank.statementLink.dismiss"].tap()
        XCTAssertFalse(host.waitForExistence(timeout: 5),
                       "a dismissed link must stop being offered")
    }

    /// **Board #171 — «just ask whether to download it to the application or
    /// not».** The owner's own sentence, and the ask is the design: nothing is
    /// fetched on arrival and nothing sweeps in the background, so this button
    /// is the only thing that follows a link.
    @MainActor
    func testALinkCanBeDownloadedIntoTheAppAndImports() {
        let app = connected()
        app.launchArguments += ["-stubStatementLink"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        XCTAssertTrue(app.first(withPrefix: "bank.statementLink.host").waitForExistence(timeout: 10))
        let download = app.first(withPrefix: "bank.statementLink.download")
        assertLive(download)

        // The manual route is still there, and still reachable. A link the
        // server cannot follow is worth opening by hand — the person may have
        // a Privat24 session the server does not — so the automatic path must
        // not replace the fallback.
        XCTAssertTrue(app.buttons["bank.statementLink.open"].exists,
                      "the fallback must survive the feature that makes it rarer")

        download.tap()

        // Gone because it landed: the card is dropped only on success, so a
        // failure would leave it here with «Відкрити посилання» underneath.
        XCTAssertFalse(app.first(withPrefix: "bank.statementLink.host").waitForExistence(timeout: 15),
                       "a downloaded link stops being offered")
        XCTAssertFalse(app.staticTexts["bank.statementLink.error"].exists)

        // And it reached the parser, not just the disk. The statement stub
        // carries real xlsx bytes, so «Виписки» listing it means
        // `importPrivatStatement` ran.
        XCTAssertTrue(app.staticTexts["bank.statement.name"].firstMatch.waitForExistence(timeout: 10),
                      "the fetched file has to arrive as an ordinary imported statement")
    }

    // MARK: - Board #174 — the screen stops being a setup guide

    /// **The complaint, made measurable.** The owner: «Make the Privat Bank
    /// settings more understandable, because they are too confusing, there are
    /// a lot of things.»
    ///
    /// The screen's length did not change as the person succeeded: walls of
    /// instructions stood above the one card that says whether any of it
    /// worked, at the same size on the hundredth visit as on the first. So the
    /// thing a returning person came to see was the thing they had to scroll
    /// past everything else to reach.
    @MainActor
    func testAWorkingMailboxShowsStatusAndFoldsTheSetupAway() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        // Status is here without scrolling; the instructions are not on screen
        // at all until asked for.
        let status = app.staticTexts["email.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertEqual(status.label, "Листи надходять")
        XCTAssertFalse(app.staticTexts["email.file.instructions"].exists,
                       "a mailbox that demonstrably works does not need the setup guide")

        // **A default, not a lock.** Somebody whose letters stopped has to be
        // able to re-read exactly the instructions their own success hid.
        let toggle = app.buttons["email.instructions.toggle"]
        assertLive(toggle)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["email.file.instructions"].waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(app.staticTexts["email.file.instructions"].exists,
                       "and closable again")

        // The address is visible and copyable in every state — the one thing
        // on this screen a person genuinely needs to get out of the app, and
        // board #168 made it permanent for the life of the phone.
        XCTAssertTrue(app.staticTexts["email.address"].exists)
        XCTAssertTrue(app.buttons["email.copy"].exists)
    }

    /// The other half: **while nothing has arrived, the guide is what the
    /// screen is for.** Folding it away by default would hide the instructions
    /// from the only person who needs them.
    @MainActor
    func testAMailboxWithNoLettersLeadsWithTheInstructions() {
        let app = XCUIApplication()
        // No `-stubPrivatEmail` rows to import: `-stubNoStatementRoute` keeps
        // the statement calls quiet, and `-emptyReceiptSample` is irrelevant
        // here — what matters is that no letter has landed.
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "offline",
                               "-stubStatementDelay", "600"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        XCTAssertTrue(app.staticTexts["email.file.instructions"].waitForExistence(timeout: 15),
                      "nothing has arrived, so the guide is exactly what this screen is for")
        XCTAssertEqual(app.staticTexts["email.status"].label, "Листів ще немає")
    }

    // MARK: - Board #175 — the last few letters

    /// **The whole point: «нічого не прийшло» and «прийшло й не зрозуміли»
    /// stop looking identical.**
    ///
    /// The owner: «I think you can briefly show the last 2-3 letters, not all
    /// of them, but part of the flood that come to the mail from Privat Bank.»
    /// Today a letter that arrived and failed to parse shows up as a count
    /// that simply did not move — indistinguishable from one that never came,
    /// and those two want completely different actions.
    @MainActor
    func testTheLastFewLettersAreShownWithWhatBecameOfEach() {
        let app = connected()
        app.launchArguments += ["-stubRecentLetters"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        let outcomes = app.staticTexts.matching(identifier: "email.recent.outcome")
        XCTAssertTrue(outcomes.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(outcomes.count, 3, "a window, not a mailbox")

        let labels = (0..<outcomes.count).map { outcomes.element(boundBy: $0).label }
        XCTAssertTrue(labels.contains("операція додана"))
        XCTAssertTrue(labels.contains("не вдалося прочитати"),
                      "the state this list exists for must be visible, and named")
        XCTAssertTrue(labels.contains("не банківський лист"))

        // Subjects are the person's own data, so they render verbatim — the
        // stub's are invented, and that is what makes asserting on one safe.
        let subjects = app.staticTexts.matching(identifier: "email.recent.subject")
        XCTAssertEqual(subjects.count, 3)
    }

    /// **«Листів ще немає» is a complete answer**, and replacing it with an
    /// empty list would turn a sentence somebody can read into a shape they
    /// have to interpret. Without this, a section that always rendered would
    /// pass the test above.
    @MainActor
    func testNothingIsListedWhenNoLetterArrived() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        XCTAssertTrue(app.staticTexts["email.status"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(identifier: "email.recent.outcome").firstMatch.exists,
                       "no letters means no list, not an empty one")
    }

    /// Nothing appears when nothing arrived. Without this, a card that always
    /// rendered would pass the test above and put a permanent "your statement
    /// is waiting" on a screen where none is.
    func testNoLinkCardWhenNoLinkArrived() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        XCTAssertTrue(app.staticTexts["bank.email.address"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.first(withPrefix: "bank.statementLink.host").exists)
    }

    /// Board #112 — «no way to change the mail», and there was a way: the
    /// destructive one.
    ///
    /// `PrivatEmailSetupView` has always drawn everything needed to redo a
    /// forwarding rule. It was simply **unreachable** once connected and
    /// healthy: the section pushed `.emailSetup` from the not-connected branch
    /// and from the dead-secret branch, and from nowhere else. So the only
    /// visible way to touch the email setup again was «Відключити пошту».
    ///
    /// **The address surviving the round trip is the whole assertion.** It is
    /// what separates the answer this card chose — show the setup again for
    /// the address you already have — from the disconnect-and-reconnect
    /// reading it rejected, which would come back with a different one.
    @MainActor
    func testTheForwardingInstructionsCanBeReopenedWithoutDisconnecting() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let before = app.staticTexts["bank.email.address"]
        XCTAssertTrue(before.waitForExistence(timeout: 5))
        let issued = before.label

        let instructions = app.buttons["bank.email.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5),
                      "a connected, working email must still offer its setup instructions")
        assertLive(instructions)
        instructions.tap()

        // The setup screen, in its connected shape: the address and the
        // forwarding steps, and no offer to create anything (board #113).
        let onSetup = app.staticTexts["email.address"]
        XCTAssertTrue(onSetup.waitForExistence(timeout: 5),
                      "the instructions screen must show the address it is instructing about")
        XCTAssertEqual(onSetup.label, issued)
        XCTAssertFalse(app.buttons["email.connect"].exists,
                       "arriving here from a connected bank must offer nothing to create")
        XCTAssertTrue(app.buttons["email.copy"].exists,
                      "redoing a forwarding rule starts by copying the address")

        app.buttons["email.done"].tap()
        app.buttons["banks.row.privatbank"].tap()
        let after = app.staticTexts["bank.email.address"]
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertEqual(after.label, issued,
                       "reopening the instructions must not have minted a new address — "
                       + "that is the destructive path this card exists to avoid")
    }

    /// The consequence of each choice, on screen BEFORE the tap.
    ///
    /// The pair is the point: one address stays, the other does not. The
    /// confirmation dialog already said the second half, but a consequence
    /// somebody reads after choosing is not what let them choose.
    @MainActor
    func testEachEmailActionSaysWhatItCosts() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let keeps = app.staticTexts["bank.email.instructions.cost"]
        XCTAssertTrue(keeps.waitForExistence(timeout: 5))
        XCTAssertEqual(keeps.label, "Адреса залишиться та сама.")

        // Board #158. The disconnect is no longer the destructive one, so its
        // caption no longer claims a cost it does not have — and the caption
        // that DOES carry one moved to «Змінити адресу», which is now the only
        // thing that ends an address.
        let costs = app.staticTexts["bank.email.disconnect.cost"]
        XCTAssertTrue(costs.exists)
        XCTAssertEqual(costs.label,
                       "Адреса залишиться вашою й далі прийматиме листи. Пересилання можна не чіпати.")

        let change = app.staticTexts["bank.email.changeAddress.cost"]
        XCTAssertTrue(change.exists,
                      "the destructive action must say so where it is offered")
        XCTAssertEqual(change.label,
                       "Стара адреса перестане приймати листи. Пересилання у своїй пошті доведеться перенаправити.")

        // Board #170. The card's second destructive answer, and the caption is
        // what separates it from the one above: «Змінити адресу» leaves this
        // phone with a working mailbox, and this one does not.
        let delete = app.staticTexts["bank.email.deleteAddress.cost"]
        XCTAssertTrue(delete.exists)
        XCTAssertEqual(delete.label,
                       "Пошта вимкнеться, і цієї адреси більше не буде. Нова, якщо колись знадобиться, буде інша.")
        XCTAssertNotEqual(delete.label, change.label,
                          "two red buttons a row apart must not read the same — "
                          + "that is the shape board #168's screenshot rejected")
    }

    // MARK: - Board #111 — a new address is never issued silently

    /// **The state a restore onto a new phone leaves**, and the one the app
    /// used to describe as a first-time setup.
    ///
    /// The secret is stored `…ThisDeviceOnly`, which is deliberately excluded
    /// from backups and iCloud Keychain, so a restore brings `sync.json` back
    /// without it. Before this card that was indistinguishable from a fresh
    /// install: the bank read «Не підключено», the button said «Підключити
    /// пошту», and one tap replaced the address in silence — while the
    /// forwarding rule in the person's own mailbox went on sending to the dead
    /// one. Sync simply stopped, with nothing anywhere saying why.
    @MainActor
    func testAPhoneThatLostItsKeyIsToldTheNextAddressWillBeDifferent() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "-emailKeyLost",
                               "-stubStatementDelay", "600"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let reissue = app.buttons["bank.email.reissue"]
        XCTAssertTrue(reissue.waitForExistence(timeout: 10),
                      "a phone that had an address must be offered a REISSUE, not a first setup")
        XCTAssertFalse(app.buttons["bank.email.connect"].exists,
                       "«Підключити пошту» describes a first-time setup and this is not one")
        XCTAssertEqual(app.staticTexts["bank.email.reissue.cost"].label,
                       "Нова адреса буде іншою — пересилання у вашій пошті треба буде замінити.")
        assertLive(reissue)
        reissue.tap()

        // The setup screen must not offer «Створити адресу» here either — the
        // whole defect was that both screens read as a first-time setup.
        let issue = app.buttons["email.reissue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["email.connect"].exists)
        XCTAssertFalse(app.staticTexts["email.address"].exists,
                       "board #113 still holds: arriving must create nothing")

        // The one part no tap in this app can fix: the rule lives in somebody
        // else's mail settings.
        let warning = app.staticTexts["email.reissue.warning"]
        XCTAssertTrue(warning.exists)
        XCTAssertTrue(warning.label.contains("Старе пересилання"),
                      "the old forwarding rule is the part a person has to go and change")
    }

    // MARK: - Board #97 — a statement emailed to the issued address

    /// **The card's first two boxes, on the screen a person actually uses.**
    ///
    /// Connecting the email source only ever captures letters from NOW ON;
    /// history still needed the file picker. Emailing the export to the
    /// address that already receives mail is the path this card opened, and
    /// the phone parses — `PrivatStatementParser` stays the only parser in
    /// the system, so these bytes go through the file picker's own entry
    /// point.
    @MainActor
    /// **Board #187 — two waiting statements must be tellable apart.**
    ///
    /// **Owner:** «There may be several statements in the mail, so you need to
    /// give the user the opportunity to choose which statement to download.»
    ///
    /// One statement is the state that HIDES this bug: with a single button
    /// there is nothing to tell apart and the screen looks fine. That is why
    /// the fixture is two, and why this test asserts on the SECOND — an
    /// assertion on the first would have passed before the fix, because before
    /// the fix there was only ever one reachable element.
    func testTwoWaitingStatementsAreTellableApart() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "-stubEmailStatement",
                               "-stubTwoStatements", "-stubStatementDelay", "600"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        let first = app.buttons["email.statement.import.1"]
        let second = app.buttons["email.statement.import.2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        // The whole card, in one assertion: a second offer that is REACHABLE.
        // Every button used to carry the identifier `email.statement.import`,
        // so two waiting statements were one addressable element.
        XCTAssertTrue(second.waitForExistence(timeout: 5),
                      "the second waiting statement must be its own control")
        // Two statements make the card taller than one, so the second offer
        // can render below the fold — present in the tree, not actually
        // tappable. Board #171 hit exactly this with the link card. Scroll
        // only if needed, the same "if and only if" the rest of the suite uses.
        for _ in 0..<4 where !second.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        // Two statements make the card taller than one, so the second offer
        // can render below the fold — present in the tree, not actually
        // tappable. Board #171 hit exactly this with the link card. Scroll
        // only if needed, the same "if and only if" the rest of the suite uses.
        for _ in 0..<4 where !second.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        assertLive(first)
        assertLive(second)

        XCTAssertNotEqual(first.label, second.label,
                          "two identical «Завантажити виписку» buttons is the bug")
        XCTAssertTrue(first.label.contains(".xlsx"), first.label)
        XCTAssertTrue(second.label.contains(".xlsx"), second.label)

        // …and picking one imports THAT one. The other stays.
        second.tap()
        XCTAssertTrue(app.staticTexts["email.statement.done"].waitForExistence(timeout: 20))
    }

    func testAnEmailedStatementIsOfferedAndImports() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "-stubEmailStatement",
                               "-stubStatementDelay", "600"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        // Board #174 folded the setup half away once letters are arriving, and
        // this stub delivers four — so the instructions are behind their own
        // toggle now. Opening it is part of the assertion: a person whose
        // letters stopped has to be able to re-read exactly what their own
        // success hid.
        app.buttons["email.instructions.toggle"].tap()

        // Box two: the instructions name this path, whether or not a file is
        // waiting — somebody has to be told before they can send one.
        let instructions = app.staticTexts["email.file.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 15))
        XCTAssertTrue(instructions.label.contains("виписку в Приват24"))

        // Board #173. The steps used to describe a world where the bank sends
        // a FILE; #145 measured that it usually sends a LINK, so somebody
        // following them got something matching none of them and waited for a
        // button that never appeared. Both arrivals are named now, and so is
        // the manual forward the steps silently depended on — the Gmail filter
        // is «Операція за карткою», which never catches a statement letter.
        let note = app.staticTexts["email.file.linkNote"]
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("посилання"), "the usual arrival must be named")
        XCTAssertTrue(note.label.contains("Завантажити в додаток"),
                      "and it must name the button board #171 built, not a trip to a browser")

        let offer = app.first(withPrefix: "email.statement.import")
        XCTAssertTrue(offer.waitForExistence(timeout: 10),
                      "a statement waiting on the backend must be offered")
        assertLive(offer)
        offer.tap()

        XCTAssertTrue(app.staticTexts["email.statement.done"].waitForExistence(timeout: 20),
                      "the emailed statement must import")
        XCTAssertFalse(app.first(withPrefix: "email.statement.import").exists,
                       "an imported statement must stop being offered — the same "
                       + "history twice is the failure this guards")
    }

    /// Nothing waiting, no offer — but the instructions stay. An offer to
    /// import history somebody has not sent is not an offer.
    @MainActor
    func testNoOfferAppearsWhenNothingWasEmailed() {
        let app = connected()
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        // Board #174 — behind the toggle, because this stub's letters have
        // arrived and the setup half folds away once they have.
        app.buttons["email.instructions.toggle"].tap()
        XCTAssertTrue(app.staticTexts["email.file.instructions"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.first(withPrefix: "email.statement.import").exists)
        XCTAssertFalse(app.staticTexts["email.statement.waiting"].exists)
    }

    /// **A phone that updated ahead of its server must not break.**
    ///
    /// A backend predating board #97 has no `/statements` route and answers
    /// 404. Folding that failure in with the confirmation fetch would paint
    /// «Сервер відповів помилкою» over a screen whose every other part works
    /// — and the forwarding CODE lives on that screen, so the one thing a
    /// person cannot finish setup without would be hidden behind an error
    /// about a feature they never asked for.
    ///
    /// `-stubNoStatementRoute` makes the stub answer 404, which is the real
    /// shape of an old server. Merely omitting `-stubEmailStatement` would
    /// give an EMPTY LIST, and this test would then pass without the failure
    /// it is named for ever happening.
    @MainActor
    func testTheScreenStillWorksWhenNoStatementRouteAnswers() {
        let app = connected()
        app.launchArguments += ["-stubNoStatementRoute"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()
        app.buttons["bank.email.instructions"].tap()

        XCTAssertTrue(app.staticTexts["email.confirmation"].waitForExistence(timeout: 15),
                      "the forwarding code is what this screen exists for")
        XCTAssertFalse(app.staticTexts["email.error"].exists,
                       "an absent capability is not an error — it is an empty list")
        XCTAssertFalse(app.first(withPrefix: "email.statement.import").exists)
    }

    /// Connected, but with a secret the backend rejects — every request 401s.
    private func rejected() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-stubMonobank", "-stubPrivatEmail", "fail401",
                               "-stubStatementDelay", "600"]
        return app
    }

    /// A 401 is the one failure a person must be told about: the letters stop
    /// for good and only re-registering restarts them.
    @MainActor
    func testARejectedSecretSaysSoOnHome() {
        let app = rejected()
        app.launch()
        let status = app.staticTexts["sync.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(status.label.contains("підключіть пошту заново"),
                      "a rejected secret must not fail silently: \(status.label)")
    }

    /// The line above tells the person to connect again, so somewhere has to
    /// let them. Without this the bank screen offered «Перевірити» — which
    /// 401s forever — and «Відключити пошту», so the copy named an action the
    /// app did not have.
    @MainActor
    func testARejectedSecretOffersAWayToConnectAgain() {
        let app = rejected()
        app.launch()
        // Waiting on the status line first is what proves the flag is set;
        // the section below branches on the same flag.
        XCTAssertTrue(app.staticTexts["sync.status"].waitForExistence(timeout: 30))
        app.buttons["home.settings"].tap()
        app.buttons["settings.banks"].tap()
        app.buttons["banks.row.privatbank"].tap()

        let reconnect = app.buttons["bank.email.reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5),
                      "a dead secret must offer reconnecting, not only «Перевірити»")
        assertLive(reconnect)
        XCTAssertFalse(app.buttons["bank.email.check"].exists,
                       "«Перевірити» 401s forever here; offering it would be a dead end")
        reconnect.tap()
        XCTAssertTrue(app.buttons["email.done"].waitForExistence(timeout: 10),
                      "«Підключити заново» must reach the setup screen")
    }
}
