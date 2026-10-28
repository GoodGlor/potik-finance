import XCTest

final class QueueFlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "4", "-lang", "uk"]
        app.launch()
        return app
    }

    /// Board #104 — a queue card says which bank and which card, and shows its
    /// amount in an element of its own so direction can be a colour.
    ///
    /// Found by identifier prefix, not by name: a card suffix is seed data and
    /// naming one would put it into committed source.
    func testAQueueCardSaysWhichBankAndCard() {
        let app = launch()
        XCTAssertTrue(app.marker("queue.title").waitForExistence(timeout: 10))

        let mark = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.mark.'")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5),
                      "a card must say where its rows came from")
        XCTAssertTrue(mark.label.contains("monobank"), "got «\(mark.label)»")

        let amount = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.amount.'")).firstMatch
        XCTAssertTrue(amount.exists, "the money is its own element now, so it can be tinted")
        XCTAssertTrue(amount.label.contains("₴"))
        XCTAssertFalse(mark.label.contains("₴"),
                       "the money moved to its own element; this line is count and provenance")
    }

    func testConfirmingAdvancesTheQueueAndDropsTheCount() {
        let app = launch()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let before = progress.label

        XCTAssertTrue(app.confirmTopQueueItem(timeout: 5),
                      "the top card must offer a live way to resolve a shop")

        // Waited for, not read straight after the tap: the next render lands
        // a moment later, and an immediate read can still return the label
        // the screen had before it. A false red, but an expensive one to chase.
        let advanced = expectation(for: NSPredicate(format: "label != %@", before),
                                   evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed,
                       "confirming must advance the counter")
    }

    func testUndoPutsTheItemBack() {
        let app = launch()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let before = progress.label

        XCTAssertTrue(app.confirmTopQueueItem(timeout: 5),
                      "the top card must offer a live way to resolve a shop")
        // The count must actually move first, or the assertion at the end of
        // this test holds trivially and undo is never really put to work.
        let advanced = expectation(for: NSPredicate(format: "label != %@", before),
                                   evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)

        XCTAssertTrue(app.buttons["queue.undo"].waitForExistence(timeout: 2))
        app.buttons["queue.undo"].tap()

        // Waited for rather than read on the spot, for the same reason as
        // above — the restored count lands on a later render.
        let restored = expectation(for: NSPredicate(format: "label == %@", before),
                                   evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "undo restores the count the confirmation consumed")
    }

    /// The whole point of the redesign: one tap per shop, not one per
    /// purchase. A merchant that shipped several purchases resolves all of
    /// them together in the single tap that answers for it.
    ///
    /// One tap on a shop's card answers every purchase that shop has, not just
    /// the one on top.
    ///
    /// **Read off Головна's queue line, not off `queue.progress`** — board #8.
    /// Progress counts CARDS now, so answering one card advances it by exactly
    /// one however many purchases it carried, and this test's whole claim is
    /// about the purchases. Reading the jump off the progress line was only
    /// ever possible while that line counted rows, which is the same
    /// unit-confusion the badge had. The purchase count lives on
    /// `home.queue.line`.
    func testOneTapResolvesEveryPurchaseFromThatShop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", "0", "-lang", "uk"]
        app.launch()
        let line = app.staticTexts["home.queue.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let purchasesBefore = try XCTUnwrap(Self.purchases(in: line.label),
                                            "Головна must name the purchases: \(line.label)")

        app.tabBars.buttons["Розібрати"].tap()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let before = progress.label

        // A card that answers for several purchases, whichever merchant that
        // happens to be. NOT the top card any more: a generic merchant — a
        // transfer, a delivery service, an ATM — now renders one card per
        // transaction, and the seed's biggest card is a single row.
        let first = try XCTUnwrap(app.multiRowQueueGroup(),
                                  "the seed must still carry a shop with more than one purchase")
        XCTAssertTrue(app.revealQueueGroup(first), "the card must be reachable by scrolling")
        assertLive(first)
        first.tap()
        let notAnExpense = app.buttons["picker.notAnExpense"]
        XCTAssertTrue(notAnExpense.waitForExistence(timeout: 5))
        notAnExpense.tap()

        let advanced = expectation(for: NSPredicate(format: "label != %@", before),
                                   evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)

        // Exactly one card answered — the unit the queue is in.
        XCTAssertEqual(progress.label, "1 з " + (before.split(separator: " ").last ?? ""),
                       "one tap is one card: " + progress.label)

        // …and it took the whole shop with it. This is the claim.
        app.tabBars.buttons["Головна"].tap()
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let purchasesAfter = Self.purchases(in: line.label) ?? 0
        XCTAssertLessThan(purchasesAfter, purchasesBefore - 1,
                          "one tap must resolve every purchase from the shop, not just one — "
                          + "\(purchasesBefore) → \(line.label)")
    }

    /// The purchase figure out of «12 запитань · 66 покупок», or nil when the
    /// line names only the cards (which it does when the two are equal).
    private static func purchases(in label: String) -> Int? {
        guard let half = label.split(separator: "·").last, label.contains("·") else { return nil }
        return Int(half.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
    }

    // MARK: the picker knows what it is being asked about

    /// A launch with no demo data, so the queue holds exactly the stub's own
    /// six rows: five «Тестовий продавець …» purchases and one «Тестове
    /// надходження» of +2 500 ₴, which is the only income card in the app.
    /// The sync's first window lands about 3.5 s in, hence the long wait.
    private func launchWithAStubbedIncomeRow() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-noDemoData",
                               "-stubMonobank", "-stage", "unlocked", "-tab", "4", "-lang", "uk"]
        app.launch()
        return app
    }

    private func incomeGroup(_ app: XCUIApplication) -> XCUIElement {
        // `MerchantKey.normalize` lowercases and trims; the identifier is
        // `queue.group.<MerchantGroup.id>`, and that id is `key|kind` — board
        // #55, because a merchant that both paid and charged renders two
        // cards and the key alone named both of them.
        app.buttons["queue.group.тестове надходження|income"]
    }

    // MARK: what a card says about itself (board #9)

    /// The card was a plain white rectangle with nothing on it to say it did
    /// anything — the one screen in the app whose core gesture had no name.
    ///
    /// The chevron IS reachable, unlike the tab badge board #8 had to guard in
    /// pytest: SwiftUI keeps it as an `Image` with identifier `chevron.right`
    /// beside the merged button label. Dumped before this was written.
    func testEveryQueueCardShowsThatItOpensSomething() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", "4", "-lang", "uk"]
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'queue.group.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(cards.count, 1, "precondition: the demo shows several cards")

        // Every card on screen, not just the first: the affordance is only
        // worth anything if it is the pattern rather than a decoration on one.
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            XCTAssertTrue(card.images["chevron.right"].exists,
                          "card \(index) (\(card.identifier)) has nothing saying it is tappable")
        }
    }

    /// Board #9's other half: a salary was «1 покупка · 2 500 ₴» — income
    /// called a purchase, with the sign that makes it income thrown away.
    ///
    /// Read off the card's own label, which is where a person reads it. The
    /// wording and the plural agreement are pinned without a simulator in
    /// `QueueCardTests`; this is the wiring — that the card the queue builds
    /// for money coming IN is the one that gets the income wording.
    func testTheIncomeCardCallsItAnArrivalAndShowsThePlus() {
        let app = launchWithAStubbedIncomeRow()
        let income = incomeGroup(app)
        XCTAssertTrue(income.waitForExistence(timeout: 25))
        XCTAssertTrue(income.label.contains("1 надходження"),
                      "money arriving is not a purchase: " + income.label)
        XCTAssertTrue(income.label.contains("+2 500 ₴"),
                      "the sign is what makes it income: " + income.label)
        XCTAssertFalse(income.label.contains("покупка"), income.label)

        // The partner, or the assertions above would pass on a build that put
        // «надходження» on every card: a spending card keeps its own words and
        // takes no sign.
        let spend = app.buttons["queue.group.тестовий продавець 1|expense"]
        XCTAssertTrue(spend.waitForExistence(timeout: 5))
        XCTAssertTrue(spend.label.contains("покупки"), spend.label)
        XCTAssertFalse(spend.label.contains("+"), spend.label)
        XCTAssertFalse(spend.label.contains("надходження"), spend.label)
    }

    /// The bug this closes, verified live before the fix: the income card
    /// opened the full spending list, «Продукти» was one tap away, and taking
    /// it left Головна reporting income the Бюджет editor said was 0 ₴.
    func testAnIncomeCardOffersIncomeCategoriesAndNothingElse() {
        let app = launchWithAStubbedIncomeRow()
        let income = incomeGroup(app)
        XCTAssertTrue(income.waitForExistence(timeout: 25),
                      "the stub's +2 500 ₴ row must reach the queue as its own card")
        income.tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))

        assertLive(app.buttons["picker.row.Зарплата"])
        XCTAssertFalse(app.buttons["picker.notAnExpense"].exists,
                       "«Це не витрата» is about transfers, not about money coming in")

        // Counted, not spot-checked for one absent name: a `List` is lazy, so
        // «Продукти» being absent from the tree would also be true of a full
        // 39-row list scrolled to the top — the negative would pass for the
        // wrong reason. Four rows fit on any screen, so a count of exactly
        // four is a claim about the whole list.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'"))
        XCTAssertEqual(rows.count, 4, "only the income vocabulary, nothing else")
        let offered = Set((0..<rows.count).map {
            rows.element(boundBy: $0).identifier.replacingOccurrences(of: "picker.row.", with: "")
        })
        XCTAssertEqual(offered, ["Зарплата", "Стипендія", "Подарунки", "Інші надходження"])
    }

    /// The partner that stops the two negatives above from passing for the
    /// wrong reason: on a SPENDING card the same picker still offers both.
    func testASpendingCardStillOffersTheFullListAndNotAnExpense() {
        let app = launchWithAStubbedIncomeRow()
        let spend = app.buttons["queue.group.тестовий продавець 1|expense"]
        XCTAssertTrue(spend.waitForExistence(timeout: 25))
        spend.tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))

        let ownTransfer = app.buttons["picker.notAnExpense"]
        assertLive(ownTransfer)
        // Board #6, read off the screen rather than trusted: the row's whole
        // job is now its wording. SwiftUI merges a Button's label into one
        // accessibility element, so title and subtitle both arrive here.
        XCTAssertTrue(ownTransfer.label.contains("Переказ між своїми картками"),
                      "the row must name the ONE thing it still means — " + ownTransfer.label)
        XCTAssertFalse(ownTransfer.label.contains("готівк"),
                       "cash is spending now; offering it here is the bug #6 closed — "
                       + ownTransfer.label)

        // Searched for rather than read off the list: 40 categories do not
        // fit on a screen and a `List` only publishes what it has rendered.
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("Прод")
        assertLive(app.buttons["picker.row.Продукти"])
    }

    /// The answers #6 moved the cash and jar cases to. Both must be in the
    /// list for a person who has never opened Бюджет — «Заощадження» used to
    /// exist only once a plan was saved.
    func testCashAndSavingsAreOfferedOnASpendingCard() {
        let app = launchWithAStubbedIncomeRow()
        let spend = app.buttons["queue.group.тестовий продавець 1|expense"]
        XCTAssertTrue(spend.waitForExistence(timeout: 25))
        spend.tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))

        for name in ["Готівка", "Заощадження"] {
            let search = app.searchFields.firstMatch
            search.tap()
            search.typeText(name)
            assertLive(app.buttons["picker.row.\(name)"])
            // Cleared between the two, or the second search runs against the
            // first one's text and matches nothing.
            search.buttons.firstMatch.tap()
        }
    }

    /// Money can come in because a shop gave it back, and that row belongs
    /// against the purchase it cancels. Without this path the only answers
    /// would be the four income categories — three of which the budget counts
    /// as EARNINGS, so every refund would inflate the income the whole plan
    /// is a percentage of.
    func testARefundCanStillBeGivenTheCategoryOfThePurchaseItCancels() {
        let app = launchWithAStubbedIncomeRow()
        let income = incomeGroup(app)
        XCTAssertTrue(income.waitForExistence(timeout: 25))
        income.tap()

        let refund = app.buttons["picker.refund"]
        XCTAssertTrue(refund.waitForExistence(timeout: 3))
        refund.tap()

        XCTAssertTrue(app.marker("picker.refund.list").waitForExistence(timeout: 3))
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("Прод")
        let groceries = app.buttons["picker.row.Продукти"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 3),
                      "the refund list is the full category list, not the income one")
        groceries.tap()

        // One tap answers AND closes the whole picker, rather than popping
        // back to the income list — the sheet's own dismiss, not the push's.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: refund)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let cardGone = expectation(for: NSPredicate(format: "exists == false"),
                                   evaluatedWith: income)
        XCTAssertEqual(XCTWaiter.wait(for: [cardGone], timeout: 5), .completed,
                       "the answered income card leaves the queue")
    }

    /// D8, re-expressed for the by-shop queue (task-10 review): a merchant
    /// is answered ONCE, not once per purchase. `AppStore+Sync.applyingRule`
    /// (Step 3b) is what makes a FUTURE synced purchase from the same
    /// merchant arrive already typed instead of re-entering the queue —
    /// that half is unit-tested (`SyncStoreTests`), because nothing in this
    /// branch yet drives a live sync from the UI to exercise it end-to-end
    /// here. What the UI can prove today: resolving a shop's card retires
    /// it from the queue entirely — there is nothing left of that merchant
    /// still sitting there to be "remembered" again this session.
    func testAnAnsweredShopsCardLeavesTheQueue() {
        let app = launch()
        let group = app.topQueueGroup()
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        let identifier = group.identifier

        XCTAssertTrue(app.confirmTopQueueItem(timeout: 5),
                      "the top card must offer a live way to resolve a shop")

        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: app.buttons[identifier])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed,
                       "an answered shop's card must not linger in the queue")
    }

    /// Deferred finding from an earlier task: Home's queue card must stay
    /// visible at zero remaining, in a muted register, rather than vanish —
    /// a card that disappears when the work is done reads as a bug.
    ///
    /// The queue holds every `.pending` purchase, folded one card per shop —
    /// no date window, no row cap (D5). Confirming a card resolves every row
    /// it holds at once, so this drains however many shops the seed carries
    /// rather than one row at a time.
    func testHomeQueueCardStaysVisibleAndMutedOnceTheQueueIsEmpty() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))

        // The positive partner for the XCTAssertFalse at the end of this test.
        // Without it, that assertion passes for the wrong reason the moment the
        // identifier stops existing anywhere — which is exactly what happened:
        // `home.queue` on the card container stamped itself over the button's
        // own identifier, and the "no button once done" assertion went on
        // passing while the button was unreachable in BOTH states.
        app.tabBars.buttons["Головна"].tap()
        XCTAssertTrue(app.buttons["home.queue.open"].waitForExistence(timeout: 3),
                      "with the queue full, Home must offer the button to go resolve it")
        assertLive(app.buttons["home.queue.open"])
        app.tabBars.buttons["Розібрати"].tap()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 3))

        var safety = 0
        while app.confirmTopQueueItem(timeout: 5) {
            safety += 1
            // Sized well past the seed's distinct-merchant count: each tap
            // clears a whole shop, not one row, so this drains far faster
            // than the old per-purchase valve did.
            XCTAssertLessThan(safety, 200, "queue did not clear — confirming stopped advancing it")
        }

        XCTAssertTrue(app.marker("queue.doneScreen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["queue.done"].waitForExistence(timeout: 3))

        // The last confirmation's toast sits at the bottom of the screen for
        // five seconds and can still overlap "На головну" the instant the done
        // screen appears — wait it out so the tap lands on the button, not on
        // the toast drawn above it.
        let lastToast = app.buttons["queue.undo"]
        if lastToast.exists {
            let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: lastToast)
            wait(for: [dismissed], timeout: 6)
        }

        assertLive(app.buttons["queue.done"])
        app.buttons["queue.done"].tap()

        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 3))
        XCTAssertTrue(app.marker("home.queue").waitForExistence(timeout: 3),
                      "the queue card must stay on Home even with nothing pending")
        XCTAssertFalse(app.buttons["home.queue.open"].exists,
                       "the muted done state offers no 'go resolve it' button")
    }

    // MARK: one screen's worth of work, one number

    /// **Board #8's first acceptance line.** Головна led with the purchases and
    /// the toolbar counted something else, so one screen's worth of work had
    /// two names — 4 cards on screen, «12» beside them.
    ///
    /// **The tab badge is not in this assertion, and cannot be.** SwiftUI does
    /// not surface it: the tab's element is a plain `Button` labelled «Розібрати»
    /// with an empty `value`, so there is nothing for XCUITest to read. It is
    /// pinned at the call site instead —
    /// `test_the_badge_and_the_home_card_count_the_same_thing` fails if
    /// `MainView` ever feeds the badge and Головна different values.
    func testTheHomeCardAndTheQueueProgressAreTheSameNumber() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", "0", "-lang", "uk"]
        app.launch()
        let line = app.staticTexts["home.queue.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let onHome = try XCTUnwrap(Int(line.label.split(separator: " ").first ?? ""),
                                   "Головна must lead with a number: \(line.label)")

        app.tabBars.buttons["Розібрати"].tap()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "0 з \(onHome)",
                       "the queue must open counting the same cards Головна named")

        // …and they stay together. One card answered moves both by one — the
        // old pair moved by one card and by however many purchases that card
        // carried, which is how they drifted apart within a single tap.
        XCTAssertTrue(app.confirmTopQueueItem(timeout: 5))
        let advanced = expectation(for: NSPredicate(format: "label == %@", "1 з \(onHome)"),
                                   evaluatedWith: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed,
                       "one card answered is one step: " + progress.label)

        app.tabBars.buttons["Головна"].tap()
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(Int(line.label.split(separator: " ").first ?? ""), onHome - 1,
                       "Головна must have moved by exactly one card too: \(line.label)")
    }

    // MARK: one card, one identifier (board #55)

    // MARK: board #103 — answering several cards at once

    /// The card's whole point: ~61 taps to drain the demo queue, and ten coffee
    /// shops should be one gesture. This picks three cards and answers them
    /// together.
    func testSeveralCardsCanBeAnsweredWithOneCategory() {
        let app = launch()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let before = progress.label

        app.buttons["queue.select"].tap()
        // The bar exists but cannot act until something is picked — otherwise
        // the assertion below would pass for a button that always worked.
        XCTAssertTrue(app.marker("queue.selectedCount").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["queue.bulkCategory"].isEnabled,
                       "nothing is selected yet, so there is nothing to answer")

        let picked = pickCards(app, wanted: 3)
        XCTAssertEqual(picked, 3, "three cards of one kind must be selectable")
        XCTAssertEqual(Int(app.marker("queue.selectedCount").value as? String ?? "") ?? -1, 3)

        app.buttons["queue.bulkCategory"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'picker.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker opens for the selection")
        row.tap()

        // The progress line is the app's own count of what is left, and three
        // cards leaving at once is what this card exists to do.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, progress.label == before { usleep(150_000) }
        XCTAssertNotEqual(progress.label, before, "three cards must have left the queue")
        XCTAssertFalse(app.buttons["queue.bulkCategory"].exists,
                       "answering ends the mode — the bar is gone")
    }

    /// **The corruption vector, on screen.** With an expense picked, the income
    /// cards stop responding: one category across directions is how a spending
    /// category lands on a salary.
    func testASelectionCannotMixDirections() {
        let app = launchWithAStubbedIncomeRow()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 30))
        let income = incomeGroup(app)
        XCTAssertTrue(income.waitForExistence(timeout: 10), "precondition: an income card")
        XCTAssertTrue(income.isEnabled, "…and it is ordinarily live")

        app.buttons["queue.select"].tap()
        // An expense card — anything that is not the income one.
        let expense = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'queue.group.' AND identifier CONTAINS '|expense'"))
            .firstMatch
        XCTAssertTrue(expense.waitForExistence(timeout: 5))
        expense.tap()
        XCTAssertEqual(Int(app.marker("queue.selectedCount").value as? String ?? "") ?? -1, 1)

        XCTAssertFalse(income.isEnabled,
                       "with an expense picked, an income card must not join the selection")
        XCTAssertEqual(Int(app.marker("queue.selectedCount").value as? String ?? "") ?? -1, 1,
                       "…and the count must not have moved")
    }

    /// Leaving the mode drops the selection. Coming back to cards still ticked
    /// would arm a bulk answer with a choice made minutes ago and no longer on
    /// screen.
    func testLeavingSelectionModeForgetsWhatWasPicked() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 10))
        app.buttons["queue.select"].tap()
        XCTAssertEqual(pickCards(app, wanted: 2), 2)
        XCTAssertEqual(Int(app.marker("queue.selectedCount").value as? String ?? "") ?? -1, 2)

        app.buttons["queue.select"].tap()          // «Готово»
        app.buttons["queue.select"].tap()          // «Вибрати» again
        XCTAssertEqual(Int(app.marker("queue.selectedCount").value as? String ?? "") ?? -1, 0,
                       "the previous selection must not survive the round trip")
    }

    /// Taps the first `wanted` selectable cards and returns how many took.
    /// Cards of the wrong kind are disabled, so this counts what actually
    /// joined rather than how many taps it made.
    private func pickCards(_ app: XCUIApplication, wanted: Int) -> Int {
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'queue.group.'"))
        var taken = 0
        for i in 0..<min(cards.count, wanted * 3) where taken < wanted {
            let card = cards.element(boundBy: i)
            guard card.exists, card.isEnabled, card.isHittable else { continue }
            card.tap()
            taken += 1
        }
        return taken
    }

    private func queueCardIds(_ app: XCUIApplication) -> [String] {
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'queue.group.'"))
        return (0..<cards.count).map { cards.element(boundBy: $0).identifier }
    }

    /// Every identifier of the largest family of cards that share a merchant
    /// and a kind — i.e. the per-transaction cards of one generic merchant.
    ///
    /// Found by folding on the identifier's `queue.group.<key>|<kind>` head
    /// rather than by naming a merchant: the seed's merchants may not be
    /// written into source (the privacy guard in `tests/test_ios_seed.py`),
    /// and a test that hardcoded one would break the day the demo changed
    /// shape anyway.
    private func largestCardFamily(_ app: XCUIApplication) -> [String] {
        var families: [String: [String]] = [:]
        for id in queueCardIds(app) {
            let parts = id.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }   // key|kind|rowId
            families[parts[0] + "|" + parts[1], default: []].append(id)
        }
        return families.values.max { $0.count < $1.count } ?? []
    }

    /// The demo seed's biggest transfer family is 35 rows of one generic
    /// merchant, so the queue renders 35 separate cards for it — and every
    /// one of them used to answer to `queue.group.<that merchant>`. Nothing in
    /// the app misbehaved; what broke was the ability to write a test that
    /// means a PARTICULAR one. `firstMatch` would quietly hand back whichever
    /// the tree yielded first, and the test would pass having exercised a card
    /// it did not choose.
    func testEveryQueueCardHasAnIdentifierOfItsOwn() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))

        let ids = queueCardIds(app)
        XCTAssertGreaterThan(ids.count, 1, "an empty queue would make this vacuous")

        // The precondition that makes the assertion mean anything: several
        // cards on screen really do share a merchant. Without it, unique
        // identifiers would prove only that the seed has no repeats.
        XCTAssertGreaterThan(largestCardFamily(app).count, 1,
                             "the colliding case is not on screen: \(ids)")

        XCTAssertEqual(Set(ids).count, ids.count,
                       "two cards answering to one identifier: \(ids)")
    }

    /// The other half of the card, and the one a future test will lean on:
    /// naming a specific per-transaction card resolves to exactly that card.
    ///
    /// The identifier is read off the tree rather than written as a literal —
    /// it ends in the row's UUID, which no test can know in advance. That is
    /// the honest shape here: the guarantee being bought is that the name is
    /// UNIQUE and STABLE for the card it came from, not that it is guessable.
    func testNamingOnePerTransactionCardAnswersThatCardAlone() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))

        let transfers = largestCardFamily(app)
        XCTAssertGreaterThan(transfers.count, 1, "need two to tell them apart")
        let chosen = transfers[1]                 // deliberately NOT firstMatch
        let other = transfers[0]

        let card = app.buttons[chosen]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: chosen).count, 1,
                       "the name must reach one card, not a family of them")
        let itsLabel = card.label

        XCTAssertTrue(app.revealQueueGroup(card), "could not bring \(chosen) into reach")
        assertLive(card)
        card.tap()

        let notAnExpense = app.buttons["picker.notAnExpense"]
        XCTAssertTrue(notAnExpense.waitForExistence(timeout: 5))
        notAnExpense.tap()

        // The card that was named is gone; its sibling is untouched. Both
        // halves matter — a build that answered ALL the transfers at once
        // would pass the first assertion on its own.
        let vanished = expectation(for: NSPredicate(format: "exists == false"),
                                   evaluatedWith: app.buttons[chosen])
        XCTAssertEqual(XCTWaiter.wait(for: [vanished], timeout: 5), .completed,
                       "answering «\(itsLabel)» must remove that card")
        XCTAssertTrue(app.buttons[other].exists,
                      "…and only that card: the sibling transfer was answered too")
    }
}
