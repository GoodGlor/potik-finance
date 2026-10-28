import XCTest

final class BudgetTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "2", "-lang", "uk"]
        app.launch()
        return app
    }

    func testTheTabOffersToBuildAPlanWhenThereIsNone() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Плану ще немає"].waitForExistence(timeout: 5))
        assertLive(app.buttons["budget.create"],
                      "the button is live now — stage 3 shipped it disabled on purpose")
    }

    /// The whole loop: no plan → starter → saved → real rows on the tab.
    func testBuildingTheStarterPlanFillsTheTab() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()

        XCTAssertTrue(app.marker("editor.title").waitForExistence(timeout: 3))
        // Exact equality, not `contains("100%")`: the empty-plan string
        // «Розподілено 0% · залишилось 100%» contains "100%" too, so the
        // looser check passed on a plan allocating nothing at all.
        XCTAssertEqual(app.staticTexts["editor.total"].label, "Розподілено 100%",
                       "the starter plan is offered complete")
        XCTAssertTrue(app.buttons["editor.save"].isEnabled)
        app.buttons["editor.save"].tap()

        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["budget.row.Продукти"].exists)
        XCTAssertTrue(app.staticTexts["budget.row.Заощадження"].exists,
                      "the savings line must render even though the seed has no such category")
        XCTAssertFalse(app.buttons["budget.create"].exists, "the empty state is gone")

        // The tab's own top drift card. Deterministic on the seed rather than
        // hopeful: with the starter plan's 3-month average base the savings
        // line is planned ~9 340 ₴ (board #23 raised it from 10% to 20%) and
        // August's income minus spend leaves ~2 116 ₴, so it is under plan —
        // and in a month with no data at all (the calendar rolling past the
        // seed) actual is 0 against a positive plan, so it is under plan then
        // too. Both spending lines are well below their share, so savings is
        // also the WORST drift and this card is the one place its sentence
        // appears. Re-checked against the new starter, not assumed.
        XCTAssertTrue(app.marker("budget.drift").waitForExistence(timeout: 3),
                      "a drifting plan must be called out at the top of the tab")
        XCTAssertEqual(app.staticTexts["budget.drift.category"].label,
                       "Заощадження",
                       "the card names its subject — driftText leaves the savings line's out")
        XCTAssertTrue(app.staticTexts["budget.drift.text"].label.contains("запланованих"),
                      app.staticTexts["budget.drift.text"].label)
        // …and exactly once: the row for that same line must not reprint it.
        XCTAssertFalse(app.staticTexts["budget.drift.Заощадження"].exists,
                       "the worst drift belongs to the top card; the row must not repeat it")

        // The starter plan covers three categories; the seed ships nineteen
        // and a seeded month has spending well outside those three, so the
        // «Поза планом» total must be both present and reachable — this is
        // what proves the identifier is not smothered by its own card.
        //
        // STEP BACK ONE MONTH FIRST, and do not "simplify" this tap away.
        // The tab opens on the current CALENDAR month, which is not the same
        // thing as the newest month with data: the seed's last transaction is
        // 2026-08-21, so from 1 September onwards the month this test lands on
        // has no rows at all, no unplanned spend, and no «Поза планом» card to
        // find. One step back is a seeded month in both regimes — 2026-07
        // before the rollover, 2026-08 after it — and both have spend outside
        // the starter plan's four categories.
        app.buttons["budget.prevMonth"].tap()
        XCTAssertTrue(app.staticTexts["budget.unplanned.total"].waitForExistence(timeout: 3),
                      "spend outside the plan must be reported, and reachable by identifier")
    }

    func testAnIncompletePlanCannotBeSaved() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.marker("editor.title").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["editor.save"].isEnabled, "precondition: starts complete")

        app.buttons["editor.delete.Продукти"].tap()

        XCTAssertTrue(app.staticTexts["editor.total"].label.contains("залишилось 35%"),
                      app.staticTexts["editor.total"].label)
        XCTAssertFalse(app.buttons["editor.save"].isEnabled,
                       "65% is not a plan and must not be savable")
    }

    func testThePlanSurvivesLeavingAndReturningToTheTab() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.buttons["editor.save"].waitForExistence(timeout: 3))
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))

        app.tabBars.buttons["Головна"].tap()
        app.tabBars.buttons["Бюджет"].tap()

        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["budget.create"].exists)
    }

    func testPastMonthsAreBrowsable() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.buttons["editor.save"].waitForExistence(timeout: 3))
        app.buttons["editor.save"].tap()

        let month = app.staticTexts["budget.month"]
        XCTAssertTrue(month.waitForExistence(timeout: 3))
        let shown = month.label

        // The tab opens on the current month, which is the one month the plan
        // may be edited from.
        XCTAssertTrue(app.buttons["budget.edit"].waitForExistence(timeout: 3),
                      "the current month must offer «Змінити»")

        app.buttons["budget.prevMonth"].tap()
        XCTAssertNotEqual(app.staticTexts["budget.month"].label, shown,
                          "the stepper must actually move the month it reports")

        // Board #62 changed the REASON, not the rule. It used to be that one
        // stored plan meant editing from March would rewrite what August was
        // measured against. Now each month keeps the plan it had, so editing a
        // past one would be rewriting what actually happened. A conditional
        // `ToolbarItem` is exactly the sort of thing SwiftUI gets wrong
        // without saying so, which is why the assertion stays.
        XCTAssertTrue(app.buttons["budget.edit"].waitForNonExistence(timeout: 3),
                      "a past month must not offer to rewrite the plan it was lived under")

        // …and it is still MEASURED, against the earliest plan there is. The
        // app backfills months of history and the whole reason to look back is
        // to measure it; a "no plan yet" answer here would make the tab useful
        // for exactly the month the plan was written in. The label below says
        // which month's plan is being used, so nothing is implied.
        let label = app.staticTexts["budget.planMonth"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertNotEqual(label.label, "План на цей місяць",
                          "a past month must say whose plan it is being measured by")
    }

    /// Board #62's second criterion. The 1st has come round: the tab offers to
    /// keep last month's shares or to write new ones, and does neither by
    /// itself.
    ///
    /// `-stalePlan` is the only way in — a plan written during a test run
    /// belongs to the month the run is in, and no test can move the calendar.
    func testANewMonthOffersToCarryThePlanForwardOrReplan() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", "2", "-stalePlan", "-lang", "uk"]
        app.launch()

        XCTAssertTrue(app.marker("budget.monthlyDecision").waitForExistence(timeout: 8),
                      "a plan belonging to a month that is over must ask what happens next")
        // …and the month is measured meanwhile. An offer, not an interruption:
        // the old plan is still the newest one written on or before now.
        XCTAssertTrue(app.marker("budget.rows").exists,
                      "the tab must keep working while the offer is ignored")
        XCTAssertEqual(app.staticTexts["budget.planMonth"].label.hasPrefix("План за"), true,
                       "…and say whose plan it is using: "
                           + app.staticTexts["budget.planMonth"].label)

        let carry = app.buttons["budget.carryForward"]
        XCTAssertTrue(app.buttons["budget.replan"].exists, "both branches must be offered")
        assertLive(carry)
        carry.tap()

        XCTAssertTrue(app.marker("budget.monthlyDecision").waitForNonExistence(timeout: 3),
                      "the offer must go away once it is taken")
        XCTAssertEqual(app.staticTexts["budget.planMonth"].label, "План на цей місяць",
                       "carrying forward makes it this month's plan")
        XCTAssertTrue(app.marker("budget.rows").exists, "…with the same shares still measured")
    }

    /// Board #62's first criterion: the tab says which month the plan it is
    /// showing was written for, which the stepper alone cannot — the stepper
    /// says which month you are LOOKING at, and the two part company the
    /// moment there is more than one plan.
    func testTheTabSaysWhichMonthThePlanIsFor() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.buttons["editor.save"].waitForExistence(timeout: 3))
        app.buttons["editor.save"].tap()

        let label = app.staticTexts["budget.planMonth"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertEqual(label.label, "План на цей місяць",
                       "a plan written today belongs to today's month")
    }
}

extension BudgetTests {
    func testHomesCardStopsAdvertisingTheEmptyStateOnceAPlanExists() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.buttons["editor.save"].waitForExistence(timeout: 3))
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))

        app.tabBars.buttons["Головна"].tap()
        let card = app.buttons["home.budget.open"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))

        XCTAssertFalse(card.label.contains("Плану ще немає"),
                       "a plan exists; the card must stop inviting one: " + card.label)
        // Exactly one of the plan-present states, deterministic once a plan
        // is saved. Before this task the card says neither.
        //
        // The seed's August data + starter plan deterministically drift the
        // "Заощадження" (savings) line, not a spending line — its driftText
        // reads "...із запланованих...", not "...замість запланованих...".
        // The brief's original OR only covered the spending-drift wording;
        // this was verified against the actual seed data (see task-8-report).
        XCTAssertTrue(card.label.contains("План витримується")
                      || card.label.contains("запланованих"),
                      "the card must report the plan it now has: " + card.label)

        // And it still does the job the older test relies on.
        card.tap()
        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))
    }
}

extension BudgetTests {

    /// A numeric field has no clear button, so whatever is there is deleted
    /// first. Four deletes covers any 1–3 digit value.
    private func setPercent(_ app: XCUIApplication, _ category: String, to value: String) {
        let field = app.textFields["editor.percentField.\(category)"]
        XCTAssertTrue(field.waitForExistence(timeout: 2), "no percent field for \(category)")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        field.typeText(value)
    }

    /// Typing into a numeric field is only reliable once the keyboard is up.
    /// Characters sent before that are dropped and an early delete leaves the
    /// old value in place, so the two mistakes compound: this helper first
    /// sent «10000» to a field that took «10», then sent «3333» to a field
    /// that had never cleared and read back «33333». Waiting on the keyboard
    /// is what makes the clear-then-type sequence deterministic.
    private func replace(_ app: XCUIApplication, _ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // The trailing edge, not the middle. The ₴ field is right-aligned in
        // a wide frame, so a centre tap lands in the empty space BEFORE the
        // text and puts the caret at position 0 — where backspace deletes
        // nothing and the new digits are inserted in front of the old ones.
        // That is how «3333» typed over «3 000» read back as 33 333 000.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3),
                      "no keyboard, so nothing typed after this would land")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText(value)
    }

    private func setAmount(_ app: XCUIApplication, _ category: String, to value: String) {
        replace(app, app.textFields["editor.amountField.\(category)"], with: value)
    }

    /// Pins the income base to a typed sum, so nothing downstream depends on
    /// the seed's rolling 3-month average — which moves when the calendar
    /// rolls over and would time-bomb every figure below it.
    private func setFixedIncome(_ app: XCUIApplication, _ hryvnia: String) {
        app.buttons["editor.income"].tap()
        XCTAssertTrue(app.marker("income.title").waitForExistence(timeout: 3))
        app.buttons["Своя сума"].tap()
        replace(app, app.textFields["income.custom"], with: hryvnia)
        app.buttons["income.save"].tap()
        // The editor's own card, formatted by the app: proves the base really
        // is what was asked for before anything is measured against it.
        XCTAssertTrue(app.buttons["editor.income"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["editor.income"].label.contains("10 000"),
                      "income base did not take: " + app.buttons["editor.income"].label)
    }

    /// The reason this feature exists. 3 333 ₴ of a 10 000 ₴ base is 33,33% —
    /// a percentage no whole-number plan can hold, which before this change
    /// meant the amount was simply not a value the owner could ask for.
    ///
    /// Both lines are set by their ₴ figure and the plan still completes:
    /// 33,33% + 66,67% is exactly 100%. The load-bearing assertions are the
    /// app-generated ones — the footer and the saved rows' «План …%» — because
    /// a snap back to whole percents would leave the footer at 100% (33 + 67)
    /// and betray itself only in the rows.
    func testALineSetByItsAmountKeepsThatAmount() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.marker("editor.title").waitForExistence(timeout: 3))
        setFixedIncome(app, "10000")

        // Down to two lines, so both can be set by amount and still total 100.
        app.buttons["editor.delete.Квартплата"].tap()

        let products = app.textFields["editor.amountField.Продукти"]
        XCTAssertTrue(products.waitForExistence(timeout: 3))
        XCTAssertEqual(products.value as? String, 3500.formatted(.number),
                       "precondition: the starter's 35% of 10 000 ₴ is 3 500 ₴")

        setAmount(app, "Продукти", to: "3333")
        setAmount(app, BudgetMath_savings, to: "6667")

        // Продукти is no longer the focused field, so this is the binding's
        // own rendering rather than the text mid-edit.
        XCTAssertEqual(products.value as? String, 3333.formatted(.number),
                       "the line must still plan exactly what was typed")
        XCTAssertEqual(app.staticTexts["editor.total"].label, "Розподілено 100%",
                       "33,33% + 66,67% is a complete plan")
        XCTAssertTrue(app.buttons["editor.save"].isEnabled)
        app.buttons["editor.save"].tap()

        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["budget.plannedPercent.Продукти"].label, "План 33,3%",
                       "a whole-percent plan would say «План 33%»")
        XCTAssertEqual(app.staticTexts["budget.plannedPercent.\(BudgetMath_savings)"].label,
                       "План 66,7%")
    }

    /// The UI target does not link the app, so the savings category is spelled
    /// once here rather than reaching for `BudgetMath.savingsCategory`.
    private var BudgetMath_savings: String { "Заощадження" }

    private func createCategory(_ app: XCUIApplication, _ name: String) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(name)
        let create = app.buttons["picker.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 2),
                      "\(name) must be absent from the store for this test to mean anything")
        create.tap()
    }

    /// The novel category. Contains a digit so it can never collide with a
    /// real one, and so `typeText` commits reliably.
    private var freshCategory: String { "Резерв7" }

    private func openRow(_ app: XCUIApplication, at index: Int) {
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
            .element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
    }

    func testDetailFlagsThePurchaseThatTookALineOverAndOnlyThatOne() {
        let app = launch()
        XCTAssertTrue(app.buttons["budget.create"].waitForExistence(timeout: 5))
        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.marker("editor.title").waitForExistence(timeout: 3))

        // Income base of 1 ₴ = 100 minor units, so a 45% line plans 45 of
        // them — ₴0,45, not 0 ₴. That is the mechanism: the plan is not zero,
        // it is negligible next to any real purchase, and the row this test
        // moves is orders of magnitude larger than 30 копійок. It does depend
        // on the seed that far — on the moved row being a normal-sized
        // purchase — and on nothing else about it.
        app.buttons["editor.income"].tap()
        XCTAssertTrue(app.marker("income.title").waitForExistence(timeout: 3))
        app.buttons["Своя сума"].tap()
        let custom = app.textFields["income.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 2))
        custom.tap()
        custom.typeText("1")
        app.buttons["income.save"].tap()

        // Swap one line for a category nothing has ever been filed under,
        // keeping the total at exactly 100 so Save stays enabled.
        XCTAssertTrue(app.buttons["editor.delete.Квартплата"].waitForExistence(timeout: 3))
        app.buttons["editor.delete.Квартплата"].tap()
        app.buttons["editor.addLine"].tap()
        createCategory(app, freshCategory)
        setPercent(app, freshCategory, to: "45")

        // Exact, not `contains`: «Розподілено 0% · залишилось 100%» satisfies
        // `contains("100%")`, so the loose form would pass on an empty plan.
        XCTAssertEqual(app.staticTexts["editor.total"].label, "Розподілено 100%",
                       "precondition: the swap kept the plan complete")
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.marker("budget.rows").waitForExistence(timeout: 3))

        // A row that was NOT moved: nothing tipped, so nothing to say.
        app.tabBars.buttons["Стрічка"].tap()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        openRow(app, at: 1)
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["detail.budgetDrift"].exists,
                       "an untouched row must not carry a drift warning")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))

        // Now move the first row into the empty line. It is the only spend
        // there, against a planned ₴0,30 — it is definitionally the tipping one.
        openRow(app, at: 0)
        XCTAssertTrue(app.buttons["detail.category"].waitForExistence(timeout: 3))
        app.buttons["detail.category"].tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))
        let row = app.buttons["picker.row.\(freshCategory)"]
        if !(row.waitForExistence(timeout: 1) && row.isHittable) {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 2))
            search.tap()
            search.typeText(freshCategory)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "saving the plan must have created \(freshCategory) as a real category")
        row.tap()

        XCTAssertTrue(app.staticTexts["detail.budgetDrift"].waitForExistence(timeout: 3),
                      "this purchase took a ₴0,30 line over; detail must say so")
        XCTAssertTrue(app.staticTexts["detail.budgetDrift"].label.contains(freshCategory),
                      app.staticTexts["detail.budgetDrift"].label)
    }
}
