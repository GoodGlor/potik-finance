import XCTest
@testable import MonitorFinance

/// Board #100 — one correction, offered to the merchant's backlog.
///
/// The gap is narrow. `confirm`'s cascade reaches only `.pending` rows, so a
/// person who finds a purchase categorised WRONGLY and fixes it leaves every
/// other row of that merchant — already answered, and wrong the same way —
/// exactly as it was. The rule toggle does not help: it governs the future.
@MainActor
final class ApplyToSimilarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func tx(_ merchant: String, category: String, days: Int = 0,
                    amount: Int = -100_00, kind: TxKind? = nil,
                    resolution: Resolution = .user) -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: kind ?? (amount > 0 ? .income : .expense), category: category,
                    merchant: merchant, amount: amount, cardSuffix: "*1111",
                    bankId: "monobank", receiptId: nil, splits: [],
                    resolution: resolution, suggestions: [])
    }

    private func store(_ rows: [Transaction]) throws -> AppStore {
        var seed = try SeedLoader.load()
        seed.transactions = rows; seed.receipts = []; seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: the count that decides whether anything is offered

    func testTheOfferCountsOnlyRowsThatDisagree() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let same = tx("Крамниця-Приклад", category: "Продукти", days: 1)
        let other = tx("Крамниця-Приклад", category: "Розваги", days: 2)
        let s = try store([anchor, same, other])

        XCTAssertEqual(s.othersDisagreeing(with: anchor.id), 1,
                       "the row that already agrees is not something to change")
    }

    func testADifferentMerchantIsNeverOffered() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let elsewhere = tx("Заклад-Зразок", category: "Розваги", days: 1)
        let s = try store([anchor, elsewhere])
        XCTAssertEqual(s.othersDisagreeing(with: anchor.id), 0)
    }

    /// **The hazard this card's «similar» definition exists to avoid.**
    ///
    /// A merchant that both pays and charges — a marketplace, an employer who
    /// also sells — holds two independent answers. Matching on merchant alone
    /// would stamp a spending category onto a salary, which is exactly why
    /// `confirm`'s cascade and board #81's rule key both carry the kind.
    func testAnIncomeRowIsNeverChangedByCorrectingAnExpense() throws {
        let expense = tx("Маркет-Зразок", category: "Продукти")
        let salary = tx("Маркет-Зразок", category: "Зарплата", days: 1, amount: 25_000_00)
        let s = try store([expense, salary])

        XCTAssertEqual(s.othersDisagreeing(with: expense.id), 0,
                       "an income row is a different question about the same merchant")
        XCTAssertEqual(s.applyCategoryToSimilar(expense.id), 0)
        XCTAssertEqual(s.transactions.first { $0.id == salary.id }?.category, "Зарплата")
    }

    /// A transfer has no category, and giving it one silently would move money
    /// into spending. `setCategory` retypes the row it edits OUT of
    /// `.transfer`, so the kind term already excludes them — asserted, because
    /// this is the failure that would be invisible in every total.
    func testATransferIsNeverSweptIntoACategory() throws {
        let anchor = tx("Банк-Зразок", category: "Послуги")
        let transfer = tx("Банк-Зразок", category: "", days: 1, kind: .transfer)
        let s = try store([anchor, transfer])

        XCTAssertEqual(s.othersDisagreeing(with: anchor.id), 0)
        XCTAssertEqual(s.transactions.first { $0.id == transfer.id }?.kind, .transfer)
    }

    /// A row with no category cannot be an anchor — there is nothing to apply.
    func testARowWithNoCategoryOffersNothing() throws {
        let blank = tx("Банк-Зразок", category: "", kind: .transfer)
        let other = tx("Банк-Зразок", category: "Послуги", days: 1)
        let s = try store([blank, other])
        XCTAssertEqual(s.othersDisagreeing(with: blank.id), 0)
    }

    // MARK: applying

    func testApplyingChangesEveryDisagreeingSiblingAndNothingElse() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let wrong1 = tx("Крамниця-Приклад", category: "Розваги", days: 1)
        let wrong2 = tx("Крамниця-Приклад", category: "Послуги", days: 2)
        let untouched = tx("Заклад-Зразок", category: "Розваги", days: 3)
        let s = try store([anchor, wrong1, wrong2, untouched])

        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 2)
        XCTAssertEqual(s.transactions.first { $0.id == wrong1.id }?.category, "Продукти")
        XCTAssertEqual(s.transactions.first { $0.id == wrong2.id }?.category, "Продукти")
        XCTAssertEqual(s.transactions.first { $0.id == untouched.id }?.category, "Розваги",
                       "another merchant's row is not this decision's business")
    }

    /// `.user`, not `.rule`. No rule is written, so a row claiming «за
    /// правилом» would point at a Правила screen listing no such rule.
    func testTheChangedRowsSayThePersonDecidedThemAndNotARule() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let wrong = tx("Крамниця-Приклад", category: "Розваги", days: 1, resolution: .pattern)
        let s = try store([anchor, wrong])

        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 1)
        XCTAssertEqual(s.transactions.first { $0.id == wrong.id }?.resolution, .user)
    }

    /// **No rule is written.** The «Завжди відносити …» toggle on the same
    /// screen does that, with its own copy about contradictions. Two controls
    /// on one screen that both teach rules is how a person stops being able to
    /// predict either.
    func testApplyingWritesNoRule() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let wrong = tx("Крамниця-Приклад", category: "Розваги", days: 1)
        let s = try store([anchor, wrong])
        let before = s.rules.count

        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 1)
        XCTAssertEqual(s.rules.count, before, "the backlog is not a statement about the future")
    }

    /// **One undo entry for the whole bulk change**, so a mis-tap on twelve
    /// rows costs one tap to reverse rather than twelve.
    func testUndoRestoresEverySweptRowInOneStep() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let wrong1 = tx("Крамниця-Приклад", category: "Розваги", days: 1)
        let wrong2 = tx("Крамниця-Приклад", category: "Послуги", days: 2)
        let s = try store([anchor, wrong1, wrong2])

        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 2)
        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.transactions.first { $0.id == wrong1.id }?.category, "Розваги")
        XCTAssertEqual(s.transactions.first { $0.id == wrong2.id }?.category, "Послуги")
        XCTAssertEqual(s.transactions.first { $0.id == anchor.id }?.category, "Продукти",
                       "undoing the sweep must not undo the correction that prompted it")
    }

    func testApplyingNothingChangesNothingAndPushesNoUndo() throws {
        let anchor = tx("Крамниця-Приклад", category: "Продукти")
        let agrees = tx("Крамниця-Приклад", category: "Продукти", days: 1)
        let s = try store([anchor, agrees])

        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 0)
        XCTAssertFalse(s.undoLast(), "an empty sweep must not leave an undo entry to spend")
    }

    /// The whole point, end to end: correcting one row and accepting the offer
    /// repairs a backlog that `confirm`'s cascade cannot reach, because those
    /// rows are already answered.
    func testTheWholeRepairPathOnRowsThatAreAlreadyAnswered() throws {
        let anchor = tx("Крамниця-Приклад", category: "Розваги")
        let others = (1...3).map { tx("Крамниця-Приклад", category: "Розваги", days: $0) }
        let s = try store([anchor] + others)

        s.setCategory(anchor.id, to: "Продукти")
        XCTAssertEqual(s.othersDisagreeing(with: anchor.id), 3)
        XCTAssertEqual(s.applyCategoryToSimilar(anchor.id), 3)
        XCTAssertTrue(s.transactions.allSatisfy { $0.category == "Продукти" })
    }
}
