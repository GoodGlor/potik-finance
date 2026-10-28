import XCTest
@testable import MonitorFinance

/// Merchants whose name cannot say what was bought: they get one queue card
/// per purchase, they never learn a rule, and they never cascade.
@MainActor
final class GenericMerchantTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func tx(_ merchant: String, _ day: Int = 1, amount: Int = -50_000,
                    kind: TxKind = .expense) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!,
                    kind: kind, category: "", merchant: merchant, amount: amount,
                    cardSuffix: "*0000", bankId: "monobank", receiptId: nil, splits: [],
                    resolution: .pending, suggestions: [])
    }

    private func store(_ txs: [Transaction]) throws -> AppStore {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: keychain)
        s.transactions = txs
        s.rules = []
        return s
    }

    // MARK: the predicate

    func testTheAgreedFamiliesAreRecognised() {
        for merchant in ["Приклад на картку", "Переказ-Приклад", "Переказ зі своєї картки *0000",
                         "Нова Пошта №12", "Зняття готівки в банкоматі",
                         "платіж за приклад", "*0000", "537541******1234"] {
            XCTAssertTrue(GenericMerchant.matches(merchant), merchant)
        }
    }

    /// The other half, and the one that keeps the feature honest: a shop is
    /// still a shop. Every name here would cost its owner the one-tap flow if
    /// a pattern were written too loosely.
    func testOrdinaryShopsAreNot() {
        for merchant in ["Крамниця-Приклад", "Маркет-Приклад", "Кав'ярня-Приклад",
                         "Zoomagazin-Example", "Аптека-Приклад",
                         "Крамниця Хвіст"] {
            XCTAssertFalse(GenericMerchant.matches(merchant), merchant)
        }
    }

    func testMatchingIgnoresCaseAndPadding() {
        XCTAssertTrue(GenericMerchant.matches("   NOVAPAY   "))
        XCTAssertTrue(GenericMerchant.matches("ЗНЯТТЯ ГОТІВКИ"))
    }

    // MARK: the queue

    /// The headline. The demo seed's largest card was a card-to-card transfer
    /// with 35 rows, and one tap answered for all thirty-five.
    func testAGenericMerchantBecomesOneCardPerPurchase() throws {
        let rows = [tx("Приклад на картку", 1, amount: -50_000),
                    tx("Приклад на картку", 2, amount: -30_000),
                    tx("Приклад на картку", 3, amount: -20_000)]
        let s = try store(rows)

        let groups = s.pendingGroups
        XCTAssertEqual(groups.count, 3, "one card per transfer, not one card for the merchant")
        XCTAssertEqual(Set(groups.map(\.count)), [1])
        XCTAssertEqual(Set(groups.map(\.id)).count, 3, "three cards need three identities")
        XCTAssertEqual(groups.map(\.total), [50_000, 30_000, 20_000], "still biggest first")
        for group in groups {
            XCTAssertNotNil(group.date, "a per-transaction card shows which purchase it is")
            XCTAssertNotNil(group.rowId)
        }
    }

    /// The partner: an ordinary merchant is still answered once.
    func testAnOrdinaryMerchantIsStillOneCard() throws {
        let s = try store([tx("Маркет-Приклад", 1), tx("Маркет-Приклад", 2),
                           tx("Маркет-Приклад", 3)])
        let groups = s.pendingGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertNil(groups[0].date, "a merchant card spans dates and names none of them")
        XCTAssertNil(groups[0].rowId)
    }

    func testTheTwoKindsOfMerchantCoexistInOneQueue() throws {
        let s = try store([tx("Приклад на картку", 1, amount: -10_000),
                           tx("Приклад на картку", 2, amount: -10_000),
                           tx("Маркет-Приклад", 3, amount: -90_000),
                           tx("Маркет-Приклад", 4, amount: -90_000)])
        let groups = s.pendingGroups
        XCTAssertEqual(groups.count, 3, "one merchant card plus two transfer cards")
        XCTAssertEqual(groups[0].merchant, "Маркет-Приклад")
        XCTAssertEqual(groups[0].count, 2)
    }

    /// Two transfers of the same amount share a merchant, so they share a
    /// `key` — and a comparator that breaks ties on `key` would return false
    /// both ways and hand the order back to the dictionary iteration the sort
    /// exists to defend against. Their order would then change between
    /// launches, and the queue would look shuffled for no reason.
    func testTwoIdenticalTransfersHaveAStableOrder() throws {
        let rows = [tx("Приклад на картку", 1, amount: -20_000),
                    tx("Приклад на картку", 2, amount: -20_000),
                    tx("Приклад на картку", 3, amount: -20_000)]
        let s = try store(rows)

        let first = s.pendingGroups.map(\.id)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first, first.sorted(), "ties resolve by id, ascending")
        for _ in 0..<5 {
            XCTAssertEqual(s.pendingGroups.map(\.id), first, "the order must not move")
        }
    }

    // MARK: answering one

    func testConfirmingATransferAnswersThatRowAndNoOther() throws {
        let rows = [tx("Приклад на картку", 1), tx("Приклад на картку", 2), tx("Приклад на картку", 3)]
        let s = try store(rows)

        XCTAssertEqual(s.confirm(rows[0].id, as: "Продукти"), 1,
                       "one transfer is not a statement about the next one")
        XCTAssertEqual(s.transactions[0].category, "Продукти")
        XCTAssertEqual(s.transactions[0].resolution, .user)
        XCTAssertEqual(s.transactions[1].resolution, .pending)
        XCTAssertEqual(s.transactions[2].resolution, .pending)
    }

    func testConfirmingATransferTeachesNoRule() throws {
        let rows = [tx("Приклад на картку", 1)]
        let s = try store(rows)
        s.confirm(rows[0].id, as: "Продукти")
        XCTAssertTrue(s.rules.isEmpty,
                      "a rule here would answer for every future transfer")
    }

    /// The rule table is not merely unwritten — it is not consulted either. A
    /// rule taught by a build that predates this must not start typing
    /// transfers again at ingest.
    func testAnOldRuleForAGenericMerchantIsNeverAppliedToANewRow() throws {
        let s = try store([])
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Приклад на картку"),
                        category: "Продукти", ambiguous: false)]
        let arriving = tx("Приклад на картку", 5)
        s.ingest([arriving], step: .forward(account: "a1", from: arriving.date, to: arriving.date),
                 wasEmpty: false)

        let landed = try XCTUnwrap(s.transactions.first { $0.id == arriving.id })
        XCTAssertEqual(landed.resolution, .pending, "it must come back and ask")
        XCTAssertEqual(landed.category, "")
    }

    func testUndoingATransferAnswerLeavesTheRuleTableAlone() throws {
        let rows = [tx("Приклад на картку", 1)]
        let s = try store(rows)
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Маркет-Приклад"),
                        category: "Техніка", ambiguous: false)]
        s.confirm(rows[0].id, as: "Продукти")

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.transactions[0].resolution, .pending)
        XCTAssertEqual(s.rules.count, 1, "an undo that touched no rule may remove none")
        XCTAssertEqual(s.rules[0].category, "Техніка")
    }

    // MARK: «Це не витрата»

    /// The graver half. `markNotAnExpense`'s own comment describes the
    /// failure: a transfer rule for a merchant like this types EVERY future
    /// row `.transfer` at ingest, those rows never reach the queue, and
    /// `Derived` excludes them from every spending figure — a person's
    /// spending silently reads low, forever, with no way to see why.
    func testNotAnExpenseOnATransferWritesNoRuleAndCascadesNothing() throws {
        let rows = [tx("Зняття готівки", 1), tx("Зняття готівки", 2)]
        let s = try store(rows)

        XCTAssertEqual(s.markNotAnExpense(rows[0].id), 1)
        XCTAssertEqual(s.transactions[0].kind, .transfer)
        XCTAssertEqual(s.transactions[1].kind, .expense, "the sibling was never looked at")
        XCTAssertEqual(s.transactions[1].resolution, .pending)
        XCTAssertTrue(s.rules.isEmpty)
    }

    /// And the partner, so the assertions above are not simply describing a
    /// broken `markNotAnExpense`: an ordinary merchant still cascades and
    /// still learns.
    func testNotAnExpenseOnAnOrdinaryMerchantStillCascades() throws {
        let rows = [tx("Маркет-Приклад", 1), tx("Маркет-Приклад", 2)]
        let s = try store(rows)

        XCTAssertEqual(s.markNotAnExpense(rows[0].id), 2)
        XCTAssertEqual(s.transactions[1].kind, .transfer)
        XCTAssertEqual(s.rules.count, 1)
        XCTAssertEqual(s.rules[0].kind, .transfer)
    }

    // MARK: the group card the UI taps

    func testConfirmingAPerTransactionCardResolvesItsOwnRow() throws {
        let rows = [tx("Приклад на картку", 1, amount: -50_000), tx("Приклад на картку", 2, amount: -30_000)]
        let s = try store(rows)
        let smaller = try XCTUnwrap(s.pendingGroups.first { $0.total == 30_000 })

        XCTAssertEqual(s.confirmGroup(smaller, as: .category("Розваги")), 1)
        XCTAssertEqual(s.transactions[1].category, "Розваги")
        XCTAssertEqual(s.transactions[0].resolution, .pending, "the other card is still to answer")
        XCTAssertEqual(s.pendingGroups.count, 1)
    }
}
