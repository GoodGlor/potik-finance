import XCTest

/// The receipt loop, Task 13's shape: one scanner, in Розібрати, because a fiscal
/// QR carries no purchase to point back at — matching runs automatically
/// afterwards, keyed by sum and time (`ReceiptMatch`), and a person is only
/// ever asked the two questions the app cannot answer on its own
/// (`ReceiptCard`): no purchase matched, or the receipt never published.
///
/// Task 10/12 review, superseded round: scanning used to live on a
/// purchase's own detail screen («Додати чек», `detail.receipt.add`). D2
/// removed it — `DetailTests` now asserts the affordance is GONE — and moved
/// the one scanner in the app here.
final class ReceiptTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ extra: [String] = [], tab: Int = 4) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "\(tab)",
             "-lang", "uk"] + extra
        app.launch()
        return app
    }

    /// The seed's OTHER pre-attached purchase (D5) — a car wash, not the
    /// fuel one `SplitTests` drives — picked specifically because its
    /// receipt's `fiscalTime` and its transaction's own `date` are the SAME
    /// instant: `ReceiptMatch`'s 3-hour window is real, and the seed's fuel
    /// pair (built by a different rule, not `ReceiptMatch`, when the seed
    /// was authored) sits outside it, so detaching and rescanning THAT one
    /// would never re-attach automatically. Named by UUID and its SPENDING
    /// category, never by seller: the standing privacy rule is that no
    /// merchant from the seed is ever written into source.
    private static let carWashTxId = "E9D0F6EB-4061-5ED2-A17F-32F1E4BA4DC3"
    private static let carWashDocumentNumber = "1000000006"
    private static let carWashCategory = "Автомобіль"

    /// A purchase the seed leaves unattached: 200,00 ₴, 2026-08-04. Its sum
    /// disagrees with the seeded `-seedNoPurchaseReceipt` fixture's own
    /// (287,01 ₴) — exactly the case a hand-picked attach must still honour.
    /// `SplitTests` builds its over-the-purchase fixture from the same pair.
    ///
    /// Found by a category few rows carry, because the pick list is searched by
    /// text: a category holding forty rows would put the wanted one below the
    /// fold, where `isHittable` fails. «Готівка» has four in the whole seed.
    ///
    /// It moved in board #15. The fixture named «Платежі до бюджету», one of
    /// the forty seeded categories, and the trim folded that into «Послуги» —
    /// the search then found nothing and the failure read like a broken picker
    /// rather than a stale constant.
    private static let smallTxId = "812B1E29-45A5-5871-A4EF-28E4820924C4"
    private static let smallCategory = "Готівка"

    /// Reached by search, in the month named by `monthsBack` (0 = the
    /// default, newest-with-data month). Stepping happens BEFORE the search
    /// field is engaged, never after: `.searchable` replaces the toolbar's
    /// month stepper with the system's own search chrome the instant the
    /// field is focused, so a step attempted once search is active finds no
    /// live `feed.prevMonth` at all. `monthsBack` is therefore only ever
    /// passed on the FIRST call for a given purchase in a test — a later
    /// call reusing the same purchase finds the feed already parked on the
    /// right month (tabs are not torn down) and needs none.
    @discardableResult
    private func openByCategory(_ app: XCUIApplication, txId: String, category: String,
                                monthsBack: Int = 0) -> XCUIElement {
        if monthsBack > 0 {
            let prev = app.buttons["feed.prevMonth"]
            for _ in 0..<monthsBack {
                XCTAssertTrue(prev.waitForExistence(timeout: 3))
                XCTAssertTrue(prev.isEnabled)
                prev.tap()
            }
        }

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let clear = app.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(category)

        let row = app.marker("feed.row.\(txId)")
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the purchase must be reachable in this month")
        for _ in 0..<3 where !row.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        return row
    }

    /// The receipt card sits low enough on the detail screen that at rest it
    /// renders under the floating tab bar — present in the tree but not
    /// actually reachable. A real user scrolls; so does this helper.
    private func scrollToReceiptCard(_ app: XCUIApplication) {
        app.scrollViews.firstMatch.swipeUp()
    }

    private func openScanner(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))
        let scan = app.buttons["queue.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 3))
        XCTAssertTrue(scan.isHittable)
        XCTAssertTrue(scan.isEnabled)
        scan.tap()
        XCTAssertTrue(app.marker("scanner.title").waitForExistence(timeout: 3))
    }

    /// Neither an attach nor a mismatch step exists in the scanner any more
    /// (D2/D10) — picking a sample hands its parsed check straight to
    /// `store.scan` and the sheet dismisses on its own. Waited for, not just
    /// asserted absent on the spot: a sheet does not remove the presenting
    /// content from the accessibility tree, so `scanner.title` going away is
    /// what actually proves the scan went through.
    private func waitForScannerToDismiss(_ app: XCUIApplication) {
        let scanner = app.marker("scanner.title")
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: scanner)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "scanning must dismiss the scanner on its own — there is no confirm step any more")
    }

    /// The owner's OWN launch: `-resetState` and nothing else, through the
    /// real first-run flow. `completeOnboarding` now stamps `Date()`
    /// unconditionally — Task 10 retired `Launch.demoStartedUsingAt` along
    /// with the date-windowed queue it existed for — and the queue no
    /// longer depends on that stamp at all: it is simply every `.pending`
    /// row, folded one card per shop (D5), no window, no row cap.
    ///
    /// This asserts the queue is POPULATED, not merely that Home rendered:
    /// «Усе розібрано» renders perfectly well over an empty queue.
    func testOnboardingForRealLeavesAQueueThereIsSomethingIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank", "-lang", "uk"]
        app.launch()

        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        for d in "1111" { app.buttons["pin.key.\(d)"].tap() }
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        for d in "1111" { app.buttons["pin.key.\(d)"].tap() }

        let mono = app.buttons["bank.row.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        mono.tap()                                       // board #19: one tap, no «Далі»
        let field = app.secureTextFields["bank.token.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        // "t1", not "t" — see OnboardingTests: a bare letter never round-trips
        // through Observation in this simulator.
        field.typeText("t1")
        app.buttons["bank.token.connect"].tap()
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
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "«Готово» must appear now that monobank is connected")
        skip.tap()

        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 5))
        let open = app.buttons["home.queue.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3),
                      "a freshly onboarded demo launch must have purchases to sort")
        XCTAssertTrue(open.isHittable)
        XCTAssertTrue(open.isEnabled)

        // …and the queue itself really has a card, not just a button offering one.
        open.tap()
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(app.topQueueGroup().waitForExistence(timeout: 3),
                      "the queue must actually hold a shop to answer, not just the button that opens it")
        // The total, parsed rather than hardcoded: `AppStore.groups` no
        // longer depends on `startedUsingAt` or a date window (D5), so the
        // row-cap era's fixed "0 з 31" no longer means anything, and
        // hardcoding today's demo total would only make this assertion
        // agree with whatever the seed happens to ship.
        let total = Int(progress.label.split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThan(total, 0, "the queue must not be empty: \(progress.label)")
    }

    /// The core loop: detach the seed's own pre-attached fuel receipt (so
    /// this proves Розібрати's scanner did the attaching, not that the seed
    /// already had), scan the SAME sample back from the queue, and the
    /// automatic matcher (`ReceiptMatch.sole`) must re-attach it to the same
    /// purchase without asking anyone.
    func testScanningASampleFromTheQueueAttachesItToTheMatchingPurchase() {
        let app = launch(tab: 1)
        openByCategory(app, txId: Self.carWashTxId, category: Self.carWashCategory, monthsBack: 1).tap()
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        scrollToReceiptCard(app)
        let detach = app.buttons["detail.receipt.detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 3), "precondition: the seed pre-attaches this receipt")
        detach.tap()
        XCTAssertTrue(app.staticTexts["Чек не додано"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))

        app.tabBars.buttons["Розібрати"].tap()
        openScanner(app)
        app.buttons["scanner.sample"].tap()
        let carWash = app.buttons["scanner.sample.\(Self.carWashDocumentNumber)"]
        XCTAssertTrue(carWash.waitForExistence(timeout: 3))
        XCTAssertTrue(carWash.isHittable)
        XCTAssertTrue(carWash.isEnabled)
        carWash.tap()
        waitForScannerToDismiss(app)

        app.tabBars.buttons["Стрічка"].tap()
        openByCategory(app, txId: Self.carWashTxId, category: Self.carWashCategory).tap()
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        scrollToReceiptCard(app)
        XCTAssertTrue(app.buttons["detail.receipt.detach"].waitForExistence(timeout: 3),
                      "the matching purchase must carry a receipt again, attached automatically")

        // The re-attached receipt is a fresh shell (D8): its goods have not
        // landed yet — that only happens through `ReceiptFetcher`'s async
        // commit, which this launch shape never runs (see the doc comment
        // on `Launch.seedNoPurchaseReceipt`) — so this is the empty state
        // EVERY scan is in immediately after attaching now, not a rare
        // branch. `receipt.empty` used to be asserted on exactly once, in a
        // test this task deleted with the old detail-screen flow; without
        // this, deleting the identifier or its copy leaves everything green.
        let empty = app.marker("receipt.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 3),
                      "a freshly scanned receipt has no goods yet and must say so")
        XCTAssertEqual(empty.label, "Чек розпізнано, товари з'являться після синхронізації")
    }

    /// The honest branch: a check nothing matches sits loose, never becomes
    /// a card while its items have not landed and it is not yet given up
    /// on — a receipt merely waiting is work in progress, not a question for
    /// a person (`ReceiptCard`'s own doc comment).
    ///
    /// Reviewer finding: the absence this test drives at is equally true of
    /// a screen that simply failed to render — an earlier draft passed even
    /// with the queue's scan wiring removed ENTIRELY. The positive partner
    /// is `queue.progress`, read before and after: it must still be there,
    /// and its own count must not have moved — proof this is "no card yet",
    /// not "nothing happened at all".
    func testAReceiptWaitingOnItsGoodsIsNotYetACard() {
        let app = launch(["-emptyReceiptSample"])
        let progress = app.staticTexts["queue.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let before = progress.label

        openScanner(app)
        app.buttons["scanner.sample"].tap()
        // `-emptyReceiptSample`'s document `store.scan` has never seen
        // before, so it takes the fresh-shell path and is genuinely enqueued
        // — not merely returned unchanged, the way re-picking a bundled
        // sample already in `store.receipts` would be.
        let unknown = app.buttons["scanner.sample.1000000009"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 3))
        XCTAssertTrue(unknown.isHittable)
        XCTAssertTrue(unknown.isEnabled)
        unknown.tap()
        waitForScannerToDismiss(app)

        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.'")).firstMatch.exists,
            "a receipt still waiting on its goods, inside its retry window, must not become a card")
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertEqual(progress.label, before, "the scan must not have touched the merchant-group queue")
    }

    /// A6: the hand-pick must go through even when the sums disagree —
    /// `AppStore.mismatch` is advisory, and only the AUTOMATIC matcher
    /// (`ReceiptMatch.sole`) is exact. `-seedNoPurchaseReceipt` stands in for
    /// a receipt whose items have already landed (unreachable live in this
    /// launch shape — `fetchDueReceiptsIfAllowed` itself suppresses the tax
    /// cabinet fetch under `-stage unlocked`, to protect other suites' fixed
    /// fixtures) — see `AppStore.live()`'s own doc comment on the fixture.
    func testPickingThePurchaseByHandAttachesEvenWhenTheSumsDisagree() {
        let app = launch(["-seedNoPurchaseReceipt"])
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))
        let pick = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.pick.'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "precondition: the seeded fixture is a .noPurchase card")
        XCTAssertTrue(pick.isHittable)
        XCTAssertTrue(pick.isEnabled)
        pick.tap()

        XCTAssertTrue(app.marker("queue.receipt.pickList").waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText(Self.smallCategory)
        let row = app.marker("queue.receipt.pickRow.\(Self.smallTxId)")
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "the picker must offer a purchase even though its sum disagrees")
        XCTAssertTrue(row.isHittable)
        row.tap()

        // An unconditional `.exists` here races the sheet-dismiss animation:
        // read immediately after `row.tap()`, the sheet can still be on
        // screen mid-dismiss, so a bare `.exists` is a coin flip on a slow
        // run. Wait for it the same way the card-removal check four lines
        // below already does.
        let pickList = app.marker("queue.receipt.pickList")
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pickList)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "picking must dismiss the sheet")
        let stillACard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.pick.'")).firstMatch
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stillACard)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed,
                       "attaching must clear the card — it is no longer loose")

        // Proof it actually attached, mismatch and all: the purchase's own
        // detail screen now carries this receipt.
        app.tabBars.buttons["Стрічка"].tap()
        openByCategory(app, txId: Self.smallTxId, category: Self.smallCategory).tap()
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        scrollToReceiptCard(app)
        XCTAssertTrue(app.buttons["detail.receipt.detach"].waitForExistence(timeout: 3),
                      "the hand-picked purchase must carry the receipt now, sum mismatch notwithstanding")
    }

    /// D6/A5: past `ReceiptSchedule.hasGivenUp`'s 48-hour boundary, the queue
    /// stops asking on its own — only a person's retry restarts it.
    /// `-seedNotPublishedReceipt` stands in for the real 48-hour wait a UI
    /// test cannot take: see `AppStore.live()`'s own doc comment.
    func testAReceiptThatNeverPublishedOffersARetry() {
        let app = launch(["-seedNotPublishedReceipt"])
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))
        let retry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.retry.'")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "precondition: the seeded fixture is a .notPublished card")
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(retry.isEnabled)
        retry.tap()

        // `AppStore.retryNow` restarts the clock — `scannedAt` becomes now,
        // so the card is no longer given up on and must disappear. Waited
        // for, not read on the spot: the next render lands a moment later.
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "retrying must restart the backoff — the card cannot still read as given up")
    }

    /// **Board #185 — the goods are sorted from the queue, not from the feed.**
    ///
    /// **Owner:** «I think it needs to be placed in the queue itself, combined
    /// with the categorization itself.» Before this card, a receipt whose goods
    /// published hours after the purchase was categorized left them no way back
    /// to those items except finding the transaction again in the feed and
    /// expanding it — and nothing on any screen said there was anything to
    /// find.
    ///
    /// `-seedItemsWaitingReceipt` stands in for the real publish-hours-later
    /// wait a UI test cannot take, exactly as its two sibling fixtures do.
    func testTheQueueOffersToSortAReceiptsGoodsAndStopsOnceSorted() {
        let app = launch(["-seedItemsWaitingReceipt"])
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))

        let sort = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.sort.'")).firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5),
                      "precondition: the seeded fixture is an .itemsWaiting card")
        assertLive(sort)
        sort.tap()

        // The sorter opens ON THE QUEUE — the whole point is that the person
        // never has to go and find the transaction.
        XCTAssertTrue(app.marker("queue.receipt.sorter").waitForExistence(timeout: 5),
                      "the items must be sortable from the queue itself")
        let confirm = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'receipt.confirm.'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        assertLive(confirm)
        confirm.tap()

        // **No «Готово» needed, and that is not an oversight.** The sheet is
        // presented BY the card, and confirming the split removes the card from
        // `receiptCards` — so SwiftUI tears the card down and the sheet goes
        // with it. Sorting the goods closes the thing you sorted them in, which
        // is what a person would expect and is why this test asserts the
        // dismissal rather than driving it. «Готово» exists for the other exit:
        // opening the sorter and deciding not to finish.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sort)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed,
                       "a sorted receipt must stop asking to be sorted")
        XCTAssertFalse(app.marker("queue.receipt.sorter").exists,
                       "…and the sheet it was sorted in goes with it")
    }

    /// A5: `QueueView`'s three-way branch now accounts for receipt cards —
    /// "done" is nothing pending AND no card, not merely nothing pending.
    /// Drains every merchant group (`QueueFlowTests` does the same thing to
    /// prove the OLD "done" still works) and proves the queue does not
    /// consider itself finished while `-seedNoPurchaseReceipt`'s card is
    /// still sitting there unanswered.
    func testTheQueueIsNotDoneWhileAReceiptStillNeedsAnAnswer() {
        let app = launch(["-seedNoPurchaseReceipt"])
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))

        var safety = 0
        while app.confirmTopQueueItem(timeout: 5) {
            safety += 1
            XCTAssertLessThan(safety, 200, "queue did not clear — confirming stopped advancing it")
        }

        XCTAssertFalse(app.marker("queue.doneScreen").exists,
                       "a receipt card still needs an answer — the queue cannot be done")
        let pick = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.pick.'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 3),
                      "the card that is keeping the queue open must actually still be on screen")
    }
}
