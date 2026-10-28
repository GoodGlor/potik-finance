import XCTest
@testable import MonitorFinance

final class DetailTextTests: XCTestCase {
    func testRuleEffectTextReportsTheCascadeCount() {
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 1, merchant: "Крамниця-Приклад", category: "Продукти", ambiguous: false, .uk),
            "Правило збережено",
            "one row changed is just this row — there is no cascade to report")
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 2, merchant: "Сервіс-Приклад", category: "Послуги", ambiguous: false, .uk),
            "Ще 1 покупка Сервіс-Приклад → Послуги")
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 5, merchant: "Сервіс-Приклад", category: "Послуги", ambiguous: false, .uk),
            "Ще 4 покупки Сервіс-Приклад → Послуги")
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 12, merchant: "Сервіс-Приклад", category: "Послуги", ambiguous: false, .uk),
            "Ще 11 покупок Сервіс-Приклад → Послуги",
            "11 takes the many-form despite ending in 1")
    }

    /// An ambiguous rule is the one case where the screen must NOT claim a rule
    /// was saved: `confirm` wrote a rule that asks instead of answering, and the
    /// toggle springs straight back off. The wording has to explain that.
    func testRuleEffectTextSaysTheMerchantWillBeAskedAboutEveryTime() {
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 1, merchant: "Маркет-Приклад", category: "Техніка", ambiguous: true, .uk),
            "«Маркет-Приклад» трапляється в різних категоріях — питатимемо щоразу")
    }

    /// Ambiguity outranks the count. `confirm` returns 1 for the ambiguous
    /// path today, but it is the flag that decides the wording, not the count —
    /// otherwise the day `confirm` returns something else here, the screen
    /// quietly goes back to promising a rule that does not exist.
    func testAmbiguityOutranksTheCascadeCount() {
        XCTAssertEqual(TransactionDetailView.ruleEffectText(
            changed: 7, merchant: "Маркет-Приклад", category: "Техніка", ambiguous: true, .uk),
            "«Маркет-Приклад» трапляється в різних категоріях — питатимемо щоразу",
            "an ambiguous rule cascades to nothing, whatever the count says")
    }

    // MARK: the category row — one label for the feed and the detail screen

    private func tx(kind: TxKind, category: String) -> Transaction {
        Transaction(id: UUID(), date: Date(timeIntervalSince1970: 1_780_000_000),
                    kind: kind, category: category, merchant: "Маркет-Приклад",
                    amount: -1_000, cardSuffix: "*0000", bankId: "monobank",
                    receiptId: nil, splits: [], resolution: .user, suggestions: [])
    }

    /// Board #13. A transfer has no category and never will, so the row used
    /// to fall through to «Без категорії» — which made the screen say the
    /// opposite of what had just happened: answer «Переказ між своїми
    /// картками» in the picker, come back, and the app appears to have
    /// forgotten. It is also the only visible confirmation the tap landed.
    func testATransferNamesItselfRatherThanReadingUncategorised() {
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .transfer, category: ""), .uk),
                       "Переказ між своїми картками")
        XCTAssertNotEqual(Derived.categoryLabel(tx(kind: .transfer, category: ""), .uk),
                          Derived.uncategorised)
        // Board #128: the same row, on an English phone. This is the
        // assertion the app was missing — both translations were in the
        // catalogue the whole time and neither was ever read.
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .transfer, category: ""), .en),
                       "Transfer between your own cards")
    }

    /// The label stands in for the PLACEHOLDER, never for a real answer. The
    /// a real ledger has transfers carrying the owner's own word for them,
    /// and overwriting that with a label the app chose would hide data to
    /// display a constant.
    func testATransferThatDoesHaveACategoryKeepsIt() {
        XCTAssertEqual(
            Derived.categoryLabel(tx(kind: .transfer, category: "Категорія-Приклад"), .uk),
            "Категорія-Приклад")
        // …and an English phone must NOT translate it either: a category name
        // is the person's own data, not the app's copy.
        XCTAssertEqual(
            Derived.categoryLabel(tx(kind: .transfer, category: "Категорія-Приклад"), .en),
            "Категорія-Приклад")
    }

    /// The guard: a genuinely unanswered EXPENSE still says so. Without it the
    /// test above would pass against a screen that had stopped admitting it
    /// does not know anything at all.
    func testAnUnansweredExpenseStillReadsUncategorised() {
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .expense, category: ""), .uk),
                       Derived.uncategorised)
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .expense, category: ""), .en),
                       "No category")
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .expense, category: "Продукти"), .uk),
                       "Продукти")
        XCTAssertEqual(Derived.categoryLabel(tx(kind: .income, category: "Зарплата"), .uk),
                       "Зарплата")
    }
}
