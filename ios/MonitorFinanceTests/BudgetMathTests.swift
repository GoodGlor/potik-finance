import XCTest
@testable import MonitorFinance

@MainActor
final class BudgetMathTests: XCTestCase {

    /// The seed's own categories, which is what `BudgetMath` now asks for
    /// (board #94). Most tests here fix the income base or use «Зарплата»,
    /// so this is the vocabulary the app would pass — the parameter has no
    /// default precisely so each test says which vocabulary it means.
    private let seedCategories = (try? SeedLoader.load().categories) ?? []

    override func setUp() { super.setUp(); pinUkrainianFormatting() }


    /// August is in progress on `now`, so it must not dilute the average.
    private let now = ISO8601DateFormatter().date(from: "2026-08-23T10:00:00+03:00")!
    // Every extension below MUST stay in this file: `private` is
    // file-scoped, and moving one out loses access to `now` and `tx`.

    /// An ISO-stamped Kyiv-offset instant, so a fixture never lands near a
    /// month boundary by accident.
    private func tx(_ iso: String, _ kind: TxKind, _ category: String, _ amount: Int) -> Transaction {
        Transaction(id: UUID(), date: ISO8601DateFormatter().date(from: iso)!, kind: kind,
                    category: category, merchant: category, amount: amount, cardSuffix: "*0000",
                    bankId: "monobank", receiptId: nil, splits: [], resolution: .rule, suggestions: [])
    }

    private func threeMonths() -> [Transaction] {
        [tx("2026-05-10T12:00:00+03:00", .income, "Зарплата", 30_000_00),
         tx("2026-06-10T12:00:00+03:00", .income, "Зарплата", 40_000_00),
         tx("2026-07-10T12:00:00+03:00", .income, "Зарплата", 50_000_00),
         tx("2026-08-10T12:00:00+03:00", .income, "Зарплата", 99_000_00),
         tx("2026-06-11T12:00:00+03:00", .expense, "Продукти", -1_000_00)]
    }

    func testTheCurrentMonthIsExcludedFromTheAverage() {
        let a = BudgetMath.average(threeMonths(), months: 3, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(a.used, 3)
        // 99 000 belongs to the in-progress August and must not appear here.
        XCTAssertEqual(a.perMonth, 40_000_00)
    }

    func testGiftsAndRefundsAreExcludedUnlessAskedFor() {
        let rows = [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 40_000_00),
                    tx("2026-07-02T12:00:00+03:00", .income, "Подарунки", 10_000_00),
                    tx("2026-07-03T12:00:00+03:00", .income, "Таксі", 200_00)]
        XCTAssertEqual(BudgetMath.average(rows, months: 1, now: now, includeGifts: false, categories: seedCategories).perMonth,
                       40_000_00, "a gift and a taxi refund are not earnings")
        XCTAssertEqual(BudgetMath.average(rows, months: 1, now: now, includeGifts: true, categories: seedCategories).perMonth,
                       50_200_00, "the switch adds every income row, not just gifts")
    }

    /// D2: a complete month that earned nothing is still a month.
    func testAZeroIncomeMonthStillCountsInTheDenominator() {
        let rows = [tx("2026-06-05T12:00:00+03:00", .expense, "Продукти", -500_00),
                    tx("2026-07-10T12:00:00+03:00", .income, "Зарплата", 40_000_00)]
        let a = BudgetMath.average(rows, months: 2, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(a.used, 2, "June has transactions, so June is a month")
        XCTAssertEqual(a.perMonth, 20_000_00, "40 000 over two months, not over one")
    }

    func testAShortWindowSaysSoInItsLabel() {
        let a = BudgetMath.average(threeMonths(), months: 12, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(a.asked, 12)
        XCTAssertEqual(a.used, 3)
        // The divisor is `used`, not `asked`: three months of 30/40/50k
        // average to 40 000, not to 120 000 spread over a year.
        XCTAssertEqual(a.perMonth, 40_000_00)
        let aLabel = BudgetMath.label(for: a, .uk)
        XCTAssertTrue(aLabel.contains("є лише за 3"), aLabel)
        XCTAssertFalse(BudgetMath.label(
                        for: BudgetMath.average(threeMonths(), months: 3, now: now, includeGifts: false, categories: seedCategories),
                        .uk).contains("є лише"),
                       "a full window must not apologise for itself")
    }

    // MARK: the rows read as sentences (board #23)

    /// «3 міс · є лише 1 · 0 ₴» was a debug print, sitting in the one list
    /// whose whole job is to let somebody decide which number is their real
    /// income. Exact strings, because the complaint was about the words.
    /// Non-breaking spaces normalised away, so the expected strings here stay
    /// readable. `testTheSumNeverWrapsAwayFromItsSign` is where that character
    /// is the point.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTheIncomeRowsReadAsSentences() {
        let full = BudgetMath.average(threeMonths(), months: 3, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(plain(BudgetMath.label(for: full, .uk)), "За 3 місяці — 40 000 ₴")

        let short = BudgetMath.average(threeMonths(), months: 12, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(plain(BudgetMath.label(for: short, .uk)), "За 12 місяців даних є лише за 3 — 40 000 ₴")

        let none = BudgetMath.average([], months: 6, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(plain(BudgetMath.label(for: none, .uk)), "За 6 місяців — даних ще немає")
    }

    /// Found by looking at the screen: the 12-month row wraps, and it broke
    /// between «36 280» and «₴», leaving the sign alone on the second line
    /// where it reads as a typo.
    func testTheSumNeverWrapsAwayFromItsSign() {
        let label = BudgetMath.label(
            for: BudgetMath.average(threeMonths(), months: 12, now: now, includeGifts: false, categories: seedCategories), .uk)
        XCTAssertTrue(label.hasSuffix("\u{00A0}₴"), label)
        XCTAssertFalse(label.hasSuffix(" ₴"),
                       "a breakable space here is what put «₴» on a line of its own")
    }

    /// Ukrainian needs all three forms, and the list offers 1, 2, 3, 6 and 12
    /// — which is one of each.
    func testTheMonthCountAgreesWithItsNoun() {
        func label(_ n: Int) -> String {
            BudgetMath.label(for: BudgetMath.average([], months: n, now: now, includeGifts: false, categories: seedCategories), .uk)
        }
        XCTAssertTrue(label(1).hasPrefix("За 1 місяць"), label(1))
        XCTAssertTrue(label(2).hasPrefix("За 2 місяці"), label(2))
        XCTAssertTrue(label(3).hasPrefix("За 3 місяці"), label(3))
        XCTAssertTrue(label(6).hasPrefix("За 6 місяців"), label(6))
        XCTAssertTrue(label(12).hasPrefix("За 12 місяців"), label(12))
    }

    func testNoCompleteMonthsYieldsZeroRatherThanACrash() {
        let rows = [tx("2026-08-02T12:00:00+03:00", .income, "Зарплата", 40_000_00)]
        let a = BudgetMath.average(rows, months: 3, now: now, includeGifts: false, categories: seedCategories)
        XCTAssertEqual(a.used, 0)
        XCTAssertEqual(a.perMonth, 0)
    }

    func testAFixedBaseIgnoresTheLedgerEntirely() {
        let budget = Budget(incomeBase: .fixed(49_000_00), lines: [])
        XCTAssertEqual(BudgetMath.monthlyIncome(budget, txs: threeMonths(), now: now, categories: seedCategories), 49_000_00)
    }

    func testAnAverageBaseResolvesThroughTheSameWindow() {
        let budget = Budget(incomeBase: .average(months: 3, includeGifts: false), lines: [])
        XCTAssertEqual(BudgetMath.monthlyIncome(budget, txs: threeMonths(), now: now, categories: seedCategories), 40_000_00)
    }
}

extension BudgetMathTests {

    private func plan() -> Budget {
        Budget(incomeBase: .fixed(50_000_00), lines: [
            .init(id: UUID(), category: "Продукти", percent: 30),
            .init(id: UUID(), category: "Квартплата", percent: 30),
            .init(id: UUID(), category: BudgetMath.savingsCategory, percent: 10),
        ])
    }

    /// Computed, not stored: Swift forbids stored properties in an
    /// extension, and every fixture below lives in one.
    private var july: MonthKey { MonthKey(year: 2026, month: 7) }

    func testASpendingLineOverItsPlanIsFlagged() {
        let rows = [tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -17_850_00),
                    tx("2026-07-06T12:00:00+03:00", .expense, "Квартплата", -10_000_00)]
        let r = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
        let groceries = r.rows.first { $0.category == "Продукти" }!
        XCTAssertEqual(groceries.planned, 15_000_00)
        XCTAssertEqual(groceries.actual, 17_850_00)
        XCTAssertTrue(groceries.offPlan)
        XCTAssertEqual(groceries.share, 0.357, accuracy: 0.0005)

        let rent = r.rows.first { $0.category == "Квартплата" }!
        XCTAssertFalse(rent.offPlan, "10 000 against a 15 000 plan is under, not over")
    }

    /// The savings row is the one line that inverts: nothing is spent on it,
    /// so its actual is what survived the month, and *under* plan is the miss.
    func testSavingsCountsWhatIsLeftOverAndInvertsTheComparison() {
        let rows = [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00),
                    tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -40_000_00)]
        let saved = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
            .rows.first { $0.isSavings }!
        XCTAssertEqual(saved.planned, 5_000_00)
        XCTAssertEqual(saved.actual, 10_000_00, "50 000 earned − 40 000 spent")
        XCTAssertFalse(saved.offPlan, "saving more than planned is not a problem")
    }

    func testSavingsIsFlaggedWhenTooLittleSurvivesAndNeverGoesNegative() {
        let rows = [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00),
                    tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -60_000_00)]
        let saved = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
            .rows.first { $0.isSavings }!
        XCTAssertEqual(saved.actual, 0, "spending past income floors at zero, it does not go negative")
        XCTAssertTrue(saved.offPlan)
    }

    func testTransfersAreExcludedFromASavingsLeftover() {
        let rows = [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00),
                    tx("2026-07-04T12:00:00+03:00", .transfer, "Перекази — свої картки", -20_000_00),
                    tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -10_000_00)]
        let saved = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
            .rows.first { $0.isSavings }!
        XCTAssertEqual(saved.actual, 40_000_00, "money moved between own cards never left")
    }

    func testSpendOutsideThePlanIsCollectedSeparately() {
        let rows = [tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -1_000_00),
                    tx("2026-07-06T12:00:00+03:00", .expense, "Таксі", -700_00),
                    tx("2026-07-07T12:00:00+03:00", .expense, "Кафе та ресторани", -300_00)]
        let r = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
        XCTAssertEqual(r.unplanned.map(\.name), ["Таксі", "Кафе та ресторани"],
                       "largest first, and neither is a planned line")
        XCTAssertEqual(r.unplannedTotal, 1_000_00)
    }

    func testAnotherMonthsSpendingDoesNotLeakIn() {
        let rows = [tx("2026-06-30T23:30:00+03:00", .expense, "Продукти", -9_000_00),
                    tx("2026-07-01T00:30:00+03:00", .expense, "Продукти", -1_000_00)]
        let groceries = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
            .rows.first { $0.category == "Продукти" }!
        XCTAssertEqual(groceries.actual, 1_000_00,
                       "the 30 June row is June's in Kyiv, whatever the device's timezone says")
    }

    func testTheSavingsRowReportsItsShareOfTheIncomeBaseLikeEveryOtherRow() {
        let rows = [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00),
                    tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -40_000_00)]
        let saved = BudgetMath.report(plan(), txs: rows, month: july, now: now, categories: seedCategories)
            .rows.first { $0.isSavings }!
        // 10 000 survived of a 50 000 base — the bar's fill depends on this.
        XCTAssertEqual(saved.share, 0.2, accuracy: 0.0001)
    }
}

extension BudgetMathTests {

    func testPercentTextUsesAUkrainianDecimalComma() {
        XCTAssertEqual(BudgetMath.percentText(0.357), "35,7%")
        XCTAssertEqual(BudgetMath.percentText(0.3), "30,0%")
    }

    func testAnOnPlanRowHasNothingToSay() {
        let row = BudgetMath.PlanRow(category: "Продукти", percent: 30, planned: 15_000_00,
                                     actual: 10_000_00, isSavings: false, offPlan: false, share: 0.2)
        XCTAssertNil(BudgetMath.driftText(row, .uk))
    }

    /// D3: the name is quoted, not declined.
    func testASpendingDriftNamesTheGapInMoneyAndInPercent() {
        let row = BudgetMath.PlanRow(category: "Продукти", percent: 30, planned: 15_000_00,
                                     actual: 17_850_00, isSavings: false, offPlan: true, share: 0.357)
        let text = BudgetMath.driftText(row, .uk)!
        XCTAssertTrue(text.contains("«Продукти»"), text)
        XCTAssertTrue(text.contains("35,7%"), text)
        XCTAssertTrue(text.contains("30%"), text)
        XCTAssertTrue(text.contains("2 850 ₴"), text)
    }

    func testASavingsDriftTalksAboutWhatIsLeftNotAboutOverspending() {
        let row = BudgetMath.PlanRow(category: BudgetMath.savingsCategory, percent: 10,
                                     planned: 4_894_00, actual: 2_117_00,
                                     isSavings: true, offPlan: true, share: 0.043)
        let text = BudgetMath.driftText(row, .uk)!
        XCTAssertTrue(text.contains("Залишилось"), text)
        XCTAssertTrue(text.contains("2 117 ₴"), text)
        XCTAssertTrue(text.contains("4 894 ₴"), text)
        XCTAssertFalse(text.contains("більше"), "savings is never 'over' — " + text)
    }

    func testTheWorstDriftIsTheLargestGapNotTheFirstRow() {
        let budget = Budget(incomeBase: .fixed(50_000_00), lines: [
            .init(id: UUID(), category: "Квартплата", percent: 10),   // over by 1 000
            .init(id: UUID(), category: "Продукти", percent: 10),     // over by 9 000
        ])
        let rows = [tx("2026-07-05T12:00:00+03:00", .expense, "Квартплата", -6_000_00),
                    tx("2026-07-06T12:00:00+03:00", .expense, "Продукти", -14_000_00)]
        let r = BudgetMath.report(budget, txs: rows, month: MonthKey(year: 2026, month: 7), now: now, categories: seedCategories)
        XCTAssertEqual(BudgetMath.worstDrift(r)?.category, "Продукти")
    }

    func testWorstDriftIsNilWhenEveryLineIsOnPlan() {
        let rows = [tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -1_000_00),
                    tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00)]
        let r = BudgetMath.report(plan(), txs: rows, month: MonthKey(year: 2026, month: 7), now: now, categories: seedCategories)
        XCTAssertNil(BudgetMath.worstDrift(r))
    }

    /// The detail-screen row: only when *this* transaction is what tipped it.
    func testATransactionThatTippedALineOverIsIdentified() {
        let budget = Budget(incomeBase: .fixed(50_000_00),
                            lines: [.init(id: UUID(), category: "Продукти", percent: 10)])
        let under = tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -4_000_00)
        let tipping = tx("2026-07-06T12:00:00+03:00", .expense, "Продукти", -2_000_00)
        let rows = [under, tipping]

        XCTAssertEqual(BudgetMath.pushedOverPlan(tipping, budget: budget, txs: rows, now: now, categories: seedCategories)?.category,
                       "Продукти")
        XCTAssertNil(BudgetMath.pushedOverPlan(under, budget: budget, txs: rows, now: now, categories: seedCategories),
                     "the line was already over without the earlier row; it did not tip it")
    }

    func testATransactionOnAnAlreadyOverLineDoesNotClaimCredit() {
        let budget = Budget(incomeBase: .fixed(50_000_00),
                            lines: [.init(id: UUID(), category: "Продукти", percent: 10)])
        let big = tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -20_000_00)
        let small = tx("2026-07-06T12:00:00+03:00", .expense, "Продукти", -100_00)
        XCTAssertNil(BudgetMath.pushedOverPlan(small, budget: budget, txs: [big, small], now: now, categories: seedCategories),
                     "already 15 000 over before this 100 ₴ row existed")
    }

    func testIncomeAndTransfersNeverTipALineOver() {
        let budget = Budget(incomeBase: .fixed(50_000_00),
                            lines: [.init(id: UUID(), category: "Продукти", percent: 10)])
        // Both carry the planned category, so the category guard cannot be
        // what makes these nil — only the kind guard can.
        let refund = tx("2026-07-01T12:00:00+03:00", .income, "Продукти", 50_000_00)
        let moved = tx("2026-07-02T12:00:00+03:00", .transfer, "Продукти", -30_000_00)
        let spend = tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -20_000_00)
        let rows = [refund, moved, spend]
        XCTAssertNil(BudgetMath.pushedOverPlan(refund, budget: budget, txs: rows, now: now, categories: seedCategories))
        XCTAssertNil(BudgetMath.pushedOverPlan(moved, budget: budget, txs: rows, now: now, categories: seedCategories))
        XCTAssertNotNil(BudgetMath.pushedOverPlan(spend, budget: budget, txs: rows, now: now, categories: seedCategories),
                        "the expense in the same category must still be found — otherwise " +
                        "this test would pass with pushedOverPlan returning nil for everything")
    }

    /// Bank exports stamp a whole batch with one instant, and the shipped
    /// seed has 13 same-instant same-category groups — one of them in
    /// «Продукти», a starter-plan line. Ordering by date alone made every
    /// member of such a group sort *after* every other, so each one saw the
    /// full group as "before" it and none of them was ever the tipper: the
    /// warning vanished entirely. The order is `(date, id)` for that reason.
    func testTwoExpensesAtOneInstantStillNameExactlyOneTipper() {
        let budget = Budget(incomeBase: .fixed(50_000_00),
                            lines: [.init(id: UUID(), category: "Продукти", percent: 10)])
        // Planned is 5 000 ₴. Neither row crosses it alone; together they do.
        let stamp = "2026-07-05T12:00:00+03:00"
        let a = tx(stamp, .expense, "Продукти", -4_000_00)
        let b = tx(stamp, .expense, "Продукти", -4_000_00)
        XCTAssertEqual(a.date, b.date, "precondition: the tie is a real tie")
        let rows = [a, b]

        let hits = rows.filter {
            BudgetMath.pushedOverPlan($0, budget: budget, txs: rows, now: now, categories: seedCategories) != nil
        }
        XCTAssertEqual(hits.count, 1,
                       "the warning must land on exactly one of the two, not on both and not on neither")

        // And on the same one every time: the tie-break is arbitrary, but it
        // must not be arbitrary per call, or the detail screen would flicker.
        for _ in 0..<5 {
            let again = rows.filter {
                BudgetMath.pushedOverPlan($0, budget: budget, txs: rows, now: now, categories: seedCategories) != nil
            }
            XCTAssertEqual(again.map(\.id), hits.map(\.id))
        }
        // Order of the input array must not decide it either.
        let reversed = rows.reversed().filter {
            BudgetMath.pushedOverPlan($0, budget: budget, txs: rows.reversed(), now: now, categories: seedCategories) != nil
        }
        XCTAssertEqual(reversed.map(\.id), hits.map(\.id))
    }
}

extension BudgetMathTests {
    /// A whole number of hryvnia, so these fixtures test the percentages and
    /// not the kopeck slack — which has tests of its own below.
    private var base: Int { 100_000_00 }

    private func lines(_ percents: [Double]) -> [Budget.Line] {
        percents.enumerated().map { .init(id: UUID(), category: "к\($0.offset)", percent: $0.element) }
    }

    func testAnIncompleteAllocationSaysWhatIsLeft() {
        XCTAssertEqual(BudgetMath.allocationText(lines([30, 30, 30]), income: base, .uk),
                       "Розподілено 90% · залишилось 10%")
        XCTAssertFalse(BudgetMath.isComplete(lines([30, 30, 30]), income: base))
    }

    func testAnExactHundredIsComplete() {
        XCTAssertEqual(BudgetMath.allocationText(lines([30, 30, 30, 10]), income: base, .uk), "Розподілено 100%")
        XCTAssertTrue(BudgetMath.isComplete(lines([30, 30, 30, 10]), income: base))
    }

    /// Over 100 must not read as "залишилось −5%".
    func testGoingOverSaysByHowMuch() {
        XCTAssertEqual(BudgetMath.allocationText(lines([50, 55]), income: base, .uk), "Розподілено 105% · на 5% більше")
        XCTAssertFalse(BudgetMath.isComplete(lines([50, 55]), income: base))
    }

    func testAnEmptyPlanIsNotComplete() {
        XCTAssertFalse(BudgetMath.isComplete([], income: base))
        XCTAssertEqual(BudgetMath.allocationText([], income: base, .uk), "Розподілено 0% · залишилось 100%")
    }

    func testAllocationCountsEveryLineEvenWhenTwoNameTheSameCategory() {
        let doubled = [Budget.Line(id: UUID(), category: "Продукти", percent: 40),
                       Budget.Line(id: UUID(), category: "Продукти", percent: 60)]
        XCTAssertEqual(BudgetMath.allocated(doubled), 100,
                       "the total is over lines, not over distinct categories")
        XCTAssertTrue(BudgetMath.isComplete(doubled, income: base))
    }
}

// MARK: - Amounts

/// A line can be set by its ₴ figure instead of its percentage. The
/// percentage stays what is stored — so the plan still totals 100% and still
/// follows the income base when the average moves — but it is no longer
/// whole, because one whole percent of this owner's income is ~467 ₴ and
/// "5 000 ₴ for groceries" is not on that grid.
extension BudgetMathTests {

    /// Mirrors the shape `Budget.Line` had through stage 4, so the fixture is
    /// the real old document rather than a guess at what Codable synthesised.
    private struct OldLine: Encodable { let id: UUID; let category: String; let percent: Int }
    private struct OldBudget: Encodable { let incomeBase: IncomeBase; let lines: [OldLine] }

    /// The whole widening rests on this. `Repository` keys one JSON file per
    /// collection with no version stamp, and `AppStore.init` does
    /// `try? repository.load(…)` — so a budget.json this build cannot read is
    /// dropped in silence and the user's plan simply disappears. Nothing else
    /// in the repo checks that the pre-stage-5 shape still decodes.
    func testAPlanWrittenWhenPercentsWereIntegersStillDecodes() throws {
        let old = OldBudget(incomeBase: .average(months: 3, includeGifts: false),
                            lines: [OldLine(id: UUID(), category: "Продукти", percent: 30),
                                    OldLine(id: UUID(), category: "Квартплата", percent: 70)])
        let data = try SeedLoader.encoder.encode(old)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"percent\":30"),
                      "precondition: the fixture really is the integer shape")

        let read = try SeedLoader.decoder.decode(Budget.self, from: data)
        XCTAssertEqual(read.lines.map(\.percent), [30, 70])
        XCTAssertTrue(BudgetMath.isComplete(read.lines, income: base),
                      "a plan that added to 100 before must still add to 100")
    }

    /// The other direction: an untouched whole percent must not start writing
    /// itself as `30.0`, or a build older than this one stops reading it.
    func testAWholePercentStillEncodesAsAnInteger() throws {
        let text = String(data: try SeedLoader.encoder.encode(Budget.starter()), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"percent\":45"), text)
        XCTAssertFalse(text.contains("\"percent\":45.0"), text)
    }

    /// The editor's amount field, both ways. 5 000 ₴ of 46 697,47 ₴ is
    /// 10,707…% — nowhere near a whole percent, which is the point.
    func testAnAmountSurvivesTheTripThroughAPercentAndBack() {
        let income = 46_697_47
        let percent = BudgetMath.percentFor(major: 5_000, income: income)!
        XCTAssertNotEqual(percent, percent.rounded(),
                          "precondition: this amount is NOT a whole percent of that income")
        XCTAssertEqual(BudgetMath.plannedMajor(percent: percent, income: income), 5_000,
                       "typing 5 000 ₴ must leave the line planning 5 000 ₴, not 4 670 or 5 137")
    }

    /// Snapping to whole percents is what this change exists to stop, so the
    /// grid it would snap to is named here explicitly.
    func testWholePercentsCannotExpressTheAmountsNextToThem() {
        let income = 46_697_47
        XCTAssertEqual(BudgetMath.plannedMajor(percent: 10, income: income), 4_670)
        XCTAssertEqual(BudgetMath.plannedMajor(percent: 11, income: income), 5_137)
    }

    func testAZeroIncomeBaseRefusesToConvertRatherThanDividingByIt() {
        XCTAssertNil(BudgetMath.percentFor(major: 5_000, income: 0))
        XCTAssertNil(BudgetMath.percentFor(major: 5_000, income: -1))
        XCTAssertEqual(BudgetMath.plannedMajor(percent: 30, income: 0), 0)
    }

    func testAPlannedAmountRoundsToTheNearestHryvniaRatherThanTruncating() {
        // 1,00007% of 1 000,00 ₴ is 10,0007 ₴ — 10 ₴ when rounded, 10 ₴ when
        // truncated, so that would prove nothing. 10,6 ₴ is the useful case.
        XCTAssertEqual(BudgetMath.plannedMajor(percent: 1.06, income: 1_000_00), 11,
                       "10,6 ₴ rounds up to 11, it does not floor to 10")
    }

    /// The same rounding one level up, through the real report.
    func testAFractionalPlanLineRoundsToTheNearestKopeck() {
        let budget = Budget(incomeBase: .fixed(1_000_00),
                            lines: [.init(id: UUID(), category: "Продукти", percent: 12.3456)])
        let r = BudgetMath.report(budget, txs: [], month: MonthKey(year: 2026, month: 7), now: now, categories: seedCategories)
        // 12,3456% of 100 000 kopecks is 12 345,6 — integer division floors
        // that to 12 345.
        XCTAssertEqual(r.rows[0].planned, 12_346)
    }
}

// MARK: - Fractional percents on screen

extension BudgetMathTests {

    func testAPlanPercentShowsADecimalOnlyWhenItHasOne() {
        XCTAssertEqual(BudgetMath.planPercentText(30), "30%",
                       "an untouched whole line must not read «30,0%»")
        XCTAssertEqual(BudgetMath.planPercentText(10.7073), "10,7%")
        XCTAssertEqual(BudgetMath.planPercentText(9.96), "10%",
                       "rounding to one decimal can land on a whole number")
    }

    func testDriftCopyQuotesAFractionalPlanWithAComma() {
        let row = BudgetMath.PlanRow(category: "Продукти", percent: 10.7073, planned: 5_000_00,
                                     actual: 5_794_00, isSavings: false, offPlan: true, share: 0.124)
        let text = BudgetMath.driftText(row, .uk)!
        XCTAssertTrue(text.contains("запланованих 10,7%"), text)
        XCTAssertFalse(text.contains("10.7"), "the separator must be a comma — " + text)
    }

    /// The reachable one, and the reason `isComplete` measures money rather
    /// than percentage points. 5 000 + 14 009 + 27 688 is 46 697 ₴ against an
    /// income base of 46 697,47 ₴ — the plan is 47 копійок, one thousandth of
    /// a percent, short. No combination of whole hryvnia closes that gap, so
    /// an exact test would leave Save disabled whatever the user typed.
    func testAPlanTypedInWholeHryvniaCompletesDespiteTheLeftoverKopecks() {
        let income = 46_697_47
        let typed = [5_000, 14_009, 27_688].map { BudgetMath.percentFor(major: $0, income: income)! }
        XCTAssertNotEqual(typed.reduce(0, +), 100,
                          "precondition: whole hryvnia cannot add to 100% of a base with kopecks")
        XCTAssertTrue(BudgetMath.isComplete(lines(typed), income: income))
        XCTAssertEqual(BudgetMath.allocationText(lines(typed), income: income, .uk), "Розподілено 100%")
    }

    /// …and the slack is a hryvnia a line, not a blank cheque.
    func testAPlanThatIsGenuinelyShortIsStillRefused() {
        let income = 46_697_47
        // 500 ₴ left unallocated — 1,07%, against 3 ₴ of rounding slack.
        let typed = [5_000, 14_009, 27_188].map { BudgetMath.percentFor(major: $0, income: income)! }
        XCTAssertFalse(BudgetMath.isComplete(lines(typed), income: income))
        XCTAssertTrue(BudgetMath.allocationText(lines(typed), income: income, .uk).contains("залишилось"),
                      BudgetMath.allocationText(lines(typed), income: income, .uk))
    }

    /// The other branch: with no income there is no money to measure, so the
    /// percentages are all there is.
    func testWithNoIncomeThePercentagesAreTheOnlyTest() {
        XCTAssertTrue(BudgetMath.isComplete(lines([30, 30, 30, 10]), income: 0))
        XCTAssertFalse(BudgetMath.isComplete(lines([30, 30, 30]), income: 0))
    }

    /// The footer's second decimal earns its keep here and nowhere else: a
    /// gap just outside the slack is real — Save IS disabled — and one
    /// decimal would round it to «залишилось 0,0%», a footer denying the very
    /// thing that is blocking the button.
    func testAGapTooSmallToRoundStillReadsAsAGap() {
        let income = 46_697_47                  // three lines ⇒ 3 ₴ of slack
        let short = lines([50, 30, 19.99])      // 4,67 ₴ short, just outside it
        XCTAssertFalse(BudgetMath.isComplete(short, income: income),
                       "precondition: this gap is outside the slack, so Save is disabled")
        XCTAssertEqual(BudgetMath.allocationText(short, income: income, .uk),
                       "Розподілено 99,99% · залишилось 0,01%")
    }

    func testAnIncompleteFractionalAllocationReportsTheGapWithADecimal() {
        XCTAssertEqual(BudgetMath.allocationText(lines([10.7, 30]), income: base, .uk),
                       "Розподілено 40,7% · залишилось 59,3%")
    }
}
