import XCTest
@testable import MonitorFinance

/// Board #9: what a queue card actually says about itself.
///
/// The card was a plain white rectangle with nothing on it to say it opened
/// anything, and it described a salary as «1 покупка · 2 500 ₴» — income called
/// a purchase, with the sign that makes it income thrown away.
@MainActor
final class QueueCardTests: XCTestCase {
    override func setUp() { super.setUp(); pinUkrainianFormatting() }

    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func group(_ merchant: String, kind: TxKind, count: Int, total: Int,
                       date: Date? = nil) -> MerchantGroup {
        MerchantGroup(key: MerchantKey.normalize(merchant), merchant: merchant, kind: kind,
                      count: count, total: total, rowIds: [], date: date)
    }

    private func tx(_ merchant: String, _ amount: Int,
                    resolution: Resolution = .pending) -> Transaction {
        Transaction(id: UUID(), date: now, kind: amount > 0 ? .income : .expense, category: "",
                    merchant: merchant, amount: amount, cardSuffix: "*1111",
                    bankId: "monobank", receiptId: nil, splits: [],
                    resolution: resolution, suggestions: [])
    }

    // MARK: income is not a purchase

    /// The demo's one income card, which read «1 покупка · 2 500 ₴».
    func testAnIncomeCardSaysMoneyArrivedAndShowsTheSign() {
        let salary = group("Надходження-Приклад", kind: .income, count: 1, total: 250_000)
        XCTAssertEqual(QueueView.subtitle(for: salary, .uk), "1 надходження · +2 500 ₴")
    }

    /// …and the figure still rounds rather than truncates: 1 240,50 belongs to
    /// the 1 241 the rest of the app quotes (`Int.uah`).
    func testAnExpenseCardIsUnchangedAndUnsigned() {
        let shop = group("Крамниця-Приклад", kind: .expense, count: 3, total: 124_050)
        XCTAssertEqual(QueueView.subtitle(for: shop, .uk), "3 покупки · 1 241 ₴")
    }

    /// Only income is signed. A card's total is a magnitude — `groups` sums
    /// `abs(amount)` — and a «−» on every one of sixty-one expense cards
    /// distinguishes nothing; the «+» earns its place by being the exception.
    func testTheMinusIsNotAddedToEveryExpenseCard() {
        let shop = group("Крамниця-Приклад", kind: .expense, count: 1, total: 250_000)
        XCTAssertFalse(QueueView.subtitle(for: shop, .uk).contains("−"))
        XCTAssertFalse(QueueView.subtitle(for: shop, .uk).contains("-"))
        XCTAssertFalse(QueueView.subtitle(for: shop, .uk).contains("+"))
    }

    /// «надходження» is its own nominative plural for 2–4, so `one` and `few`
    /// being the same string is the language and not a copy-paste. 11–14 take
    /// the many form despite ending in 1–4; 21 does not.
    func testTheIncomeWordAgreesIncludingTheTeensException() {
        XCTAssertEqual(Plural.incomes(1, .uk), "1 надходження")
        XCTAssertEqual(Plural.incomes(3, .uk), "3 надходження")
        XCTAssertEqual(Plural.incomes(7, .uk), "7 надходжень")
        XCTAssertEqual(Plural.incomes(11, .uk), "11 надходжень", "11 is not 1")
        XCTAssertEqual(Plural.incomes(14, .uk), "14 надходжень", "14 is not 4")
        XCTAssertEqual(Plural.incomes(21, .uk), "21 надходження", "…and 21 IS 1")
    }

    /// A per-transaction card names its date instead of a count — thirty-five
    /// transfers all reading «1 покупка» would be indistinguishable — and the
    /// sign has to survive that branch too.
    func testAPerTransactionCardKeepsItsDateAndItsSign() {
        let one = group("Переказ-Приклад", kind: .income, count: 1, total: 50_000, date: now)
        let text = QueueView.subtitle(for: one, .uk)
        XCTAssertTrue(text.hasSuffix("· +500 ₴"), text)
        XCTAssertFalse(text.contains("надходження"), "a dated card names the day, not the count")
        XCTAssertEqual(text, "\(FeedView.dayTitle(now)) · +500 ₴")
    }

    // MARK: the invariant the wording rests on

    /// `subtitle` speaks in purchases or in arrivals, and has no third word —
    /// because a queue card can only ever be one of two kinds. Every path that
    /// types a row `.transfer` sets a non-pending resolution in the same
    /// breath (`PrivatMapper` at import, `applyingRule` at ingest,
    /// `markNotAnExpense` and `setNotAnExpense` on a tap), so a `.transfer`
    /// row never reaches the queue.
    ///
    /// Asserted rather than assumed: if that ever stops being true, a transfer
    /// card starts calling itself a purchase and this is what says so.
    func testAQueueCardIsNeverATransfer() throws {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertFalse(s.pendingGroups.isEmpty, "precondition: the demo has a queue")
        XCTAssertTrue(s.pendingGroups.allSatisfy { $0.kind != .transfer })
        XCTAssertTrue(s.transactions.allSatisfy { $0.kind != .transfer || $0.resolution != .pending })
    }

    /// …and it stays true after the two mutations that CREATE transfers: both
    /// resolve every row they retype, so none of them can fall back into the
    /// queue.
    func testRetypingARowAsATransferTakesItOutOfTheQueue() throws {
        var seed = try SeedLoader.load()
        let rows = [tx("Крамниця-Приклад", -100_00), tx("Крамниця-Приклад", -200_00)]
        seed.transactions = rows; seed.receipts = []; seed.rules = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))

        s.markNotAnExpense(rows[0].id)

        XCTAssertTrue(s.transactions.allSatisfy { $0.kind == .transfer })
        XCTAssertTrue(s.pendingGroups.isEmpty, "a transfer must not be left in the queue")
    }

    // MARK: the income card reaches the right picker

    /// The wording change would be cosmetic if the card still opened the
    /// spending list. `MerchantGroup` splits on kind so the picker can be told
    /// what it is asking about (board #3), and this is the seam between the
    /// two — the card that now says «надходження» is the one that must open
    /// the income picker.
    func testAnIncomeCardIsTheKindThePickerAsksAboutIncomeFor() throws {
        var seed = try SeedLoader.load()
        seed.transactions = [tx("Маркет-Приклад", -100_00), tx("Маркет-Приклад", 500_00)]
        seed.receipts = []; seed.rules = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))

        XCTAssertEqual(s.pendingGroups.count, 2, "one merchant, two kinds, two cards")
        let income = try XCTUnwrap(s.pendingGroups.first { $0.kind == .income })
        XCTAssertTrue(QueueView.subtitle(for: income, .uk).contains("надходження"))
        XCTAssertTrue(QueueView.subtitle(for: income, .uk).contains("+"))

        let expense = try XCTUnwrap(s.pendingGroups.first { $0.kind == .expense })
        XCTAssertTrue(QueueView.subtitle(for: expense, .uk).contains("покупка"))
    }
}
