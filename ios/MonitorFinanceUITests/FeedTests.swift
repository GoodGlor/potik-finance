import XCTest

final class FeedTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "1", "-lang", "uk"]
        app.launch()
        return app
    }

    /// Board #98 — every row says which bank and which card.
    ///
    /// Queried by the `feed.mark.` prefix rather than by one row's uuid: the
    /// seed's ids are minted at load, so naming one would pin this test to a
    /// fixture detail instead of to the behaviour. The assertion is that a mark
    /// EXISTS and carries the bank's name, which is what the card asked for.
    func testEveryFeedRowSaysWhichBankAndCard() {
        let app = launch()
        let mark = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.mark.'"))
            .firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 10),
                      "a feed row must say where it came from")
        XCTAssertTrue(mark.label.contains("monobank"),
                      "the mark names the bank; got «\(mark.label)»")
        // The seed's cards are masked `*NNNN`, so the card half is there too —
        // and the separator does not collide with that mask.
        XCTAssertTrue(mark.label.contains(" · "),
                      "bank and card are separated the way the subtitle separates its parts")
        XCTAssertFalse(mark.label.contains("·*"),
                       "a tight separator beside the card's own mask reads as two marks")
    }

    func testFeedOpensOnTheLatestMonthAndStepsBack() {
        let app = launch()
        let title = app.buttons["feed.month"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let first = title.label
        assertLive(app.buttons["feed.prevMonth"])
        app.buttons["feed.prevMonth"].tap()
        XCTAssertNotEqual(app.buttons["feed.month"].label, first,
                          "stepping back must change the month shown")
    }

    /// The newest month has nothing after it, so forward must be unavailable —
    /// not merely present and inert.
    func testForwardIsDisabledOnTheNewestMonth() {
        let app = launch()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feed.nextMonth"].isEnabled)
        app.buttons["feed.prevMonth"].tap()
        XCTAssertTrue(app.buttons["feed.nextMonth"].isEnabled)
    }

    func testSearchNarrowsTheListAndClearingRestoresIt() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        // Rendered-row count is not trustworthy: a lazy ScrollView only
        // materialises what is on screen, and it moved by coincidence rather
        // than by search working the one time this was checked. feed.count
        // reports rows.count directly, so assert on that instead.
        let before = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(before, 0, "the seeded month must have rows to filter")

        // .searchable does not reliably carry an accessibilityIdentifier, so
        // address it as what it is: the screen's only search field.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("сільпо")
        let after = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertLessThan(after, before, "search must remove rows")

        app.buttons["Clear text"].tap()
        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, before)
    }

    func testAMonthWithNoMatchesShowsAnEmptyState() {
        let app = launch()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("zzzz9")
        XCTAssertTrue(app.staticTexts["feed.empty"].waitForExistence(timeout: 2))
    }

    /// Board #99 — the bank dimension, walked end to end on the seed.
    ///
    /// The seed is single-bank, so choosing its one bank cannot narrow the
    /// list. That is exactly why the assertion is `==` and not `<`: a bank
    /// filter that quietly dropped rows belonging to the bank it selected
    /// would pass a "fewer rows" test and be wrong. The narrowing itself is
    /// covered against two banks in `FeedBankFilterTests`, where a fixture can
    /// have them.
    func testChoosingTheBankKeepsEveryRowThatBankOwns() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        let all = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(all, 0)

        app.buttons["feed.filter"].tap()
        let bank = app.buttons["filter.bank.monobank"]
        XCTAssertTrue(bank.waitForExistence(timeout: 3),
                      "the sheet offers every bank that has rows")
        bank.tap()
        app.buttons["filter.done"].tap()

        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, all,
                       "the seed's only bank owns every row, so its filter removes none")
        // The chip proves the filter is actually ON — without it the equality
        // above would also pass for a filter that did nothing at all.
        XCTAssertTrue(app.staticTexts["monobank"].waitForExistence(timeout: 2),
                      "an active bank filter names the bank in the chip bar")

        app.buttons["feed.filter.clearAll"].tap()
        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, all)
    }

    func testFilteringByKindNarrowsTheFeedAndAChipClearsIt() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        // The rendered-row count is useless here: a lazy container materialises
        // only what is on screen, so it barely moves when the data does. The
        // count line reports rows.count itself.
        let all = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(all, 0)

        app.buttons["feed.filter"].tap()
        XCTAssertTrue(app.buttons["filter.kind.income"].waitForExistence(timeout: 2))
        app.buttons["filter.kind.income"].tap()
        app.buttons["filter.done"].tap()

        let filtered = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(filtered, 0, "the seeded month has income rows")
        XCTAssertLessThan(filtered, all, "income-only must be strictly fewer rows than everything")

        app.buttons["feed.filter.clearAll"].tap()
        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, all,
                       "clearing every filter must restore the original count")
    }

    // MARK: board #110 — with or without a receipt

    /// The card's first two criteria at once: the dimension exists, it cuts
    /// both ways, and it composes with the four that were already there.
    ///
    /// The two sides must **partition** the month — anything else means the
    /// predicate is not the complement of itself, and a purchase would be
    /// invisible under both halves of a filter that claims to cover everything.
    func testTheReceiptFilterCutsBothWaysAndTheHalvesAddUp() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        let all = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(all, 0)

        app.buttons["feed.filter"].tap()
        let without = app.buttons["filter.receipt.without"]
        XCTAssertTrue(without.waitForExistence(timeout: 3),
                      "«Чек» sits above Категорії so it needs no scrolling")
        without.tap()
        app.buttons["filter.done"].tap()
        let none = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(none, 0)
        XCTAssertLessThan(none, all, "some of the seed's rows do have a receipt")

        app.buttons["feed.filter"].tap()
        // Tapping the OTHER side replaces the choice — these are radio rows,
        // not membership rows. If it merely added, the feed would go empty and
        // the sum below would be nonsense.
        app.buttons["filter.receipt.with"].tap()
        app.buttons["filter.done"].tap()
        let some = Int(app.marker("feed.count").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(some, 0, "the seed attaches receipts to some rows")
        XCTAssertEqual(none + some, all,
                       "with + without must be exactly the month, or the predicate "
                       + "is not the complement of itself")
    }

    /// Tapping the selected side clears it — the sheet is its own undo, the
    /// same rule every other row here follows. Without it, «any» would be
    /// reachable only through «Скинути».
    func testTappingTheChosenSideAgainClearsIt() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        let all = Int(app.marker("feed.count").value as? String ?? "") ?? -1

        app.buttons["feed.filter"].tap()
        XCTAssertTrue(app.buttons["filter.receipt.without"].waitForExistence(timeout: 3))
        app.buttons["filter.receipt.without"].tap()
        app.buttons["filter.done"].tap()
        XCTAssertLessThan(Int(app.marker("feed.count").value as? String ?? "") ?? -1, all)
        // The chip proves the dimension reached `isEmpty` and `chips` — a
        // filter with no chip is one a person cannot see or clear.
        XCTAssertTrue(app.staticTexts["Без чека"].waitForExistence(timeout: 2),
                      "an active receipt filter names itself in the chip bar")

        app.buttons["feed.filter"].tap()
        app.buttons["filter.receipt.without"].tap()
        app.buttons["filter.done"].tap()
        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, all,
                       "tapping the chosen side again restores every row")
    }

    /// The card's third criterion: «Без чека» carries how many are waiting, so
    /// the filter doubles as a to-do you can read without applying it.
    func testTheWithoutSideCarriesACountOfWhatIsWaiting() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.count").waitForExistence(timeout: 5))
        app.buttons["feed.filter"].tap()

        let badge = app.marker("filter.receipt.missingCount")
        XCTAssertTrue(badge.waitForExistence(timeout: 3),
                      "the actionable side says how much there is to do")
        let waiting = Int(badge.label) ?? -1
        XCTAssertGreaterThan(waiting, 0, "the seed leaves purchases unscanned")

        // And it is the same number the filter then produces — minus the rows
        // that could never have a receipt, which the count deliberately omits
        // and the filter deliberately keeps.
        app.buttons["filter.receipt.without"].tap()
        app.buttons["filter.kind.expense"].tap()
        app.buttons["filter.done"].tap()
        XCTAssertEqual(Int(app.marker("feed.count").value as? String ?? "") ?? -1, waiting,
                       "«N без чеків» must be the list «Без чека» + «Витрати» opens")
    }

    // MARK: board #109 — choosing a month

    /// The card's first criterion: a month **control**, not only a stepper.
    /// The seed carries eight months, so reaching the oldest by chevron is
    /// seven taps; this is the one that makes it two.
    func testTheMonthTitleOpensAPickerThatChangesTheMonth() {
        let app = launch()
        let title = app.buttons["feed.month"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let opened = title.label
        title.tap()

        // Newest first, so the second row is the month before the one shown —
        // by index, because the seed's months are dates this test must not
        // hardcode.
        let months = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.month.'"))
        XCTAssertTrue(months.element(boundBy: 0).waitForExistence(timeout: 5),
                      "the sheet must list the months that have data")
        XCTAssertGreaterThan(months.count, 1, "the seed spans several months")
        months.element(boundBy: 1).tap()

        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.buttons["feed.month"].label, opened,
                          "picking a month from the sheet must change the feed's month")
    }

    /// The card's second criterion, and the literal one: back to the newest
    /// month in a single tap, from wherever you have stepped to.
    func testOnceSteppedAwayOneTapReturnsToTheNewestMonth() {
        let app = launch()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let newest = app.buttons["feed.month"].label

        // The way back must not exist before there is anywhere to come back
        // from — otherwise the assertion below passes for a button that is
        // always on screen and does nothing.
        XCTAssertFalse(app.buttons["feed.thisMonth"].exists,
                       "nothing to return to while the newest month is shown")

        app.buttons["feed.prevMonth"].tap()
        app.buttons["feed.prevMonth"].tap()
        XCTAssertNotEqual(app.buttons["feed.month"].label, newest)

        let back = app.buttons["feed.thisMonth"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        assertLive(back)
        back.tap()
        XCTAssertEqual(app.buttons["feed.month"].label, newest,
                       "one tap, from two months away")
    }

    /// The card's third criterion: totals follow the month. The feed had none
    /// at all before this card — it said how many and never how much — so
    /// "totals reflect the chosen month" was a claim about a figure that did
    /// not exist.
    func testTheSpendingTotalFollowsTheChosenMonth() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.total").waitForExistence(timeout: 5))
        let newest = Int(app.marker("feed.total").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(newest, 0, "the newest month has spending in it")

        app.buttons["feed.prevMonth"].tap()
        let previous = Int(app.marker("feed.total").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(previous, 0)
        XCTAssertNotEqual(previous, newest,
                          "two different months must not report one total")
    }

    /// And it composes with the filters, which is the criterion that would
    /// break first if the month cut were applied somewhere the filters are not.
    func testTheTotalFollowsTheFiltersTooAndClearingRestoresIt() {
        let app = launch()
        XCTAssertTrue(app.marker("feed.total").waitForExistence(timeout: 5))
        let all = Int(app.marker("feed.total").value as? String ?? "") ?? -1
        XCTAssertGreaterThan(all, 0)

        app.buttons["feed.filter"].tap()
        XCTAssertTrue(app.buttons["filter.kind.income"].waitForExistence(timeout: 2))
        app.buttons["filter.kind.income"].tap()
        app.buttons["filter.done"].tap()

        XCTAssertEqual(Int(app.marker("feed.total").value as? String ?? "") ?? -1, 0,
                       "income-only rows contain no spending, and the total must say so")

        app.buttons["feed.filter.clearAll"].tap()
        XCTAssertEqual(Int(app.marker("feed.total").value as? String ?? "") ?? -1, all)
    }
}
