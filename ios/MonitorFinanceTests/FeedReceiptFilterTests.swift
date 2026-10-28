import XCTest
@testable import MonitorFinance

/// Board #110 — the feed filters by receipt presence.
///
/// «Без чека» is the actionable side: it is how you find the purchases still
/// waiting to be scanned. «З чеком» is how you review the itemised ones.
final class FeedReceiptFilterTests: XCTestCase {

    private func tx(_ merchant: String, receipt: Bool, kind: TxKind = .expense,
                    category: String = "Продукти", amount: Int = -100_00,
                    days: Int = 0) -> Transaction {
        Transaction(id: UUID(),
                    date: Date(timeIntervalSince1970: 1_756_800_000)
                        .addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: kind, category: category, merchant: merchant, amount: amount,
                    cardSuffix: "*1111", bankId: "monobank",
                    receiptId: receipt ? UUID() : nil,
                    splits: [], resolution: .user, suggestions: [])
    }

    private var rows: [Transaction] {
        [tx("Крамниця-Приклад", receipt: true),
         tx("Кавʼярня-Зразок", receipt: false, days: 1),
         tx("Заправка-Тест", receipt: false, days: 2),
         tx("Роботодавець-Зразок", receipt: false, kind: .income,
            category: "Зарплата", amount: 25_000_00, days: 3)]
    }

    private func applying(_ presence: ReceiptPresence?) -> [Transaction] {
        var filter = FeedFilter()
        filter.receipts = presence
        return Derived.apply(filter, to: rows)
    }

    // MARK: the cut

    func testNoChoiceKeepsEverything() {
        XCTAssertEqual(applying(nil).count, 4)
    }

    func testWithAReceiptKeepsOnlyThoseThatHaveOne() {
        let kept = applying(.with)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept.allSatisfy { $0.receiptId != nil })
    }

    /// **The actionable side**, and the one the card is really about.
    func testWithoutAReceiptKeepsEveryRowThatHasNone() {
        let kept = applying(.without)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept.allSatisfy { $0.receiptId == nil })
    }

    /// The two sides partition the rows — nothing is in both, nothing in
    /// neither. Without this, a predicate that answered `false` to everything
    /// would still pass the two tests above's "all satisfy" halves.
    func testTheTwoSidesPartitionTheRows() {
        XCTAssertEqual(applying(.with).count + applying(.without).count, rows.count)
        let with = Set(applying(.with).map(\.id))
        let without = Set(applying(.without).map(\.id))
        XCTAssertTrue(with.isDisjoint(with: without))
    }

    // MARK: composing

    /// The card's second criterion. ANDed with the others, like every
    /// dimension before it.
    func testItComposesWithTheOtherFilters() {
        var filter = FeedFilter()
        filter.receipts = .without
        filter.kinds = [.expense]
        let kept = Derived.apply(filter, to: rows)
        XCTAssertEqual(kept.count, 2, "the income row has no receipt but is not an expense")
        XCTAssertTrue(kept.allSatisfy { $0.kind == .expense && $0.receiptId == nil })
    }

    /// A combination that matches nothing still matches nothing — the filters
    /// are ANDed, not ORed, and an OR here would quietly widen every other one.
    func testAnImpossibleCombinationIsEmptyRatherThanEverything() {
        var filter = FeedFilter()
        filter.receipts = .with
        filter.kinds = [.income]
        XCTAssertEqual(Derived.apply(filter, to: rows).count, 0)
    }

    // MARK: the filter's own bookkeeping

    /// **`isEmpty` decides whether the chip bar appears at all.** A dimension
    /// that forgets it leaves a filter active with no chip naming it and no way
    /// to clear it — the shape board #99's `toggleBank` exists to avoid.
    func testAChosenSideMakesTheFilterNonEmpty() {
        var filter = FeedFilter()
        XCTAssertTrue(filter.isEmpty)
        filter.receipts = .without
        XCTAssertFalse(filter.isEmpty)
        filter.receipts = nil
        XCTAssertTrue(filter.isEmpty, "clearing the last dimension empties the filter")
    }

    /// The chip is COPY, not the person's data — the distinction board #99
    /// found being got wrong across two files, with a Ukrainian chip beside a
    /// sheet reading "Spending".
    func testTheChipIsTranslatedAtTheSource() {
        var filter = FeedFilter()
        filter.receipts = .without
        let uk = filter.chips([], .uk)
        let en = filter.chips([], .en)
        XCTAssertEqual(uk, ["Без чека"])
        XCTAssertNotEqual(uk, en, "«Без чека» must become «Without a receipt»")
    }

    func testNoChosenSideAddsNoChip() {
        XCTAssertEqual(FeedFilter().chips([], .uk), [])
    }

    // MARK: the to-do count

    /// Expenses only. A transfer and an arrival never carry a fiscal receipt,
    /// so counting them would fill a to-do with rows nobody can act on.
    func testTheCountIgnoresRowsThatCouldNeverHaveAReceipt() {
        let mixed = rows + [tx("Переказ-Приклад", receipt: false, kind: .transfer,
                               category: "Перекази", days: 4)]
        XCTAssertEqual(Derived.withoutReceipt(mixed), 2,
                       "two expenses lack one; the income and the transfer do not count")
    }

    /// Money set aside is excluded for the same reason `totals` excludes it:
    /// putting money away is not a purchase and has no receipt to find.
    func testMoneySetAsideIsNotAMissingReceipt() {
        let saved = [tx("Відкладено-Приклад", receipt: false,
                        category: BudgetMath.savingsCategory)]
        XCTAssertEqual(Derived.withoutReceipt(saved), 0)
        XCTAssertEqual(Derived.withoutReceipt(saved + [tx("Крамниця-Приклад", receipt: false)]), 1,
                       "control: an ordinary expense beside it still counts")
    }

    func testAMonthWhereEverythingIsScannedCountsNothing() {
        XCTAssertEqual(Derived.withoutReceipt([tx("Крамниця-Приклад", receipt: true)]), 0)
    }

    func testNoRowsCountsNothing() {
        XCTAssertEqual(Derived.withoutReceipt([]), 0)
    }
}
