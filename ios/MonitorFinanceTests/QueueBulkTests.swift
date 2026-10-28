import XCTest
@testable import MonitorFinance

/// Board #103 — one category answered for several queue cards.
///
/// Draining the demo queue is ~61 taps and an email backfill will be worse. Ten
/// coffee shops should be one gesture — but a bulk answer is also the easiest
/// place in the app to corrupt a lot of rows at once, which is what most of
/// this file is about.
@MainActor
final class QueueBulkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func tx(_ merchant: String, days: Int = 0, amount: Int = -100_00,
                    kind: TxKind? = nil) -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: kind ?? (amount > 0 ? .income : .expense), category: "",
                    merchant: merchant, amount: amount, cardSuffix: "*1111",
                    bankId: "monobank", receiptId: nil, splits: [],
                    resolution: .pending, suggestions: [])
    }

    private func store(_ rows: [Transaction]) throws -> AppStore {
        var seed = try SeedLoader.load()
        seed.transactions = rows; seed.receipts = []; seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func groups(_ s: AppStore, _ merchants: [String]) -> [MerchantGroup] {
        s.pendingGroups.filter { merchants.contains($0.merchant) }
    }

    // MARK: the sweep

    func testEveryCardInTheSelectionIsAnswered() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1),
                           tx("Кавʼярня-Три", days: 2)])
        let picked = groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві", "Кавʼярня-Три"])
        XCTAssertEqual(picked.count, 3, "precondition")

        XCTAssertEqual(s.confirmGroups(picked, as: "Кафе та ресторани"), 3)
        XCTAssertTrue(s.transactions.allSatisfy { $0.category == "Кафе та ресторани" })
        XCTAssertTrue(s.transactions.allSatisfy { $0.resolution == .user })
        XCTAssertTrue(s.pendingGroups.isEmpty, "the queue is that much shorter")
    }

    /// A card is a merchant's whole pending backlog, so answering three cards
    /// resolves every row behind them — the same cascade one confirmation
    /// performs, three times over.
    func testTheRowsBehindEachCardGoWithIt() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Одна", days: 1),
                           tx("Кавʼярня-Дві", days: 2)])
        let picked = groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві"])
        XCTAssertEqual(s.confirmGroups(picked, as: "Кафе та ресторани"), 3,
                       "two cards, three rows")
    }

    /// **`confirm` stays the only place a rule is written**, so the rules a
    /// bulk answer leaves are exactly the rules the same taps would have left.
    func testARuleIsWrittenForEveryMerchantInTheSweep() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1)])
        s.confirmGroups(groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві"]), as: "Кафе та ресторани")

        for merchant in ["Кавʼярня-Одна", "Кавʼярня-Дві"] {
            let key = MerchantKey.normalize(merchant)
            let rule = s.rules.first { $0.merchantKey == key }
            XCTAssertEqual(rule?.category, "Кафе та ресторани", "no rule for \(merchant)")
        }
    }

    // MARK: the corruption vector

    /// **The card's second criterion.** A merchant's income and its expenses
    /// are separate cards precisely because one category across directions is
    /// how a spending category lands on a salary. The screen disables the other
    /// kind; this refuses it again, so the rule survives a screen that forgets.
    func testAMixedSelectionIsRefusedOutright() throws {
        let s = try store([tx("Крамниця-Приклад"),
                           tx("Роботодавець-Зразок", days: 1, amount: 25_000_00)])
        let mixed = groups(s, ["Крамниця-Приклад", "Роботодавець-Зразок"])
        XCTAssertEqual(mixed.count, 2, "precondition: an expense card and an income card")

        XCTAssertEqual(s.confirmGroups(mixed, as: "Продукти"), 0)
        XCTAssertTrue(s.transactions.allSatisfy { $0.category.isEmpty },
                      "nothing may be written when the selection is refused")
        XCTAssertTrue(s.rules.isEmpty, "…and no rule either")
    }

    /// The control for the test above: **the same two cards, one kind at a
    /// time, both work.** Without it, a `confirmGroups` that refused
    /// everything would pass the refusal test.
    func testOneKindAtATimeIsAccepted() throws {
        let s = try store([tx("Крамниця-Приклад"),
                           tx("Роботодавець-Зразок", days: 1, amount: 25_000_00)])
        XCTAssertEqual(s.confirmGroups(groups(s, ["Крамниця-Приклад"]), as: "Продукти"), 1)
        XCTAssertEqual(s.confirmGroups(groups(s, ["Роботодавець-Зразок"]), as: "Зарплата"), 1)
    }

    func testAnEmptySelectionDoesNothing() throws {
        let s = try store([tx("Крамниця-Приклад")])
        XCTAssertEqual(s.confirmGroups([], as: "Продукти"), 0)
        XCTAssertTrue(s.rules.isEmpty)
    }

    // MARK: undo

    /// **One action, one undo.** `confirm` pushes an entry per call and the
    /// stack is one deep by design, so three confirmations would leave an entry
    /// that undoes the THIRD merchant and silently abandons two. This is the
    /// assertion that the sweep is put back whole.
    func testUndoingABulkAnswerRestoresEveryCard() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1),
                           tx("Кавʼярня-Три", days: 2)])
        s.confirmGroups(groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві", "Кавʼярня-Три"]),
                        as: "Кафе та ресторани")
        XCTAssertTrue(s.pendingGroups.isEmpty, "precondition")

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.pendingGroups.count, 3, "all three cards come back")
        XCTAssertTrue(s.transactions.allSatisfy { $0.category.isEmpty })
        XCTAssertTrue(s.transactions.allSatisfy { $0.resolution == .pending })
    }

    /// And the rules go with them — every merchant's, not just the last one's.
    /// A sweep that left three rules behind would answer these merchants
    /// silently at the next sync, on a decision the person had just withdrawn.
    func testUndoingABulkAnswerWithdrawsEveryRule() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1),
                           tx("Кавʼярня-Три", days: 2)])
        s.confirmGroups(groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві", "Кавʼярня-Три"]),
                        as: "Кафе та ресторани")
        XCTAssertEqual(s.rules.count, 3, "precondition")

        s.undoLast()
        XCTAssertTrue(s.rules.isEmpty, "every rule the sweep wrote is withdrawn")
    }

    /// A merchant that already had a rule gets that rule back, not nothing —
    /// `rulesBefore` is a snapshot, and an empty one would silently delete an
    /// answer the sweep merely replaced.
    func testUndoRestoresARuleTheSweepOverwroteRatherThanDeletingIt() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1)])
        // Answer one merchant first, the ordinary way.
        s.confirmGroups(groups(s, ["Кавʼярня-Одна"]), as: "Продукти")
        XCTAssertEqual(s.rules.count, 1, "precondition")

        // …then sweep both to something else, and undo that sweep.
        let s2 = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1)])
        s2.confirmGroups(groups(s2, ["Кавʼярня-Одна"]), as: "Продукти")
        s2.confirmGroups(groups(s2, ["Кавʼярня-Дві"]), as: "Кафе та ресторани")
        let before = s2.rules.count
        s2.undoLast()
        XCTAssertEqual(s2.rules.count, before - 1,
                       "the second sweep's rule goes; the first sweep's stays")
        XCTAssertEqual(s2.rules.first { $0.merchantKey == MerchantKey.normalize("Кавʼярня-Одна") }?
            .category, "Продукти")
    }

    /// Only the last action is undoable — the stack is one deep — so a sweep
    /// must REPLACE what `confirm` left rather than sit on top of it. Undoing
    /// twice must not resurrect a half-swept state.
    func testASweepLeavesExactlyOneUndoableAction() throws {
        let s = try store([tx("Кавʼярня-Одна"), tx("Кавʼярня-Дві", days: 1)])
        s.confirmGroups(groups(s, ["Кавʼярня-Одна", "Кавʼярня-Дві"]), as: "Кафе та ресторани")
        XCTAssertTrue(s.undoLast())
        XCTAssertFalse(s.undoLast(), "one action, one undo")
    }
}
