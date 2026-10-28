import XCTest
@testable import MonitorFinance

@MainActor
final class ReceiptStoreTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        pinUkrainianFormatting()
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func store(_ repo: Repository = MemoryRepository()) throws -> AppStore {
        AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
    }

    private func receipt(sum: Int, check: String = "1000000001",
                         items: [Receipt.Item] = []) -> Receipt {
        Receipt(id: UUID(), scannedAt: Date(), registerNumber: "3000000001",
                documentNumber: check, fiscalTime: Date(), fiscalSum: sum,
                sellerName: "Магазин", items: items)
    }

    private func anExpense(_ s: AppStore) -> Transaction {
        s.transactions.first { $0.kind == .expense }!
    }

    func testAttachingLinksBothWaysAndSurvivesPersistence() async throws {
        let repo = MemoryRepository()
        let s = try store(repo)
        let tx = anExpense(s)
        let r = receipt(sum: abs(tx.amount))

        s.attach(r, to: tx.id)
        // No persistNow() here on purpose. `persist()` is debounced by 300 ms,
        // so calling persistNow() would write the file whether or not `attach`
        // ever asked for it — and the assertion below would pass for an
        // implementation that never persists. Wait for the real debounce
        // instead, so this test fails if `attach` drops its persist().
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, r.id)
        XCTAssertEqual(s.receipt(for: s.transactions.first { $0.id == tx.id }!)?.id, r.id)

        // A fresh store over the same repository: proves it was written, not
        // just held in memory.
        let reloaded = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        XCTAssertEqual(reloaded.transactions.first { $0.id == tx.id }?.receiptId, r.id)
        XCTAssertTrue(reloaded.receipts.contains { $0.id == r.id })
    }

    /// D4: any difference is real, because both numbers are minor units
    /// describing one purchase. No tolerance.
    func testAMismatchedSumIsReportedInBothDirections() throws {
        let s = try store()
        // AFTER the store, not in `setUp`: `AppStore.init` sets the formatting
        // language from its own settings, and this store's are the defaults —
        // «як у системі», which on an English simulator is English. That is
        // correct behaviour, so the test says which language its copy is in.
        s.setLanguage(.uk)
        var tx = anExpense(s)
        tx.amount = -980_00
        let text = AppStore.mismatch(tx, receipt(sum: 1_240_50))!
        XCTAssertTrue(text.contains("1 240,50 ₴"), text)
        XCTAssertTrue(text.contains("980,00 ₴"), text)
    }

    func testAMatchingSumSaysNothing() throws {
        let s = try store()
        var tx = anExpense(s)
        tx.amount = -1_240_50
        XCTAssertNil(AppStore.mismatch(tx, receipt(sum: 1_240_50)),
                     "the expense is negative and the receipt positive; comparing " +
                     "them without abs would report every match as a mismatch")
    }

    func testDetachingRemovesTheReceiptAndNotJustTheLink() async throws {
        let repo = MemoryRepository()
        let s = try store(repo)
        let tx = anExpense(s)
        let r = receipt(sum: abs(tx.amount))
        s.attach(r, to: tx.id)
        try await Task.sleep(for: .milliseconds(500))

        s.detachReceipt(from: tx.id)
        // The real 300 ms debounce, not persistNow(): this test must fail if
        // detachReceipt drops its persist(), because a detach that only mutates
        // memory brings the receipt back — still attached — on the next launch.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertNil(s.transactions.first { $0.id == tx.id }?.receiptId)
        XCTAssertFalse(s.receipts.contains { $0.id == r.id },
                       "a detach that clears the link but keeps the receipt grows " +
                       "an orphan nothing can ever reach or delete")

        let reloaded = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        XCTAssertNil(reloaded.transactions.first { $0.id == tx.id }?.receiptId)
        XCTAssertFalse(reloaded.receipts.contains { $0.id == r.id })
    }

    func testAttachingASecondReceiptReplacesTheFirstRatherThanOrphaningIt() throws {
        let s = try store()
        let tx = anExpense(s)
        let first = receipt(sum: 100_00, check: "1000000001")
        let second = receipt(sum: 200_00, check: "1000000002")
        let before = s.receipts.count

        s.attach(first, to: tx.id)
        s.attach(second, to: tx.id)

        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, second.id)
        XCTAssertFalse(s.receipts.contains { $0.id == first.id })
        XCTAssertEqual(s.receipts.count, before + 1, "one receipt in, one receipt out")
    }

    /// The picker and the decoder must read the BUNDLED catalogue, not the
    /// user's own receipts: `attach` appends to `receipts`, so a scanner fed
    /// from it grows one more "sample" — on a device, the seller-less,
    /// item-less record a real QR produces — and starts recognising whatever
    /// check number that record carried.
    func testTheSampleCatalogueIsUntouchedByAttaching() throws {
        let s = try store()
        let before = s.sampleReceipts
        // Non-empty, not a specific count: this is a precondition for the
        // rest of the test (there must be samples to protect), not a claim
        // about how many the seed ships — that number is Task 1's business.
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(before.map(\.id), s.receipts.map(\.id),
                       "precondition: a fresh store's receipts ARE the samples, "
                       + "which is exactly why reading the mutable array looked fine")

        s.attach(receipt(sum: 512_00, check: "9999999999"), to: anExpense(s).id)

        XCTAssertEqual(s.sampleReceipts.map(\.id), before.map(\.id),
                       "the catalogue is the bundle's, and attaching is not a bundle change")
        XCTAssertEqual(s.receipts.count, before.count + 1,
                       "precondition: the mutable array DID grow, so the assertion above "
                       + "is not passing because nothing happened")
    }
}
