import XCTest
@testable import MonitorFinance

/// Board #6 narrowed «Це не витрата» to own-card transfers and pointed jar
/// top-ups at «Заощадження» instead. That instruction is only safe if a row in
/// that category is kept out of spending — and it was not, before this.
///
/// The failure it prevents, in one month: income 50 000, purchases 30 000, and
/// 5 000 moved into a jar. Counting the jar row as spending makes «Витрати»
/// read 35 000 and the budget's savings line — which is `income - spent` —
/// read 15 000. Saving money would have *lowered* the reported savings, by
/// exactly the amount saved, and raised spending by it as well. The old
/// behaviour (mark it «Це не витрата», it becomes `.transfer`) got this right
/// by accident, so the fix had to make the new answer at least as good as the
/// one it replaces.
final class SavingsIsNotSpendingTests: XCTestCase {

    /// The seed's own categories. Every plan here uses a FIXED income base, so
    /// this cannot change an answer — it is what the app would pass, and
    /// `report` takes it with no default on purpose (board #94).
    private let seedCategories = (try? SeedLoader.load().categories) ?? []


    private let now = ISO8601DateFormatter().date(from: "2026-08-23T10:00:00+03:00")!
    private let july = MonthKey(year: 2026, month: 7)

    private func tx(_ iso: String, _ kind: TxKind, _ category: String, _ amount: Int) -> Transaction {
        Transaction(id: UUID(), date: ISO8601DateFormatter().date(from: iso)!, kind: kind,
                    category: category, merchant: category, amount: amount, cardSuffix: "*0000",
                    bankId: "monobank", receiptId: nil, splits: [], resolution: .user,
                    suggestions: [])
    }

    /// The month above, with the jar top-up recorded whichever way the caller
    /// asks for: as the transfer the old wording produced, or as the savings
    /// expense the new picker steers to.
    private func month(jarAs kind: TxKind) -> [Transaction] {
        [tx("2026-07-01T12:00:00+03:00", .income, "Зарплата", 50_000_00),
         tx("2026-07-05T12:00:00+03:00", .expense, "Продукти", -30_000_00),
         tx("2026-07-06T12:00:00+03:00", kind,
            kind == .transfer ? "" : BudgetMath.savingsCategory, -5_000_00)]
    }

    // MARK: the invariant

    /// The headline: the two recordings are the same month, so they must be
    /// the same numbers. Asserted as an equality between them rather than
    /// against two hard-coded figures, because that is the property — a later
    /// change that moves both is fine, one that separates them is the bug.
    func testATopUpCountsTheSameWhetherItIsATransferOrTheSavingsCategory() {
        let asTransfer = Derived.totals(month(jarAs: .transfer))
        let asSavings = Derived.totals(month(jarAs: .expense))
        XCTAssertEqual(asTransfer, asSavings)
        XCTAssertEqual(asSavings.spent, 30_000_00, "the jar is not a purchase")
        XCTAssertEqual(asSavings.income, 50_000_00)
    }

    func testTheSavingsPlanLineReadsTheSameEitherWay() {
        let plan = Budget(incomeBase: .fixed(50_000_00), lines: [
            .init(id: UUID(), category: "Продукти", percent: 60),
            .init(id: UUID(), category: BudgetMath.savingsCategory, percent: 40),
        ])
        func savings(_ rows: [Transaction]) -> BudgetMath.PlanRow {
            BudgetMath.report(plan, txs: rows, month: july, now: now,
                              categories: seedCategories)
                .rows.first { $0.isSavings }!
        }
        let asTransfer = savings(month(jarAs: .transfer))
        XCTAssertEqual(savings(month(jarAs: .expense)), asTransfer)
        XCTAssertEqual(asTransfer.actual, 20_000_00,
                       "50 000 in, 30 000 spent — the 5 000 in the jar is part of what is left, "
                       + "not a sixth purchase")
    }

    /// Статистика prints a total and a list of slices under it. If only one of
    /// the two learned about savings, the list would add up to more than the
    /// total printed directly above it.
    func testSavingsIsNoSliceOfSpending() {
        let slices = Derived.byCategory(month(jarAs: .expense))
        XCTAssertEqual(slices.map(\.name), ["Продукти"])
        XCTAssertEqual(slices.reduce(0) { $0 + $1.sum },
                       Derived.totals(month(jarAs: .expense)).spent,
                       "the slices must add up to the total shown above them")
    }

    /// And the budget's «не заплановано» list, which is built from the same
    /// slices: a plan with no savings line must not be told it forgot to plan
    /// for the money it managed to keep.
    func testAPlanWithoutASavingsLineIsNotToldItOverspentOnSavings() {
        let plan = Budget(incomeBase: .fixed(50_000_00),
                          lines: [.init(id: UUID(), category: "Продукти", percent: 100)])
        let report = BudgetMath.report(plan, txs: month(jarAs: .expense), month: july, now: now,
                                       categories: seedCategories)
        XCTAssertEqual(report.unplanned, [])
        XCTAssertEqual(report.unplannedTotal, 0)
    }

    /// Статистика's tips are three separate reductions over the same rows, and
    /// two of them inherit the exclusion through `totals` and `byCategory`. The
    /// third counted merchants itself — so the app would have announced a jar
    /// as the user's most frequent seller, complete with an average cheque.
    func testNoTipCallsAJarASeller() {
        let jar = "Приклад-Банка"
        var rows = month(jarAs: .expense)
        for day in 7...9 {
            rows.append(tx("2026-07-0\(day)T12:00:00+03:00", .expense,
                           BudgetMath.savingsCategory, -1_000_00))
            rows[rows.count - 1].merchant = jar
        }
        let bodies = Derived.tips(rows).map(\.body).joined(separator: " | ")
        XCTAssertFalse(bodies.contains(jar), bodies)
        XCTAssertTrue(bodies.contains("Продукти"),
                      "the tips must still be computed at all — " + bodies)
    }

    // MARK: the other side — ordinary spending is untouched

    /// The partner that stops every assertion above from passing because
    /// `totals` stopped counting anything at all. «Готівка» is deliberately
    /// the fixture: it is the category the same card introduced, and the one
    /// thing #6 insists IS spending.
    func testCashIsSpendingAndSoIsEveryOtherCategory() {
        let rows = [tx("2026-07-02T12:00:00+03:00", .expense, BudgetMath.cashCategory, -2_000_00),
                    tx("2026-07-03T12:00:00+03:00", .expense, "Продукти", -1_000_00)]
        XCTAssertEqual(Derived.totals(rows).spent, 3_000_00)
        XCTAssertEqual(Set(Derived.byCategory(rows).map(\.name)),
                       [BudgetMath.cashCategory, "Продукти"])
    }

    /// The exclusion is by category, not by "an expense with a category the
    /// budget knows" or any other predicate that would take the whole plan
    /// down with it.
    func testOnlyTheSavingsCategoryIsExcluded() {
        XCTAssertTrue(Derived.isSetAside(
            tx("2026-07-06T12:00:00+03:00", .expense, BudgetMath.savingsCategory, -1_00)))
        for name in [BudgetMath.cashCategory, "Заощадження ", "заощадження", "Продукти", ""] {
            XCTAssertFalse(Derived.isSetAside(
                tx("2026-07-06T12:00:00+03:00", .expense, name, -1_00)), name)
        }
    }
}
