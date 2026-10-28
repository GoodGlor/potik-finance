import XCTest
@testable import MonitorFinance

/// Board #109 — choosing a month in the feed rather than stepping to it.
///
/// The card said the feed showed a continuous history. It did not: `FeedView`
/// has cut by month since it was written. What it could not do was let a person
/// *choose* — eight months of data meant up to seven chevron taps to reach one,
/// with nothing on screen saying which months existed — or say how much a month
/// cost, only how many rows it held.
@MainActor
final class FeedMonthTests: XCTestCase {

    private func tx(_ month: Int, day: Int = 5, amount: Int = -100_00,
                    category: String = "Продукти", merchant: String = "Крамниця-Приклад",
                    kind: TxKind? = nil) -> Transaction {
        let date = Calendar.kyiv.date(from: DateComponents(year: 2026, month: month, day: day))!
        return Transaction(id: UUID(), date: date,
                           kind: kind ?? (amount > 0 ? .income : .expense),
                           category: category, merchant: merchant, amount: amount,
                           cardSuffix: "*1111", bankId: "monobank", receiptId: nil,
                           splits: [], resolution: .user, suggestions: [])
    }

    private var rows: [Transaction] {
        [tx(3), tx(3, day: 6, amount: -250_00), tx(5), tx(8, amount: -400_00)]
    }

    // MARK: what the picker lists

    /// **Newest first** — a picker is read from the top, and the top is where a
    /// person expects the month they are in. `months` is the other order, and
    /// deliberately stays that way: it is what the chevrons step along.
    func testTheMonthsAreListedNewestFirst() {
        let listed = Derived.monthRows(rows, matching: rows).map(\.month)
        XCTAssertEqual(listed, [MonthKey(year: 2026, month: 8),
                                MonthKey(year: 2026, month: 5),
                                MonthKey(year: 2026, month: 3)])
        XCTAssertEqual(listed.reversed().map(\.description),
                       Derived.months(rows).map(\.description),
                       "the picker's order is exactly the stepper's, reversed")
    }

    func testAMonthCarriesItsCountAndItsSpending() throws {
        let march = try XCTUnwrap(Derived.monthRows(rows, matching: rows)
            .first { $0.month == MonthKey(year: 2026, month: 3) })
        XCTAssertEqual(march.count, 2)
        XCTAssertEqual(march.spent, 350_00)
    }

    /// **The two sets are not the same set, and this is the case that says why.**
    /// A filter that empties a month must still leave that month listed —
    /// otherwise the list reshuffles as you filter, and the month currently on
    /// screen can vanish from the picker with no way back to it.
    func testAFilterEmptiesAMonthWithoutRemovingIt() {
        let matching = rows.filter { $0.date >= MonthKey(year: 2026, month: 5).start }
        let listed = Derived.monthRows(rows, matching: matching)
        XCTAssertEqual(listed.count, 3, "every month the DATA touches is still offered")
        let march = listed.first { $0.month == MonthKey(year: 2026, month: 3) }
        XCTAssertEqual(march?.count, 0)
        XCTAssertEqual(march?.spent, 0)
    }

    /// The numbers come from the same arithmetic every other screen uses, so a
    /// row promising a figure opens a feed showing it.
    func testAMonthsSpendingIsTheSameFigureTotalsComputes() {
        for row in Derived.monthRows(rows, matching: rows) {
            XCTAssertEqual(row.spent,
                           Derived.totals(Derived.inMonth(rows, row.month)).spent,
                           "\(row.month) disagrees with `totals`")
        }
    }

    /// Transfers and money set aside are not spending — `totals` excludes both,
    /// and a picker that counted them would promise a figure the feed's own
    /// total then contradicts.
    func testATransferCountsAsAnOperationButNotAsSpending() throws {
        let withTransfer = rows + [tx(8, day: 9, amount: -900_00, category: "Перекази",
                                      kind: .transfer)]
        let august = try XCTUnwrap(Derived.monthRows(withTransfer, matching: withTransfer)
            .first { $0.month == MonthKey(year: 2026, month: 8) })
        XCTAssertEqual(august.count, 2, "it is still a row in the feed")
        XCTAssertEqual(august.spent, 400_00, "but the money never left")
    }

    func testNoTransactionsListsNoMonths() {
        XCTAssertEqual(Derived.monthRows([], matching: []).count, 0)
    }

    // MARK: what a row says

    /// Composed from `uahExact` rather than compared against «350,00 ₴».
    /// `L10n.formatting` is process-wide, so the decimal separator depends on
    /// which language some other test in the suite set last — this assertion
    /// passed alone and failed in the full run, which is the definition of a
    /// test that pins the wrong thing.
    func testARowNamesItsCountAndItsSpending() throws {
        let march = try XCTUnwrap(Derived.monthRows(rows, matching: rows)
            .first { $0.month == MonthKey(year: 2026, month: 3) })
        XCTAssertEqual(FeedMonthSheet.summary(march, .uk),
                       "2 операції · \(350_00.uahExact)")
        XCTAssertTrue(FeedMonthSheet.summary(march, .uk).contains("350"),
                      "the money is the month's spending, not its row count")
    }

    /// **A month with no spending shows no money.** «0 ₴» beside a month full of
    /// income and transfers reads as a broken figure rather than an accurate
    /// one — and under a filter that keeps only income, every row would carry it.
    func testAMonthWithNoSpendingShowsOnlyItsCount() {
        let row = Derived.MonthRow(month: MonthKey(year: 2026, month: 4), count: 3, spent: 0)
        let text = FeedMonthSheet.summary(row, .uk)
        XCTAssertEqual(text, "3 операції")
        XCTAssertFalse(text.contains("₴"))
    }

    /// The count is copy and follows the language; the money is digits and a
    /// currency mark, which `uahExact` already renders for the chosen one.
    func testTheCountFollowsTheLanguage() {
        let row = Derived.MonthRow(month: MonthKey(year: 2026, month: 4), count: 3, spent: 100_00)
        XCTAssertNotEqual(FeedMonthSheet.summary(row, .uk),
                          FeedMonthSheet.summary(row, .en),
                          "«3 операції» must become «3 operations»")
    }
}
