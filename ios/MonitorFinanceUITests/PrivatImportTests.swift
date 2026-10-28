import XCTest

/// The whole new loop, walked end to end: mono → cards → depth → connected
/// → picker → privat → import (stubbed past the Files sheet) → summary →
/// skip → tabs. No other test exercises a SECOND bank being added in the
/// same onboarding pass, or the statement-import branch of the picker.
final class PrivatImportTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    func testOnboardingImportsAStatementAfterMonobank() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank", "-stubPrivatStatement", "-lang", "uk"]
        app.launch()

        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        // First bank: monobank, all the way through token → cards → depth →
        // connected, same as OnboardingTests' walk.
        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        mono.tap()                                       // board #19: one tap, no «Далі»

        let connect = app.buttons["bank.token.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3))
        let field = app.secureTextFields["bank.token.field"]
        field.tap()
        // "token1" touches the digits page — see OnboardingTests for why a
        // bare letter never round-trips through Observation in this simulator.
        field.typeText("token1")
        connect.tap()

        let cardsNext = app.buttons["cards.next"]
        XCTAssertTrue(cardsNext.waitForExistence(timeout: 5), "cards screen after the mock token validates")
        XCTAssertTrue(app.buttons.matching(identifier: "cards.row").firstMatch.waitForExistence(timeout: 3),
                      "the cards screen must list the mock account, not just offer Далі")
        cardsNext.tap()

        let depth = app.buttons["depth.3"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5), "depth screen after cards")
        depth.tap()

        let start = app.buttons["bank.connected.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        assertLive(start)
        start.tap()                                    // «Далі» → picker again, not tabs

        // Second bank: the picker must offer PrivatBank as selectable (it is
        // a `.statement`-status bank now, not `.comingSoon`), and picking it
        // must land on board #91's two-way choice — letters or a statement —
        // whose statement side goes to the file import with no token, no
        // cards and no depth screen.
        let privat = app.buttons["bank.row.privatbank"]
        XCTAssertTrue(privat.waitForExistence(timeout: 5), "the picker must reappear with PrivatBank selectable")
        XCTAssertTrue(privat.isEnabled, "PrivatBank is a statement-import bank, not comingSoon")
        privat.tap()

        let statement = app.buttons["privat.source.statement"]
        XCTAssertTrue(statement.waitForExistence(timeout: 5),
                      "PrivatBank must ask which source before committing to one")
        statement.tap()

        let choose = app.buttons["import.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5),
                      "«Імпортувати виписку» must reach the import screen, not the token screen")
        choose.tap()                                    // -stubPrivatStatement feeds the fixture, skips Files

        XCTAssertTrue(app.staticTexts["import.summary"].waitForExistence(timeout: 5),
                      "the stubbed statement must import and show its summary")
        let done = app.buttons["import.done"]
        assertLive(done)
        done.tap()                                       // «Далі» → picker again

        // Both banks are connected now: «Готово» must be offered, and
        // tapping it must be what finally ends onboarding.
        let skip = app.buttons["bank.done"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "«Готово» must appear once a bank is connected")
        skip.tap()
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 5))

        // Optional (Task 10): the imported statement's own category rides
        // along as a one-tap suggestion chip on its merchant's queue card —
        // no other UI test exercises `queue.suggest.*` at all.
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 5))
        let openQueue = app.buttons["home.queue.open"]
        XCTAssertTrue(openQueue.waitForExistence(timeout: 5),
                      "a run with two freshly connected banks must have purchases to sort")
        openQueue.tap()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))
        let suggestion = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.suggest.'"))
            .firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3),
                      "a Privat-imported merchant must offer its bank's own category as a one-tap suggestion")

        // Board #14. The statement says «Ресторани, кафе, бари»; the app has
        // «Кафе та ресторани», and only one of the two may end up in the
        // category list. This is the only place the whole chain — parser,
        // mapper, store, chip — is exercised together on real fixture text.
        let cafe = app.buttons["queue.suggest.кафе вечір|expense"]
        XCTAssertTrue(cafe.waitForExistence(timeout: 3))
        XCTAssertEqual(cafe.label, "Так, Кафе та ресторани",
                       "the chip must offer the app's category, not the bank's wording")

        // …and a transfer offers nothing at all: a movement is not a purpose,
        // so there is no answer worth one tap. The card is there; the chip is
        // not.
        //
        // Board #55: a transfer is a GENERIC merchant, so its card carries a
        // per-row identifier and cannot be named by merchant alone. Matched by
        // prefix, and the chip is then looked for under that card's own full
        // identifier rather than under the merchant — which is the whole point
        // of the change: before it, `queue.suggest.переказ на чужу картку`
        // would have answered for any transfer card on screen.
        let transferPrefix = "queue.group.переказ на чужу картку|"
        let transfers = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", transferPrefix))
        XCTAssertGreaterThan(transfers.count, 0,
                             "precondition: the fixture's transfer row reaches the queue")
        let transferId = transfers.firstMatch.identifier
        XCTAssertFalse(
            app.buttons[transferId.replacingOccurrences(of: "queue.group.",
                                                        with: "queue.suggest.")].exists,
            "«Перекази» must not become a category on one tap")

        // The chip is an ACTION, not a state. `Image(systemName: "checkmark")`
        // carries the selected trait and a merged Button label inherits it —
        // the tree read «Так, Кредит, selected, button», which tells a screen
        // reader this category is already the answer.
        XCTAssertFalse(cafe.isSelected, "an unanswered card's chip must not announce itself as selected")

        // Tapping it answers the card, which is the claim the styling makes.
        let before = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'queue.group.'")).count
        cafe.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'queue.group.'")).count < before,
                      "one tap must remove the card it answered")
    }
}
