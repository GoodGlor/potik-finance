import XCTest
@testable import MonitorFinance

/// Board #80. A hold that settles at a different figure used to leave its
/// splits describing the amount it was authorised for.
///
/// The damage was silent and arithmetic: `Derived.byProductGroup` sums the
/// SPLITS and `Derived.byCategory` sums the AMOUNT, so the two halves of
/// Статистика disagreed by exactly the settlement difference — and
/// `byProductGroup`'s own doc comment promised they always agree.
@MainActor
final class SettledHoldSplitTests: XCTestCase {

    private let txId = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private let receiptId = UUID(uuidString: "B1000000-0000-4000-8000-000000000001")!

    private func makeStore() -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [], categories: [], rules: [],
                              receipts: [],
                              productGroups: [ProductGroup(name: "Бакалія", keywords: ["крупа"]),
                                              ProductGroup(name: "Напої", keywords: ["кава"])])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    /// A purchase with a receipt whose items sum to `itemised`, already split.
    private func seeded(_ store: AppStore, held: Int, itemised: Int) {
        let first = itemised / 2
        let receipt = Receipt(
            id: receiptId, scannedAt: Date(), registerNumber: "0000000000",
            documentNumber: "1", fiscalTime: Date(), fiscalSum: itemised,
            sellerName: "Продавець-Приклад",
            items: [Receipt.Item(id: UUID(), name: "Крупа", qty: 1,
                                 price: first, sum: first, category: "Бакалія"),
                    Receipt.Item(id: UUID(), name: "Кава", qty: 1,
                                 price: itemised - first, sum: itemised - first,
                                 category: "Напої")])
        store.receipts = [receipt]
        store.transactions = [Transaction(
            id: txId, date: Date(), kind: .expense, category: "Кафе та ресторани",
            merchant: "Кав'ярня-Приклад", amount: -held, cardSuffix: "*0000",
            bankId: "monobank", receiptId: receiptId, splits: [], resolution: .user,
            // `externalId` is not decoration here: `clearDemoRowsIfNeeded`
            // wipes every row without one on the first ingest, so a fixture
            // that omits it is deleted before the merge it is testing.
            suggestions: [], externalId: "mono-settled-1", hold: true)]
        store.confirmSplits(for: txId)
    }

    private func settle(_ store: AppStore, to amount: Int) {
        var row = store.transactions[0]
        row.amount = -amount
        row.hold = false
        store.ingestRows([row])
    }

    // MARK: the criterion

    /// The card's first criterion, measured through the two functions that
    /// disagreed rather than through the field they disagreed about.
    func testTheTwoStatisticsViewsAgreeAfterAHoldSettlesHigher() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 55_000)   // a tip

        let byCategory = Derived.byCategory(store.transactions).reduce(0) { $0 + $1.sum }
        let byGroup = Derived.byProductGroup(store.transactions).reduce(0) { $0 + $1.sum }
        XCTAssertEqual(byCategory, 55_000)
        XCTAssertEqual(byGroup, byCategory, "the two views of Статистика disagree")
    }

    func testTheTwoStatisticsViewsAgreeAfterAHoldSettlesLower() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 40_000)
        settle(store, to: 45_000)   // a pre-authorisation releasing down

        let byCategory = Derived.byCategory(store.transactions).reduce(0) { $0 + $1.sum }
        let byGroup = Derived.byProductGroup(store.transactions).reduce(0) { $0 + $1.sum }
        XCTAssertEqual(byCategory, 45_000)
        XCTAssertEqual(byGroup, byCategory)
    }

    /// The difference is not absorbed into the items — it becomes its own
    /// line, which is what makes it visible rather than merely consistent.
    /// Scaling the item amounts would have satisfied the sum and invented
    /// prices nobody paid.
    func testTheSettlementDifferenceBecomesItsOwnLineRatherThanMovingTheItems() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 55_000)

        let splits = store.transactions[0].splits
        let remainder = splits.first { $0.name == SplitMath.remainderName }
        XCTAssertEqual(remainder?.amount, 5_000, "the tip is not a line of its own")
        XCTAssertEqual(splits.first { $0.name == "Крупа" }?.amount, 25_000,
                       "an item's price was rewritten to make the sum work")
        XCTAssertEqual(splits.reduce(0) { $0 + $1.amount }, 55_000)
    }

    /// Settling back down removes a remainder that is no longer there.
    func testARemainderThatIsNoLongerThereGoesAway() {
        let store = makeStore()
        seeded(store, held: 55_000, itemised: 50_000)
        XCTAssertNotNil(store.transactions[0].splits.first { $0.name == SplitMath.remainderName },
                        "precondition: the held row had a remainder")

        settle(store, to: 50_000)
        XCTAssertNil(store.transactions[0].splits.first { $0.name == SplitMath.remainderName })
        XCTAssertEqual(store.transactions[0].splits.reduce(0) { $0 + $1.amount }, 50_000)
    }

    // MARK: when the receipt no longer fits

    /// Settling BELOW the receipt's own items leaves no honest split. The
    /// arithmetic goes rather than staying wrong, and the receipt stays —
    /// it is a real fact, and detaching it is the person's call.
    func testSettlingBelowTheReceiptDropsTheArithmeticAndKeepsTheReceipt() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 40_000)

        XCTAssertTrue(store.transactions[0].splits.isEmpty)
        XCTAssertEqual(store.transactions[0].receiptId, receiptId, "the receipt was thrown away")

        let byCategory = Derived.byCategory(store.transactions).reduce(0) { $0 + $1.sum }
        let byGroup = Derived.byProductGroup(store.transactions).reduce(0) { $0 + $1.sum }
        XCTAssertEqual(byGroup, byCategory, "an unsplit purchase must still total the same")
    }

    /// …and the whole charge lands under «Без чека», which is true rather
    /// than merely consistent.
    func testAnUnsplittableSettlementCountsAsUnreceipted() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 40_000)

        let groups = Derived.byProductGroup(store.transactions)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, Derived.noReceipt)
        XCTAssertEqual(groups.first?.sum, 40_000)
    }

    // MARK: what must NOT happen

    /// An amount that did not move must not touch the splits — including the
    /// `id`s, which are what SwiftUI diffs the rows on.
    func testAResyncThatChangesNothingLeavesTheSplitsAlone() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        let before = store.transactions[0].splits

        store.ingestRows([store.transactions[0]])
        XCTAssertEqual(store.transactions[0].splits, before)
    }

    /// A receipt attached but never confirmed stays unconfirmed. A settlement
    /// is the bank talking; it is not somebody agreeing to a split.
    func testASettlementDoesNotConfirmASplitNobodyConfirmed() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        store.transactions[0].splits = []

        settle(store, to: 55_000)
        XCTAssertTrue(store.transactions[0].splits.isEmpty,
                      "the sync drafted a split the person never confirmed")
    }

    /// The other bank-owned fields still land, and the resplit reads a fully
    /// settled row rather than a half-updated one.
    func testTheResplitSeesTheSettledRowAndNotAHalfUpdatedOne() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 55_000)

        XCTAssertEqual(store.transactions[0].hold, false, "the hold flag did not land")
        XCTAssertEqual(store.transactions[0].amount, -55_000)
        XCTAssertEqual(store.transactions[0].splits.reduce(0) { $0 + $1.amount }, 55_000)
    }

    /// A row whose receipt has vanished cannot hold splits describing it.
    func testSplitsWithNoReceiptBehindThemGoRatherThanSurviveASettlement() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        store.receipts = []

        settle(store, to: 55_000)
        XCTAssertTrue(store.transactions[0].splits.isEmpty)
    }

    // MARK: the mismatch a screen can show

    /// Nothing to say while the receipt fits — and this is the assertion a
    /// mutation needed: making the mismatch fire unconditionally would have
    /// put «Чек більший за покупку на 0,00 ₴» under every receipt in the app,
    /// and while the decision lived in the view nothing could see it.
    func testAReceiptThatFitsReportsNoMismatch() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        XCTAssertNil(store.splitMismatch(forReceipt: receiptId))

        settle(store, to: 55_000)
        XCTAssertNil(store.splitMismatch(forReceipt: receiptId),
                     "a tip is a remainder line, not a mismatch")
    }

    /// And the overshoot is the real figure, so the copy can name it.
    func testAReceiptThatOvershootsReportsByHowMuch() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 40_000)
        XCTAssertEqual(store.splitMismatch(forReceipt: receiptId), 10_000)
    }

    /// **Measured against the transaction the receipt is ON.** Every other
    /// fixture here holds exactly one row, so `transactions.first` and "the
    /// one with this receipt" are the same object and a mutation swapping
    /// them survives. On a real phone with a hundred rows they are not.
    func testTheMismatchIsMeasuredAgainstTheRowTheReceiptIsAttachedTo() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 40_000)
        XCTAssertEqual(store.splitMismatch(forReceipt: receiptId), 10_000)

        // A large unrelated purchase in front of it. Against THAT row the
        // receipt fits easily, so a lookup that grabs the first transaction
        // reports no mismatch at all.
        store.transactions.insert(Transaction(
            id: UUID(), date: Date(), kind: .expense, category: "Покупки",
            merchant: "Магазин-Приклад", amount: -500_000, cardSuffix: "*0000",
            bankId: "monobank", receiptId: nil, splits: [], resolution: .user,
            suggestions: [], externalId: "mono-unrelated"), at: 0)

        XCTAssertEqual(store.splitMismatch(forReceipt: receiptId), 10_000,
                       "the mismatch was measured against the wrong transaction")
    }

    /// A receipt attached to nothing has nothing to overshoot.
    func testALooseReceiptReportsNoMismatch() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        store.transactions[0].receiptId = nil
        XCTAssertNil(store.splitMismatch(forReceipt: receiptId))
    }

    /// The user's own decisions survive a settlement, which is the promise the
    /// merge branch of `ingestRows` opens with.
    func testASettlementDoesNotDisturbTheSpendingCategory() {
        let store = makeStore()
        seeded(store, held: 50_000, itemised: 50_000)
        settle(store, to: 55_000)

        XCTAssertEqual(store.transactions[0].category, "Кафе та ресторани")
        XCTAssertEqual(store.transactions[0].resolution, .user)
    }
}
