import XCTest

final class StatsAndSettingsTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", tab, "-lang", "uk"]
        app.launch()
        return app
    }

    /// Asserts the TOTAL changes between scopes, not merely that the segments
    /// are tappable — a segmented control that changes nothing would pass that.
    /// Board #101 — scoping to one card changes what the tab is summing, and
    /// the choice survives leaving the tab and coming back.
    ///
    /// The seed is one bank with four cards, so `.all` IS that bank and no bank
    /// chip is offered; the cards are the real cut.
    ///
    /// **It taps the LAST card chip, and that is not arbitrary.** The seed puts
    /// every expense on one card and leaves the other three holding transfers
    /// only, so scoping to the FIRST card changes the spending total by exactly
    /// nothing — correctly. The first version of this test tapped that one and
    /// failed, blaming the code for the fixture's shape. The last chip is a
    /// transfer-only card, where the total must visibly move.
    ///
    /// Chips are found by their `card.` identifier prefix rather than by name:
    /// naming one would write a real seed card number into committed source,
    /// which the privacy guard forbids and a lowercase spelling would only hide.
    func testScopingToOneCardChangesTheTotalAndSurvivesATabSwitch() {
        let app = launch("3")
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.marker("stats.sources").waitForExistence(timeout: 3),
                      "four cards is something to choose between")

        // «Рік», so the period cannot be what moves the total.
        assertLive(app.buttons["Рік"])
        app.buttons["Рік"].tap()
        // The unscoped tab has a total to begin with — without this the empty
        // state below could be the screen's resting state rather than the
        // scope's doing.
        XCTAssertFalse(app.staticTexts["stats.total"].label.isEmpty,
                       "the unscoped tab shows a total")

        let cards = app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stats.source.card.'"))
        XCTAssertGreaterThan(cards.count, 1, "the seed's bank has four cards")
        let card = cards.element(boundBy: cards.count - 1)
        let chosen = card.identifier
        card.tap()

        // That card holds only transfers, so there is no spending to draw —
        // and the screen says so instead of showing a total. Asserted as the
        // EMPTY STATE rather than as a different number: a total that had
        // merely changed would also pass a `!=`, and this is the stronger and
        // more specific claim about what the scope did.
        let empty = app.marker("stats.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 3),
                      "a card with no spending must say so, not show another card's total")
        XCTAssertFalse(app.staticTexts["stats.total"].exists,
                       "and it must not still be showing every card's total")

        // Away and back: the scope is a question being asked, and it should
        // still be the question on return (board #64 keeps the tab alive).
        app.tabBars.buttons.element(boundBy: 1).tap()
        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.marker("stats.sources").waitForExistence(timeout: 3))
        XCTAssertTrue(app.marker("stats.empty").exists,
                      "the chosen scope must survive a tab switch")
        XCTAssertTrue(app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier == %@", chosen)).firstMatch.exists)
    }

    func testSwitchingScopeChangesTheTotal() {
        let app = launch("3")
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        let monthTotal = app.staticTexts["stats.total"].label
        assertLive(app.buttons["Рік"])
        app.buttons["Рік"].tap()
        XCTAssertNotEqual(app.staticTexts["stats.total"].label, monthTotal)
        assertLive(app.buttons["Тиждень"])
        app.buttons["Тиждень"].tap()
        XCTAssertNotEqual(app.staticTexts["stats.total"].label, monthTotal)
    }

    /// Board #83: the ring is a whole, and the row that closes it is not a
    /// category.
    ///
    /// The demo seed carries fifteen spending categories, so «Рік» folds —
    /// seven drillable rows and one «Решта». Counting the BUTTONS is what
    /// makes that precise: eight would mean nothing folded, and the
    /// everything-else row is deliberately not one.
    ///
    /// **Never `descendants(matching: .any)` here.** The first version of this
    /// test counted rows that way and took **907 seconds** — the same trap
    /// `expectation(for:evaluatedWith:)` sprang at 914 s on the feed. A
    /// full-tree snapshot on a screen this size is seconds per evaluation, and
    /// a loop that polls `isHittable` pays it every turn. Typed queries and a
    /// fixed number of swipes: 11 seconds.
    ///
    /// The no-fold case is `DerivedTests`' — every period the demo seed can
    /// show has more than eight categories, so there is no fixture for it here.
    func testTheRingClosesWithAnEverythingElseRowThatIsNotACategory() {
        let app = launch("3")
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["Рік"])
        app.buttons["Рік"].tap()

        let rest = app.otherElements["stats.slice.rest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 3),
                      "a year of the demo seed has more categories than colours")

        let drillable = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stats.slice.'"))
        XCTAssertEqual(drillable.count, 7, "seven categories beside the everything-else row")

        // Not a button, and that is the point: it stands for several
        // categories, and `CategoryDrill` takes one — a tap would have opened
        // a feed filtered to a category nobody has.
        XCTAssertFalse(app.buttons["stats.slice.rest"].exists,
                       "the everything-else row must not offer a drill")

        // The eighth legend row is below the fold, and `isHittable` is false
        // for an element that merely exists off screen — the one case that
        // assertion is genuinely good at.
        for _ in 0..<4 where !rest.isHittable { app.swipeUp() }
        assertLive(rest, "the row that closes the ring must be readable")
        XCTAssertTrue(app.staticTexts["Решта"].firstMatch.exists)
    }

    /// The drill-through, end to end. Reaching `feed.title` is NOT the thing
    /// worth asserting: this test used to stop there, and it stayed green both
    /// when `FeedView`'s `initialCategory` filter was deleted outright AND when
    /// the feed it opened had every row inert — a stack typed `[CategoryDrill]`
    /// silently refused the feed's own `NavigationLink(value: tx)`, so the
    /// screen the user drilled into was a dead end. Both of those are what the
    /// assertions below are for.
    func testTappingACategoryOpensTheFeedFilteredToIt() {
        let app = launch("3")
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        let slice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stats.slice.'")).firstMatch
        XCTAssertTrue(slice.waitForExistence(timeout: 3))
        let category = String(slice.identifier.dropFirst("stats.slice.".count))
        XCTAssertFalse(category.isEmpty, "the slice must name the category it drills into")
        assertLive(slice)
        slice.tap()

        XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))

        // The count comes from `feed.count`'s accessibilityValue — the raw
        // number the view computed, not a tally of whatever rows the lazy
        // container happened to materialise.
        let count = Int(app.marker("feed.count").value as? String ?? "") ?? 0
        XCTAssertGreaterThan(count, 0, "the slice claimed a share of the spending; the feed must show it")
        XCTAssertFalse(app.marker("feed.empty").exists)

        // Filtering, asserted rather than assumed: every row's subtitle is
        // "<категорія> · HH:mm", so a feed that ignored `initialCategory` shows
        // the whole month and trips this on the first row of another category.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertGreaterThan(rows.count, 0)
        for index in 0..<min(rows.count, 6) {
            let row = rows.element(boundBy: index)
            XCTAssertTrue(row.label.contains(category),
                          "row \(index) is not in \(category): \(row.label)")
        }

        // The most important line here. Every row of this feed was inert and
        // nothing caught it, because the test stopped at the screen's title.
        let first = rows.element(boundBy: 0)
        assertLive(first)
        first.tap()
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3),
                      "the drilled-into feed's rows must open the transaction, not sit dead")
    }

    /// The seed's one fuel purchase carrying a receipt — same fixture
    /// `SplitTests` drives — but that receipt ships ATTACHED, not CONFIRMED.
    /// Until it is confirmed no transaction carries splits, so
    /// `Derived.byProductGroup` returns a single «Без чека» slice at 100%
    /// and «За чеками» would look different from «Загальна» without proving
    /// the switch does anything. Confirming it first is what makes the
    /// assertions below actually exercise `byProductGroup`.
    private static let fuelTxId = "551DCED6-6D40-5401-AAA6-50D42F5336A2"
    /// Its SPENDING category. Every feed lookup here narrows by this rather
    /// than by the seller: `demo.json`'s merchants come off the owner's own
    /// bank statement and the standing privacy rule keeps them out of
    /// source — see `SplitTests` and the pytest guard that enforces it.
    /// `Derived.search` matches merchant **or** category, and the row itself
    /// is identified by its transaction UUID, so the query only has to make
    /// the row cheap to reach, not unique.
    private static let fuelCategory = "Автомобіль"
    private static let fuelProductName = "Бензин А-95-Євро5"

    /// The seed's SECOND pre-attached receipt: a car wash, 2026-07-24,
    /// 145,80 ₴, itemised to exactly the charge. `ProductGuess` files
    /// «Мийка автомобіля» under `fuelGroup` — the same product group as the
    /// petrol above — so both are contributions to ONE slice, in two
    /// different months. That is what makes a period filter provable:
    /// without a second month's contribution in the same group, a filtered
    /// drill and an unfiltered one return the identical single row.
    ///
    /// It carries no fuel GRADE, so `FuelGrade.parse` rejects it and every
    /// Заправки assertion in this file is unaffected by it.
    private static let washTxId = "E9D0F6EB-4061-5ED2-A17F-32F1E4BA4DC3"
    private static let washCategory = "Автомобіль"
    private static let washProductName = "Мийка автомобіля"

    /// Reaches one seeded purchase in the feed (tab 1): narrow to its
    /// spending category, then step back through months until the row's own
    /// `feed.row.<uuid>` appears.
    ///
    /// Narrowed with the FILTER SHEET, not the search field, and that is not
    /// a preference. `.searchable` takes over the navigation bar while a
    /// search is active — iOS hides the screen's own toolbar, the month
    /// stepper included, and swaps in its own Close control. A first lookup
    /// therefore leaves the stepper unreachable for the second, which is
    /// exactly what the two-month fixture below needs. Observed, not
    /// assumed: `feed.month` was simply absent on the second call.
    /// `feed.filter` is a sheet — it narrows the list and leaves the
    /// toolbar where it was.
    ///
    /// No keyboard is involved either, which retires the "the keyboard
    /// occludes the tab bar" workaround this file used to need.
    @discardableResult
    private func openFeedRow(_ app: XCUIApplication, txId: String, category: String) -> XCUIElement {
        app.tabBars.buttons["Стрічка"].tap()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))

        // `FeedView`'s filter is `@State` and this screen is never torn down
        // between calls, so a previous call's category is still applied.
        // Its own chip clears it.
        let clearAll = app.buttons["feed.filter.clearAll"]
        if clearAll.exists { clearAll.tap() }

        let filter = app.buttons["feed.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        assertLive(filter)
        filter.tap()
        XCTAssertTrue(app.marker("filter.sheet").waitForExistence(timeout: 3))
        let categoryRow = app.buttons["filter.category.\(category)"]
        // Scroll until it EXISTS, not until it is hittable. A `List` is lazy:
        // a row below the fold is not merely untappable, it is absent from the
        // tree — so the old order (assert existence, then scroll) could only
        // work while Категорії happened to start just above the fold. Board
        // #110 added two rows over it and that stopped being true, which is
        // the whole reason this loop moved above the assertion.
        for _ in 0..<6 where !categoryRow.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 3),
                      "precondition: the filter sheet must offer \(category)")
        for _ in 0..<4 where !categoryRow.isHittable { app.collectionViews.firstMatch.swipeUp() }
        assertLive(categoryRow)
        categoryRow.tap()
        app.buttons["filter.done"].tap()

        let row = app.marker("feed.row.\(txId)")
        var found = false
        for _ in 0..<12 {
            if row.waitForExistence(timeout: 2) { found = true; break }
            let prev = app.buttons["feed.prevMonth"]
            guard prev.exists, prev.isEnabled else { break }
            prev.tap()
        }
        if !found {
            XCTAssertTrue(row.waitForExistence(timeout: 2),
                          "precondition: the seeded purchase must be reachable")
        }
        for _ in 0..<3 where !row.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        return row
    }

    /// Expands one seeded purchase's receipt in the feed and confirms it,
    /// accepting the pre-filled group guess rather than picking a different
    /// one — these tests need the transaction to carry a split, not which
    /// group it lands in.
    private func confirmSeededReceipt(_ app: XCUIApplication, txId: String, category: String) {
        openFeedRow(app, txId: txId, category: category)

        let expand = app.buttons["feed.expand.\(txId)"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.tap()

        XCTAssertTrue(app.marker("feed.items.\(txId)").waitForExistence(timeout: 3),
                      "precondition: the disclosure must expand the row in place")

        // Keyed by the receipt's own id (`receipt.confirm.<receiptId>`),
        // matched by prefix — only one row is expanded at a time here, so
        // `firstMatch` is the button of the row just expanded.
        let confirm = app.confirmButton()
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        if !confirm.isHittable { app.scrollViews.firstMatch.swipeUp() }
        confirm.tap()
        XCTAssertFalse(app.splitRefusal().exists,
                       "precondition: this receipt itemises exactly its own charge")
    }

    private func confirmSeededFuelReceipt(_ app: XCUIApplication) {
        confirmSeededReceipt(app, txId: Self.fuelTxId, category: Self.fuelCategory)
    }

    /// The pre-filled keyword guess for the seeded fuel receipt's one item
    /// («Бензин А-95-Євро5») — `SplitTests` pins this same string as a
    /// precondition on `receipt.item.group.<fuelItemId>`'s label before
    /// confirming. `confirmSeededFuelReceipt` accepts it as-is, so after
    /// confirming this is the ONE product group in the whole dataset with
    /// a split in it.
    private static let fuelGroup = "Пальне та автотовари"

    /// The switch itself, end to end. Confirms the seeded receipt first (see
    /// `confirmSeededFuelReceipt`) so `byProductGroup` has something besides
    /// «Без чека» to show, then switches to «Рік» so the fuel purchase
    /// (2026-08-19) is included regardless of which month `StatsView`
    /// currently treats as "current" — this screen has no month stepper of
    /// its own, only `.month`/`.week`/`.year` scopes, and `.month` always
    /// tracks `months.last` rather than a month a test can pick. Trusting
    /// that default to already land on August would be exactly the "reads
    /// today in disguise" trap `SplitTests` warns about for the feed's own
    /// default month; `.year` sidesteps it by construction — it is
    /// `store.transactions` with no month filter at all.
    ///
    /// Asserts existence of `stats.slice.\(fuelGroup)`, NOT that "the top
    /// slice's label differs between modes" — the seed's one confirmed 800 ₴
    /// receipt is a sliver of even a single week's spending (≈4.7%, worse
    /// over a month or year), so «Без чека» stays the largest slice by sum in
    /// every scope this screen offers, confirmed or not. Comparing the
    /// TOP-ranked label between modes would therefore be true whether or not
    /// the receipt was ever confirmed — «Без чека» (receipts) never equals
    /// whatever spending category tops `byCategory` (general) either way —
    /// which is exactly the "passes for a switch that does nothing" trap.
    /// Asserting the confirmed group's OWN slice exists is what actually
    /// depends on the confirmation above.
    /// Board #24's gate, from the other side. `byProductGroup` files every
    /// UNSPLIT purchase under «Без чека», so before anything is confirmed
    /// «За чеками» could only ever draw a donut that is 100% «Без чека» — an
    /// empty mode wearing a full one's clothes, and the second of two stacked
    /// segmented controls eating the top of the screen to offer it.
    ///
    /// The demo seed ships six attached receipts and **zero** confirmed
    /// splits, which is exactly the state a real person is in until they
    /// answer a receipt: the picker must not be there.
    /// `testSwitchingModeShowsTheConfirmedProductGroup` below is the positive
    /// half — it confirms one first, and the picker appears.
    func testTheReceiptsModeIsNotOfferedUntilAReceiptIsConfirmed() {
        let app = launch("3")
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))

        // The scope picker IS there — so "nothing rendered" cannot be what
        // this test is measuring.
        assertLive(app.buttons["Місяць"])
        XCTAssertFalse(app.marker("stats.mode").exists,
                       "«За чеками» has nothing to slice until a receipt is confirmed")
        XCTAssertFalse(app.buttons["За чеками"].exists)
    }

    /// Board #59. `Card` is a leading-aligned `VStack`, and the donut's stack
    /// was given a height and no width — so it sized to its content and sat
    /// against the left edge of a full-width card, off centre from the bars
    /// above it and the legend below.
    ///
    /// Geometry, not an identifier: this is the one kind of defect an
    /// existence check cannot see, and `frame` is what XCUITest exposes of it.
    /// Two points of slack because a ring drawn with a 34pt stroke reports a
    /// frame that need not land on an exact half-pixel.
    func testTheDonutIsCentredInItsCard() {
        let app = launch("3")
        let donut = app.marker("stats.donut")
        XCTAssertTrue(donut.waitForExistence(timeout: 5))

        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(donut.frame.midX, screen.midX, accuracy: 2,
                       "the donut is off centre: \(donut.frame) in \(screen)")
    }

    func testSwitchingModeShowsTheConfirmedProductGroup() {
        let app = launch("1")
        confirmSeededFuelReceipt(app)

        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["Рік"])
        app.buttons["Рік"].tap()

        // The mode picker's own required identifiers, found BY identifier —
        // every tap below finds these two segments by their Ukrainian LABEL
        // instead (which XCUITest also matches against), so those taps alone
        // would not notice `stats.mode`/`stats.mode.general`/
        // `stats.mode.receipts` going missing.
        XCTAssertTrue(app.marker("stats.mode").exists)
        XCTAssertTrue(app.marker("stats.mode.general").exists)
        XCTAssertTrue(app.marker("stats.mode.receipts").exists)

        assertLive(app.buttons["Загальна"])
        assertLive(app.buttons["За чеками"])
        // `-resetState` DOES clear `stats.bySplits` — `AppStore.live()`
        // removes that `UserDefaults` key on the reset path, added in the
        // same commit as the mode picker itself, for exactly this reason.
        // (An earlier version of this comment claimed the opposite; the
        // code is the authority.) The explicit tap stays anyway: it is the
        // one line here that does not depend on that reset staying in
        // place, so the test keeps working if the key is ever left alone
        // again, and it makes the starting mode a fact of this test rather
        // than of a launch argument two files away.
        app.buttons["Загальна"].tap()

        // Negative half, in the SPENDING-category namespace: a product
        // group name must never appear as a spending-category slice.
        XCTAssertFalse(app.marker("stats.slice.\(Self.fuelGroup)").exists,
                       "precondition: this list slices by spending category, not product group")

        app.buttons["За чеками"].tap()

        // «Рік» stacks the scope and mode pickers, `totalCard`, a 12-bar
        // `barsCard` and the donut all above the share list — tall enough
        // that its rows render at rest under the floating tab bar, present
        // in the tree but not hittable. Same reasoning `SplitTests` uses for
        // the detail screen's receipt card; a real user scrolls, so does this.
        app.scrollViews.firstMatch.swipeUp()

        // Positive half: the confirmed receipt's own product group now
        // exists as its own slice.
        let group = app.marker("stats.slice.\(Self.fuelGroup)")
        XCTAssertTrue(group.waitForExistence(timeout: 3),
                      "the confirmed receipt's product group must appear once it is confirmed")
        assertLive(group)
    }

    /// The drill-through, in BOTH modes — the exact trap this repo has
    /// already shipped once: a typed `NavigationPath` silently ignores a
    /// route it was not declared with, so a row can look tappable and still
    /// be a dead end. `path` here is untyped, but the brief is explicit that
    /// this must be verified, not assumed.
    func testTappingASliceInEachModeOpensItsOwnDrill() {
        let app = launch("1")
        confirmSeededFuelReceipt(app)

        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["Рік"])
        app.buttons["Рік"].tap()
        // Same reasoning as `testSwitchingModeShowsTheConfirmedProductGroup`:
        // the mode is tapped rather than assumed, so this test does not
        // depend on `-resetState` continuing to clear `stats.bySplits`.
        assertLive(app.buttons["Загальна"])
        app.buttons["Загальна"].tap()
        // «Рік» stacks enough above the share list (both pickers, the total,
        // a 12-bar chart, the donut) that its rows render at rest under the
        // floating tab bar — present in the tree but not hittable. Same
        // reasoning `SplitTests` uses for the detail screen's receipt card.
        app.scrollViews.firstMatch.swipeUp()

        // «Загальна» drills into the feed (CategoryDrill) — unchanged.
        let generalSlice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stats.slice.'")).firstMatch
        XCTAssertTrue(generalSlice.waitForExistence(timeout: 3))
        assertLive(generalSlice)
        generalSlice.tap()
        XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3),
                      "«Загальна» must still drill into the feed")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // «За чеками» drills into ContributionsView (ContributionDrill) — new.
        // The confirmed group's OWN slice, not merely the first one found:
        // that would be «Без чека» (it dominates every scope this screen
        // offers — see `testSwitchingModeShowsTheConfirmedProductGroup`),
        // whose contributions list would be some large, non-deterministic
        // number of unsplit rows. `fuelGroup` has exactly ONE contribution
        // in the whole seed — the confirmed split itself — which is what
        // lets the assertion below name it precisely.
        app.buttons["За чеками"].tap()
        app.scrollViews.firstMatch.swipeUp()
        let receiptSlice = app.marker("stats.slice.\(Self.fuelGroup)")
        XCTAssertTrue(receiptSlice.waitForExistence(timeout: 3))
        assertLive(receiptSlice)
        receiptSlice.tap()
        XCTAssertTrue(app.marker("contributions.title").waitForExistence(timeout: 3),
                      "«За чеками» must drill into the contributions screen, not sit dead")

        let firstContribution = app.marker("stats.contribution.0")
        XCTAssertTrue(firstContribution.waitForExistence(timeout: 3),
                      "the contributions list must actually list at least one row")
        assertLive(firstContribution)
        // The confirmed split's own product NAME, not the merchant — proof
        // this is really `Derived.contributions`' SPLIT branch (named by
        // `split.name`), not its unsplit-transaction branch (named by
        // `tx.merchant`), which only fires for `noReceipt`.
        XCTAssertEqual(firstContribution.label, "Бензин А-95-Євро5",
                       "the one confirmed split's own product name must be the row's name")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // `ContributionDrill` carries the PERIOD `StatsView` just summed;
        // every assertion above ran in `.year` scope, where that is nil (the
        // whole dataset). The seed's newest month is August 2026 (a fact of
        // the committed, static `demo.json`, not of the wall clock — the
        // same fact `SplitTests` already leans on for its own default-month
        // reachability), so `.month` scope's `current` deterministically
        // includes the confirmed fuel purchase here too.
        //
        // The earlier `.year` checks scrolled well down to reach the share
        // list (a 12-bar chart plus both pickers, the total and the donut
        // all sit above it there), and that scroll offset survives popping
        // back — the `ScrollView` was never torn down. The SCOPE picker
        // itself sits at the very top of the stack, so it is what is
        // currently scrolled out of view, not the slice below it.
        // `swipeDown()` back to the top before touching it, same "scroll
        // only if actually needed" reasoning as everywhere else, applied to
        // the control this step needs first.
        if !app.buttons["Місяць"].isHittable { app.scrollViews.firstMatch.swipeDown() }
        assertLive(app.buttons["Місяць"])
        app.buttons["Місяць"].tap()
        let monthReceiptSlice = app.marker("stats.slice.\(Self.fuelGroup)")
        XCTAssertTrue(monthReceiptSlice.waitForExistence(timeout: 3))
        if !monthReceiptSlice.isHittable { app.scrollViews.firstMatch.swipeUp() }
        assertLive(monthReceiptSlice)
        monthReceiptSlice.tap()
        XCTAssertTrue(app.marker("contributions.title").waitForExistence(timeout: 3),
                      "«За чеками» must drill through in «Місяць» scope too")
        let monthContribution = app.marker("stats.contribution.0")
        XCTAssertTrue(monthContribution.waitForExistence(timeout: 3))
        assertLive(monthContribution)
        XCTAssertEqual(monthContribution.label, "Бензин А-95-Євро5")
    }

    /// BLOCKING: the «За чеками» drill must list exactly the rows its slice
    /// summed — in EVERY scope, `.week` included.
    ///
    /// It did not. `ContributionDrill` was built with
    /// `scope == .month ? current : nil`, copied from the `CategoryDrill`
    /// line below it, but nil means opposite things in the two
    /// destinations: `CategoryDrill(month: nil)` opens `FeedView`, which
    /// falls back to its own newest month and shows ONE month, while
    /// `ContributionDrill(month: nil)` reached `store.transactions` — all
    /// 772 rows of all eight months. Correct by accident in `.year`, plainly
    /// wrong in `.week`: two taps from a cold Статистика gave you a list
    /// spanning the whole dataset under a slice showing one week's spend.
    ///
    /// The fixture is the seed's two pre-attached receipts, one per month —
    /// 2026-08-19 (fuel, 800,00 ₴) and 2026-07-24 (a car wash, 145,80 ₴).
    /// `ProductGuess` files both under `fuelGroup`, so BOTH are contributions
    /// to the same slice and the only thing that can separate them is the
    /// period. Confirmed here in the feed, because a receipt only becomes a
    /// split when a human confirms it.
    ///
    /// Three scopes, one assertion each, and they are not interchangeable:
    /// `.year` proves the fixture really does have two rows (without it,
    /// every "exactly one row" below would pass against a drill that lost
    /// the July receipt for some unrelated reason), while `.week` and
    /// `.month` prove the period is actually applied.
    func testTheReceiptsDrillListsOnlyThePeriodItsSliceSummed() {
        let app = launch("1")
        confirmSeededFuelReceipt(app)
        confirmSeededReceipt(app, txId: Self.washTxId, category: Self.washCategory)

        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["За чеками"])
        app.buttons["За чеками"].tap()

        // «Рік» — the whole dataset, so BOTH months' contributions.
        openReceiptsDrill(app, scope: "Рік")
        XCTAssertEqual(app.marker("stats.contribution.0").label, Self.fuelProductName,
                       "largest first: the 800,00 ₴ fill-up")
        let second = app.marker("stats.contribution.1")
        XCTAssertTrue(second.waitForExistence(timeout: 3),
                      "precondition: the fixture must really have a second, July contribution — "
                      + "without it the two assertions below prove nothing")
        XCTAssertEqual(second.label, Self.washProductName)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // «Тиждень» — the seven Kyiv days ending on the dataset's last
        // transaction (2026-08-21), which contains 2026-08-19 and cannot
        // contain anything from July. THE assertion this test exists for.
        openReceiptsDrill(app, scope: "Тиждень")
        XCTAssertEqual(app.marker("stats.contribution.0").label, Self.fuelProductName)
        XCTAssertFalse(app.marker("stats.contribution.1").exists,
                       "a week's slice must not drill into another month's purchases")

        app.navigationBars.buttons.element(boundBy: 0).tap()

        // «Місяць» — August 2026 (`months.last` for this frozen seed), same
        // exclusion for a different period.
        openReceiptsDrill(app, scope: "Місяць")
        XCTAssertEqual(app.marker("stats.contribution.0").label, Self.fuelProductName)
        XCTAssertFalse(app.marker("stats.contribution.1").exists,
                       "a month's slice must not drill into another month's purchases")
    }

    /// Selects a scope on Статистика and drills into `fuelGroup`'s slice.
    ///
    /// The scroll dance is the same one the other drill test documents: the
    /// scope picker sits at the very top of a tall stack and the share list
    /// well below it, a popped drill restores the offset it left, and both
    /// controls are only scrolled to when they are not already live.
    private func openReceiptsDrill(_ app: XCUIApplication, scope: String) {
        if !app.buttons[scope].isHittable { app.scrollViews.firstMatch.swipeDown() }
        assertLive(app.buttons[scope])
        app.buttons[scope].tap()

        let slice = app.marker("stats.slice.\(Self.fuelGroup)")
        XCTAssertTrue(slice.waitForExistence(timeout: 3),
                      "precondition: \(scope) must show a \(Self.fuelGroup) slice to drill into")
        for _ in 0..<3 where !slice.isHittable { app.scrollViews.firstMatch.swipeUp() }
        assertLive(slice)
        slice.tap()

        XCTAssertTrue(app.marker("contributions.title").waitForExistence(timeout: 3),
                      "«За чеками» must drill into the contributions screen in \(scope) scope")
        XCTAssertTrue(app.marker("stats.contribution.0").waitForExistence(timeout: 3),
                      "the contributions list must actually list a row in \(scope) scope")
        assertLive(app.marker("stats.contribution.0"))
    }

    /// Task 9's Заправки card, present half. The seeded fuel purchase
    /// (2026-08-19, 10,00 л Бензин А-95-Євро5 at 80,00 ₴/л, 800,00 ₴ total —
    /// see `task-9-brief.md`'s fixture facts) needs no confirmation to show
    /// here, unlike `fuelGroup` above: `Derived.fillUps` only requires the
    /// receipt to be ATTACHED, which the seed already ships.
    ///
    /// `.month` is tapped explicitly rather than trusted as the `@State`
    /// default — the exact same reasoning `testSwitchingModeShowsTheConfirmedProductGroup`
    /// gives for `.year` there: a future refactor of the default must not
    /// silently start passing this test for the wrong reason. `current`
    /// (`months.last`) is deterministically August 2026 for this frozen
    /// seed, which is what makes `.month` reliably include 2026-08-19
    /// without reading "today".
    func testFuelCardShowsTheSeededFillUp() {
        let app = launch("3")
        // Board #24 stopped offering «За чеками» until some receipt has been
        // CONFIRMED — until then it can only draw «Без чека — 100%». The
        // independence check at the end of this test switches modes, so this
        // test now has to earn the picker. It also strengthens that check:
        // with a split in the data «За чеками» genuinely differs from
        // «Загальна», so "the fuel card is identical in both" is a claim
        // about something rather than about two identical screens.
        confirmSeededFuelReceipt(app)
        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["Місяць"])
        app.buttons["Місяць"].tap()
        app.scrollViews.firstMatch.swipeUp()

        // The exact string `fuelCard` builds from the ONE seeded fill-up:
        // 10,00 л (no seed rounding — `qty` drops a whole number's
        // fraction), 800,00 ₴ total, 80,00 ₴/л weighted average (both
        // trivially equal to the single fill's own price here). Asserting
        // the literal label — not merely `.exists` — is what actually
        // proves the litres/total/average arithmetic, not just that SOME
        // card rendered.
        let expectedSummary = "10 л · 800,00 ₴ · середня 80,00 ₴/л"
        let summary = app.marker("stats.fuel.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertEqual(summary.label, expectedSummary)

        // The one row this month has — its own identity is the GRADE,
        // mirroring `stats.contribution.<index>` sitting on the product
        // NAME one card over.
        let row = app.marker("stats.fuel.row.0")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(row.label, "А-95")
        assertLive(summary)
        assertLive(row)

        // The row's other five fields — station, date, litres, price/л and
        // total — carry no identifier of their own (a leaf only, per the
        // accessibility rule; the grade above is this row's one identified
        // leaf), but every one of them is a known value from the same
        // fixture: «АЗС «Приклад»», 2026-08-19, 10,00 л, 80,00 ₴/л,
        // 800,00 ₴. Asserting `row.label == "А-95"` alone proves a card
        // rendered and named the right grade; it proves nothing about
        // whether the station is real, the date is right, or litres and
        // the total weren't swapped — checking the literal text of each
        // does. `app.staticTexts["…"]` matches on the rendered text the
        // same way `DetailTests` already does for un-identified `Text`
        // views (e.g. «Чек не додано»), not on an accessibility identifier.
        XCTAssertTrue(app.staticTexts["АЗС «Приклад» · 19 серпня"].waitForExistence(timeout: 2),
                      "row must show the seeded station and date, not a placeholder")
        XCTAssertTrue(app.staticTexts["800,00 ₴"].waitForExistence(timeout: 2),
                      "row must show the fill-up's own total")
        XCTAssertTrue(app.staticTexts["10 л · 80,00 ₴/л"].waitForExistence(timeout: 2),
                      "row must show litres and price per litre, not swapped with each other")

        // Independence from `bySplits`, proved rather than merely never
        // referenced: fuel is read straight off receipt items and does not
        // depend on anything having been confirmed, so this card must
        // render identically whichever mode «Статистика» is in. Extending
        // THIS test rather than adding a third — same card, same screen
        // state, one more assertion after the mode switch.
        if !app.buttons["stats.mode.receipts"].isHittable { app.scrollViews.firstMatch.swipeDown() }
        assertLive(app.buttons["stats.mode.receipts"])
        app.buttons["stats.mode.receipts"].tap()
        app.scrollViews.firstMatch.swipeUp()
        let summaryAfterSwitch = app.marker("stats.fuel.summary")
        XCTAssertTrue(summaryAfterSwitch.waitForExistence(timeout: 3),
                      "the fuel card must still be present in «За чеками»")
        XCTAssertEqual(summaryAfterSwitch.label, expectedSummary,
                       "the fuel card must not react to the mode switch at all")
    }

    /// Task 9's Заправки card, absent half. StatsView has no month stepper
    /// of its own (unlike `FeedView`/`BudgetView`) — `.month`'s `current`
    /// always resolves to `months.last`, which for this seed is always
    /// August 2026, the one month that HAS the seeded fill-up, in every one
    /// of the three scopes this screen offers (`.week`'s window ends on the
    /// dataset's own last transaction, `.year` is the whole dataset
    /// unfiltered). There is no reachable scope selection on this screen
    /// where the card is absent while the fixture stands.
    ///
    /// So this proves absence the other way the brief's own vocabulary
    /// points at — "no fuel receipt ATTACHED" — using the real, existing
    /// «Відкріпити» control on the transaction's own detail screen
    /// (`detail.receipt.detach`, wired to `AppStore.detachReceipt`). The
    /// seed has TWO transactions with `receiptId` set — this fuel fill-up
    /// and the July car wash `testTheReceiptsDrillListsOnlyThePeriodItsSliceSummed`
    /// drives (the other four receipts in the seed are never attached to any
    /// transaction) — but only one of those two is a FUEL receipt. The car
    /// wash's item names no grade, so `FuelGrade.parse` finds nothing and
    /// `Derived.fillUps` ignores it regardless of attachment; it is not part
    /// of this test's fixture and detaching the fuel receipt alone is
    /// therefore enough to leave the dataset with no fuel receipt attached
    /// to anything, in any month, which is what the brief's "verified, not
    /// assumed" instruction asks for.
    func testFuelCardIsAbsentAfterDetachingTheOnlyFuelReceipt() {
        let app = launch("1")
        let row = openFeedRow(app, txId: Self.fuelTxId, category: Self.fuelCategory)
        row.tap()

        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        XCTAssertTrue(app.marker("detail.receipt").waitForExistence(timeout: 3))
        // Same reasoning as `DetailTests`' own receipt-card assertions: the
        // card sits last on the screen, under the floating tab bar at rest.
        app.scrollViews.firstMatch.swipeUp()
        let detach = app.buttons["detail.receipt.detach"]
        XCTAssertTrue(detach.waitForExistence(timeout: 2),
                      "precondition: the seeded purchase must still carry its receipt")
        assertLive(detach)
        detach.tap()
        // The card's own empty state, proof the detach actually took —
        // not just that the button was tappable. No live control to check
        // instead: Task 13 removed the detail screen's own "Додати чек" —
        // scanning moved to Розібрати (D2) — so the empty state is text alone now.
        XCTAssertTrue(app.staticTexts["Чек не додано"].waitForExistence(timeout: 3),
                      "precondition: detaching must leave the receipt card empty")

        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["stats.total"].waitForExistence(timeout: 5))
        assertLive(app.buttons["Місяць"])
        app.buttons["Місяць"].tap()
        app.scrollViews.firstMatch.swipeUp()

        XCTAssertFalse(app.marker("stats.fuel.summary").exists,
                       "no transaction anywhere in the dataset carries a fuel receipt now")
        XCTAssertFalse(app.marker("stats.fuel.row.0").exists)
    }

    func testTheThreeNewSettingsScreensOpen() {
        let app = launch("0")
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        for (row, screen) in [("settings.open.categories", "settings.categories"),
                              ("settings.open.data", "settings.data"),
                              ("settings.open.about", "settings.about")] {
            app.buttons["home.settings"].tap()
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 3))
            app.buttons[row].tap()
            XCTAssertTrue(app.marker(screen).waitForExistence(timeout: 3),
                          "\(row) did not open \(screen)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    /// Board #94. Income used to be decided by matching a category NAME
    /// against a hardcoded set, so a category somebody made could never be
    /// income and renaming a seeded one silently re-based the budget.
    ///
    /// The walk is the proof the unit tests cannot give: that the control is
    /// reachable by TAPPING an ordinary row — not hidden behind a third swipe
    /// action, where a full swipe would delete the category instead — and that
    /// the choice survives back into what the row shows.
    func testACategoryCanBeMadeIncomeFromSettings() {
        let app = launch("0")
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.categories"].tap()
        XCTAssertTrue(app.marker("settings.categories").waitForExistence(timeout: 5))

        // «Автомобіль» rather than a name further down: this is a `List`, which
        // materialises only the rows on screen. It is also a seeded SPENDING
        // category, so it carries no badge to begin with — which is what makes
        // the badge at the end an assertion and not a coincidence.
        let row = app.buttons["settings.categories.row.Автомобіль"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Дохід"), "precondition: \(row.label)")
        row.tap()

        let picker = app.marker("category.kind")
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "the kind belongs on the sheet the row's own tap opens")
        let earned = app.buttons["Дохід"]
        XCTAssertTrue(earned.waitForExistence(timeout: 3))
        assertLive(earned)
        earned.tap()

        // Back to the list, and the row now says what the category is.
        app.buttons["icons.done"].firstMatch.tap()
        let changed = app.buttons["settings.categories.row.Автомобіль"]
        XCTAssertTrue(changed.waitForExistence(timeout: 5))
        XCTAssertTrue(changed.label.contains("Дохід"),
                      "the row must say what the category now is: " + changed.label)
    }
}
