import XCTest
@testable import MonitorFinance

@MainActor
final class SplitStoreTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func store(_ repo: Repository = MemoryRepository()) throws -> AppStore {
        AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
    }

    /// The seed's pre-attached FUEL pair: a purchase whose receipt itemises
    /// exactly the charge, so it can be confirmed without a remainder line.
    ///
    /// Selected by the receipt's own content, not by "the first row with a
    /// receiptId" — the seed pre-attaches two receipts now (the second is a
    /// car wash in another month, the fixture the period-scoped drill needs)
    /// and array order would decide which one these tests got.
    private func fuelTx(_ s: AppStore) -> Transaction {
        s.transactions.first { tx in
            guard let receipt = s.receipt(for: tx) else { return false }
            return receipt.items.contains { FuelGrade.parse($0.name) != nil }
        }!
    }

    func testConfirmingWritesSplitsSummingToTheChargeAndTouchesNothingElse() throws {
        let s = try store()
        let tx = fuelTx(s)
        let receiptBefore = s.receipt(for: tx)!
        let resolutionBefore = tx.resolution
        let categoryBefore = tx.category
        let rulesBefore = s.rules.count

        let outcome = s.confirmSplits(for: tx.id)

        guard case .ok(let splits) = outcome else {
            return XCTFail("the seeded fuel receipt itemises exactly the charge; got \(outcome)")
        }
        XCTAssertFalse(splits.isEmpty)
        XCTAssertEqual(splits.reduce(0) { $0 + $1.amount }, abs(tx.amount),
                       "the splits must total the charge, not the receipt's own fiscalSum")
        XCTAssertEqual(splits.map(\.name), receiptBefore.items.map(\.name))

        let after = s.transactions.first { $0.id == tx.id }!
        XCTAssertEqual(after.splits, splits)
        // Confirming a PRODUCT-GROUP split is not a human decision about the
        // SPENDING category — resolution and category, and the rules table,
        // must be exactly as they were.
        XCTAssertEqual(after.resolution, resolutionBefore)
        XCTAssertEqual(after.category, categoryBefore)
        XCTAssertEqual(s.rules.count, rulesBefore, "confirming a split must write no merchant rule")

        // «Підтвердити» REWRITES the split set; it does not add to it. Every
        // other test in this file confirms exactly once on a fresh store, so
        // `transactions[index].splits += splits` would have passed all of
        // them and every UI suite — and then broken the equal-totals
        // invariant the moment the owner tapped the button a second time,
        // which the expanded feed row offers on every render.
        guard case .ok(let again) = s.confirmSplits(for: tx.id) else {
            return XCTFail("a second confirmation of a fitting receipt must also succeed")
        }
        let twice = s.transactions.first { $0.id == tx.id }!
        XCTAssertEqual(twice.splits.count, splits.count,
                       "a second «Підтвердити» must replace the split set, not append to it")
        XCTAssertEqual(twice.splits.reduce(0) { $0 + $1.amount }, abs(tx.amount),
                       "…so the splits still total the charge exactly once")
        XCTAssertEqual(twice.splits.map(\.name), again.map(\.name))
    }

    func testSetItemGroupSurvivesAReload() async throws {
        let repo = MemoryRepository()
        let s = try store(repo)
        let tx = fuelTx(s)
        let receipt = s.receipt(for: tx)!
        let item = receipt.items.first!

        s.setItemGroup(item.id, on: receipt.id, to: "Молочні продукти")
        // `persist()` is debounced by 300 ms. Calling `persistNow()` here
        // would make this pass for a store that never persists at all — wait
        // out the real debounce instead, then read the value back from a
        // second store over the same repository.
        try await Task.sleep(for: .milliseconds(500))

        let reloaded = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        let reloadedItem = reloaded.receipts.first { $0.id == receipt.id }?.items.first { $0.id == item.id }
        XCTAssertEqual(reloadedItem?.category, "Молочні продукти")
    }

    func testDetachingClearsSplits() throws {
        let s = try store()
        let tx = fuelTx(s)
        guard case .ok(let splits) = s.confirmSplits(for: tx.id), !splits.isEmpty else {
            return XCTFail("precondition: the fixture must confirm with non-empty splits")
        }
        XCTAssertFalse(s.transactions.first { $0.id == tx.id }!.splits.isEmpty)

        s.detachReceipt(from: tx.id)

        XCTAssertTrue(s.transactions.first { $0.id == tx.id }!.splits.isEmpty,
                      "a detached receipt's splits described items nobody can see any more")
    }

    func testAttachingADifferentReceiptClearsSplits() throws {
        let s = try store()
        let tx = fuelTx(s)
        guard case .ok(let splits) = s.confirmSplits(for: tx.id), !splits.isEmpty else {
            return XCTFail("precondition: the fixture must confirm with non-empty splits")
        }
        XCTAssertFalse(s.transactions.first { $0.id == tx.id }!.splits.isEmpty)

        let replacement = Receipt(id: UUID(), scannedAt: Date(), registerNumber: "3000000099",
                                  documentNumber: "1000000099", fiscalTime: Date(),
                                  fiscalSum: 1, sellerName: "Інша крамниця", items: [])
        s.attach(replacement, to: tx.id)

        XCTAssertTrue(s.transactions.first { $0.id == tx.id }!.splits.isEmpty,
                      "the old receipt is gone; its splits must not survive the replacement")
    }

    /// Whole-branch finding: `undoLast` restored a whole `Transaction`
    /// snapshot, and that snapshot carries `receiptId` and `splits` — fields
    /// no queue action ever writes and the receipts screens own. So undoing
    /// an unrelated CATEGORY decision could resurrect a split describing a
    /// receipt that has since been deleted, and put back the `receiptId`
    /// that `TransactionRow` shows its disclosure chevron on while
    /// `store.receipt(for:)` answers nil for it.
    ///
    /// The order is what makes the fixture: confirm first, so the snapshot
    /// `setCategory` takes is one WITH splits and WITH a receipt; then
    /// detach, which is the thing the undo must not reverse.
    func testUndoingACategoryEditDoesNotResurrectADetachedReceiptsSplits() throws {
        let s = try store()
        let tx = fuelTx(s)
        guard case .ok(let splits) = s.confirmSplits(for: tx.id), !splits.isEmpty else {
            return XCTFail("precondition: the fixture must confirm with non-empty splits")
        }
        let categoryBefore = tx.category
        let otherCategory = s.categories.map(\.name).first { $0 != categoryBefore }!
        s.setCategory(tx.id, to: otherCategory)
        // Precondition: the snapshot the undo will restore FROM is one that
        // carries both a receipt and its splits — otherwise this test would
        // pass against the old code for the wrong reason.
        XCTAssertFalse(s.transactions.first { $0.id == tx.id }!.splits.isEmpty)
        XCTAssertNotNil(s.transactions.first { $0.id == tx.id }!.receiptId)

        s.detachReceipt(from: tx.id)
        XCTAssertTrue(s.undoLast(), "precondition: there must be an undo entry to pop")

        let after = s.transactions.first { $0.id == tx.id }!
        XCTAssertTrue(after.splits.isEmpty,
                      "the receipt is gone; undoing a category edit must not bring its splits back")
        XCTAssertNil(after.receiptId,
                     "…nor the link to the deleted receipt — that is a disclosure onto nothing")
        XCTAssertNil(s.receipts.first { $0.id == tx.receiptId },
                     "precondition: the detach really did delete the receipt record")
        // The positive partner: the undo DID do its own job. Without this,
        // an `undoLast` that restored nothing at all would pass the three
        // assertions above.
        XCTAssertEqual(after.category, categoryBefore,
                       "the field the undo entry actually owns must be restored")
        XCTAssertEqual(after.resolution, tx.resolution)
    }

    /// A refusal must leave `splits` EXACTLY as it found them.
    ///
    /// This test used to prove nothing at all. It reached its oversized
    /// fixture through `attach`, and `attach` clears splits — so
    /// `splitsBefore` was always `[]` and the assertion below read
    /// `[] == []`. A mutation writing `splits = []` on the refusal branch
    /// stayed green, which is the exact case the assertion's own message
    /// claims to cover.
    ///
    /// So the splits are made non-empty FIRST, by confirming the seed's own
    /// fitting receipt, and the receipt is then pushed over the charge IN
    /// PLACE — `receipts` is internal and this test is `@testable`, so the
    /// item's `sum` can be raised without going near `attach`. `splitsBefore`
    /// is now a real, non-empty array, and a refusal that blanked it fails.
    func testARefusedConfirmationWritesNothing() throws {
        let s = try store()
        let tx = fuelTx(s)
        guard case .ok(let confirmed) = s.confirmSplits(for: tx.id), !confirmed.isEmpty else {
            return XCTFail("precondition: the fixture must confirm with non-empty splits")
        }
        let before = s.transactions.first { $0.id == tx.id }!
        let splitsBefore = before.splits
        let resolutionBefore = before.resolution
        XCTAssertFalse(splitsBefore.isEmpty,
                       "precondition: this test is worthless unless there is something to lose")

        // Push the ATTACHED receipt past the purchase without detaching or
        // re-attaching it, so nothing clears the splits on the way.
        let receiptIndex = s.receipts.firstIndex { $0.id == before.receiptId }!
        s.receipts[receiptIndex].items[0].sum += 500

        let outcome = s.confirmSplits(for: tx.id)

        XCTAssertEqual(outcome, .receiptExceedsPurchase(by: 500))
        let after = s.transactions.first { $0.id == tx.id }!
        XCTAssertEqual(after.splits, splitsBefore,
                       "a refusal must write nothing — not a new split set, and not an empty array")
        XCTAssertEqual(after.resolution, resolutionBefore)
    }
}
