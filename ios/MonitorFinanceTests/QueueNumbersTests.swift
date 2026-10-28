import XCTest
@testable import MonitorFinance

/// Board #8: one screen's worth of work, named once.
///
/// The queue showed 4 cards, the tab badge said 12 and the toolbar said «0 з
/// 12» — three numbers for one screen, because the badge counted PURCHASES
/// while the queue asks one question per CARD. The gap widened with board #7,
/// which gave every transfer a card of its own.
@MainActor
final class QueueNumbersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func tx(_ merchant: String, _ amount: Int = -100_00, days: Int = 0,
                    resolution: Resolution = .pending) -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: amount > 0 ? .income : .expense, category: "",
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

    // MARK: the badge speaks the screen's language

    /// **The card's first acceptance line.** Three purchases from one shop are
    /// one card and one question, and every number that describes the queue has
    /// to say so.
    func testTheBadgeCountsCardsAndNotPurchases() throws {
        let s = try store([tx("Крамниця-Приклад", -100_00),
                           tx("Крамниця-Приклад", -200_00),
                           tx("Крамниця-Приклад", -300_00),
                           tx("Маркет-Приклад", -50_00)])
        XCTAssertEqual(s.pendingRowCount, 4, "four purchases…")
        XCTAssertEqual(s.queueCardCount, 2, "…on two cards, which is the work")
        XCTAssertEqual(s.pendingCardCount, s.pendingGroups.count)
    }

    /// **The invariant that keeps this fixed.** `pendingCardCount` counts
    /// through `AppStore.cardId` rather than re-deriving what a card is; if
    /// anyone ever spells that rule a second time, this is what fails.
    ///
    /// The cases are the ones where the two could plausibly diverge: a merchant
    /// with many rows, a `GenericMerchant` that gets one card per row, the same
    /// merchant in both directions (income and expense are separate cards),
    /// and rows that are not pending at all.
    func testTheCardCountIsExactlyTheNumberOfCardsTheScreenWouldShow() throws {
        let s = try store([tx("Крамниця-Приклад", -100_00),
                           tx("крамниця-приклад ", -200_00),
                           tx("Маркет-Приклад", 500_00),
                           tx("Маркет-Приклад", -50_00),
                           tx("Переказ-Приклад", -10_00),
                           tx("Переказ-Приклад", -20_00),
                           tx("Переказ-Приклад", -30_00),
                           tx("Кава-Приклад", -80_00, resolution: .user),
                           tx("Чай-Приклад", -80_00, resolution: .skipped)])
        XCTAssertEqual(s.pendingCardCount, s.pendingGroups.count)
        XCTAssertEqual(s.pendingCardCount, 6,
                       "1 shop (2 rows, one spelt differently) + 2 kinds of one merchant "
                       + "+ 3 separate transfers")
        XCTAssertEqual(s.pendingRowCount, 7, "the answered and the skipped row are not counted")
    }

    /// The demo seed, which is what a person meets on a first launch and the
    /// shape neither number was checked against.
    func testTheSeedsOwnNumbersAgree() throws {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertEqual(s.pendingCardCount, s.pendingGroups.count)
        XCTAssertLessThan(s.pendingCardCount, s.pendingRowCount,
                          "precondition: the demo has a merchant with more than one pending row")
    }

    /// A receipt question is a card the screen shows and the done screen
    /// refuses to appear over, so a badge that ignored it would read 0 with a
    /// question up — a fourth disagreeing number rather than a fix.
    func testTheBadgeCountsTheReceiptQuestionsToo() throws {
        let s = try store([])
        XCTAssertEqual(s.queueCardCount, 0)

        // A receipt whose goods arrived but which matched no purchase — the
        // `.noPurchase` card. Built through the store's own loader so this
        // tracks whatever `receiptCards` actually counts.
        let receipt = try XCTUnwrap(SeedLoader.load().receipts.first)
        var loose = receipt
        loose.id = UUID()
        loose.itemsLandedAt = now
        s.receipts = [loose]
        s.transactions = []

        XCTAssertEqual(s.receiptCards().count, 1, "precondition: the receipt asks a question")
        XCTAssertEqual(s.queueCardCount, 1, "the badge must count it")
        XCTAssertEqual(s.pendingRowCount, 0, "…and it is not a purchase")
    }

    /// Answering one card moves the badge by one. It used to move by however
    /// many purchases that merchant happened to have, so the number jumped in
    /// steps nobody could predict from the screen.
    func testAnsweringOneCardMovesTheBadgeByOne() throws {
        let rows = [tx("Крамниця-Приклад", -100_00), tx("Крамниця-Приклад", -200_00),
                    tx("Маркет-Приклад", -50_00)]
        let s = try store(rows)
        XCTAssertEqual(s.queueCardCount, 2)

        s.confirm(rows[0].id, as: "Продукти")

        XCTAssertEqual(s.queueCardCount, 1, "one card answered, one card gone")
        XCTAssertEqual(s.pendingRowCount, 1, "…and it took both of that shop's purchases with it")
    }

    // MARK: progress can never read backwards

    /// **The card's second acceptance line.** `startCount` was captured once,
    /// on first appearance, so a sync landing mid-session added cards the
    /// denominator had never heard of and «2 з 12» became «−3 з 12».
    func testProgressNeverGoesNegativeWhenASyncLandsMidSession() {
        // Twelve at the start, five answered, then a sync brings twenty.
        let start = QueueView.Baseline(cards: 12, rows: 40)
        let after = QueueView.raised(start, cards: 27, rows: 90)

        XCTAssertEqual(QueueView.progressText(start: after.cards, remaining: 27, .uk), "0 з 27")
        XCTAssertFalse(QueueView.progressText(start: after.cards, remaining: 27, .uk).contains("-"))
        XCTAssertFalse(QueueView.progressText(start: after.cards, remaining: 27, .uk).contains("−"))
    }

    /// …and the numerator keeps counting from the raised baseline, rather than
    /// restarting. Answering one of the twenty-seven is «1 з 27», not «1 з 26»
    /// — which is what clamping the numerator alone would have produced.
    func testTheRaisedBaselineIsWhatTheProgressKeepsCountingFrom() {
        var start = QueueView.Baseline(cards: 12, rows: 40)
        start = QueueView.raised(start, cards: 27, rows: 90)
        start = QueueView.raised(start, cards: 26, rows: 89)   // one answered

        XCTAssertEqual(start.cards, 27, "the baseline only ever grows")
        XCTAssertEqual(start.rows, 90)
        XCTAssertEqual(QueueView.progressText(start: start.cards, remaining: 26, .uk), "1 з 27")
    }

    /// The belt-and-braces half: `raised` runs from `onAppear` and `onChange`,
    /// and a render can happen between a store mutation and the `onChange` that
    /// observes it — so the text function has to survive a stale baseline on
    /// its own.
    func testAStaleBaselineStillCannotProduceANegativeNumerator() {
        XCTAssertEqual(QueueView.progressText(start: 3, remaining: 9, .uk), "0 з 9")
        XCTAssertEqual(QueueView.progressText(start: nil, remaining: 9, .uk), "0 з 9")
        XCTAssertEqual(QueueView.progressText(start: 9, remaining: 0, .uk), "9 з 9")
        XCTAssertEqual(QueueView.progressText(start: nil, remaining: 0, .uk), "0 з 0")
    }

    /// Both scales are raised, independently: a sync bringing twenty purchases
    /// on three cards moves each by its own amount. One shared value would
    /// have made the done screen count in the badge's unit.
    func testBothScalesAreRaisedSeparately() {
        let start = QueueView.raised(nil, cards: 4, rows: 30)
        XCTAssertEqual(start, QueueView.Baseline(cards: 4, rows: 30))

        let after = QueueView.raised(start, cards: 7, rows: 50)
        XCTAssertEqual(after, QueueView.Baseline(cards: 7, rows: 50))
    }
}
