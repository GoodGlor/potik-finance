import XCTest
@testable import MonitorFinance

final class PrivatMapperTests: XCTestCase {
    private func row(date: TimeInterval = 1_787_000_000, category: String = "Тварини",
                     suffix: String = "*1111", description: String = "Крамниця Хвіст",
                     amount: Int = -174_50, balance: Int = 8885_00) -> PrivatRow {
        PrivatRow(date: Date(timeIntervalSince1970: date), category: category,
                  cardSuffix: suffix, descriptionText: description,
                  amountMinor: amount, currency: "UAH",
                  balanceMinor: balance, balanceCurrency: "UAH")
    }

    func testExpenseMapsPendingWithPrivatCategoryAsSuggestion() {
        let tx = PrivatMapper.transaction(row())
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.resolution, .pending)
        XCTAssertEqual(tx.category, "")
        XCTAssertEqual(tx.suggestions, ["Тварини"])
        XCTAssertEqual(tx.merchant, "Крамниця Хвіст")
        XCTAssertEqual(tx.amount, -174_50)
        XCTAssertEqual(tx.bankId, "privatbank")
        XCTAssertEqual(tx.cardSuffix, "*1111")
        XCTAssertEqual(tx.hold, false)
        XCTAssertNil(tx.mcc, "the statement export carries no MCC — «Тварини» is Privat's text, not a code")
        XCTAssertEqual(tx.balanceAfterMinor, 8885_00,
                       "the half of the cross-source key this source contributes")
    }

    func testIncomeArrivesInACategoryTheBudgetActuallyCounts() {
        let tx = PrivatMapper.transaction(row(category: "Зарахування", amount: 30_000_00))
        XCTAssertEqual(tx.kind, .income)
        XCTAssertEqual(tx.category, BudgetMath.defaultIncomeCategory)
        XCTAssertEqual(tx.resolution, .pending)
        // An income row already carries the correct, countable category —
        // there is nothing to suggest. A later queue chip that applied a
        // suggestion verbatim would move this income out of
        // `BudgetMath.earnedCategories` on one tap; do not "fix" this back.
        XCTAssertEqual(tx.suggestions, [])
    }

    func testOwnTransfersBothDirectionsAreTransfers() {
        for r in [row(category: "Переказ на свою картку", description: "На свою картку *2222", amount: -500_00),
                  row(category: "Зарахування зі своєї картки", description: "Зі своєї картки *1111", amount: 500_00),
                  // Mixed case: `isOwnTransfer` case-folds before matching —
                  // without `.lowercased()` this row would wrongly stay an
                  // expense.
                  row(category: "Переказ на Свою Картку", description: "оплата", amount: -50_00)] {
            let tx = PrivatMapper.transaction(r)
            XCTAssertEqual(tx.kind, .transfer, r.category)
            XCTAssertEqual(tx.resolution, .transfer, r.category)
            XCTAssertEqual(tx.category, "", r.category)
            XCTAssertEqual(tx.suggestions, [], r.category)
        }
    }

    /// Board #6. A withdrawal used to come back `.transfer`, which kept it out
    /// of the queue and out of `Derived`'s spending — the money left the card
    /// and the app reported that nothing had been spent. The ATM is the last
    /// place the app can see it, so that is where it counts.
    func testACashWithdrawalIsSpendingTheQueueStillAsksAbout() {
        let tx = PrivatMapper.transaction(
            row(category: "Зняття готівки", description: "Зняття готівки в банкоматі", amount: -100_00))
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.resolution, .pending, "it must reach the queue, not bypass it")
        XCTAssertEqual(tx.amount, -100_00)
    }

    /// The chip creates whatever category it carries. Offering Privat's own
    /// word would put «Зняття готівки» in the list beside the «Готівка» the
    /// seed ships — two names for one thing, created by a tap meant to save
    /// the user work.
    ///
    /// **The translation moved** in board #14, from here to the moment the
    /// chip is offered, so what the ROW stores is now the bank's own word. The
    /// protection is unchanged and is pinned where it now lives, in
    /// `PrivatCategoryMapTests`; this end of it only has to keep the bank's
    /// word intact for `CategorizationLog`'s `bankSuggestion` column.
    func testTheRowStoresPrivatsOwnWordForTheTrainingLog() {
        let tx = PrivatMapper.transaction(
            row(category: "Зняття готівки", description: "Зняття готівки в банкоматі", amount: -100_00))
        XCTAssertEqual(tx.suggestions, ["Зняття готівки"])
        XCTAssertEqual(PrivatMapper.suggestion(for: "Зняття готівки"), BudgetMath.cashCategory,
                       "…and it still reaches the chip as the app's word")
        XCTAssertNotEqual(BudgetMath.cashCategory, "Зняття готівки",
                          "precondition: the two words are different, or this test proves nothing")
    }

    /// And the other side: a statement category the table does not cover
    /// still reaches the chip untouched. A mapping that rewrote more than it
    /// has ruled on would silently retitle the owner's own vocabulary.
    func testAnUnmappedStatementCategoryIsSuggestedVerbatim() {
        let tx = PrivatMapper.transaction(row(category: "Тварини", amount: -100_00))
        XCTAssertEqual(tx.suggestions, ["Тварини"])
        XCTAssertEqual(PrivatMapper.suggestion(for: "Тварини"), "Тварини")
    }

    func testTransferToSomeoneElseStaysAnExpense() {
        // The only negative fixture for `isOwnTransfer`: the description
        // contains bare «картку» but neither «свою картку» nor «своєї
        // картки», so it must stay an expense. Relaxing the match to bare
        // «картку» would flip this row to `.transfer` and is exactly the
        // regression this test exists to catch.
        let tx = PrivatMapper.transaction(row(category: "Перекази", description: "Переказ на чужу картку", amount: -300_00))
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.resolution, .pending)
    }

    func testIdentityIsStableAndBalanceSensitive() {
        let a = PrivatMapper.transaction(row())
        let b = PrivatMapper.transaction(row())
        let c = PrivatMapper.transaction(row(balance: 120_00))
        XCTAssertEqual(a.id, b.id, "same row twice → same id, or a re-import duplicates")
        XCTAssertNotEqual(a.id, c.id, "the balance is the only difference between the same-second pair")
        XCTAssertEqual(a.externalId, "privatbank|" + PrivatMapper.key(row()))
        XCTAssertNotNil(a.externalId, "nil externalId would be swept as a demo row")
        // Pins the exact key format Task 7's tests depend on: field order,
        // separator, and that every component is present. Without this, the
        // two asserts above hold for ANY format (they compare key() against
        // key()) and would stay green through a reordering, a separator
        // change, or a dropped field.
        XCTAssertEqual(PrivatMapper.key(row()), "1787000000|-17450|*1111|888500|Крамниця Хвіст")
    }
}
