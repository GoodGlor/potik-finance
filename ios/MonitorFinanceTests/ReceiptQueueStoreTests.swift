import XCTest
@testable import MonitorFinance

/// Task 10: the store side of scan → land/fail → match → attach/delete.
/// Follows `ReceiptStoreTests`'s setup style (`MemoryRepository`, a seeded
/// `AppStore`) rather than inventing a second one.
@MainActor
final class ReceiptQueueStoreTests: XCTestCase {
    private var keychain: Keychain!
    private let now = Date(timeIntervalSince1970: 1_756_800_000)
    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    /// `demoRows: true` keeps the seed exactly as it ships (demo transactions
    /// with no `externalId`, ready to be swept); the default strips them, so
    /// most tests start from the empty, "fresh install" shape and build only
    /// the rows they need.
    /// `taxCabinetAPI` defaults to an immediate, never-hanging stub so every
    /// test that doesn't care about the network can ignore it — the wipe and
    /// gate tests below (task 12) pass their own.
    private func makeStore(_ repo: Repository = MemoryRepository(), demoRows: Bool = false,
                           taxCabinetAPI: TaxCabinetAPI = TaxCabinetStub(mode: .ok)) throws -> AppStore {
        var seed = try SeedLoader.load()
        if !demoRows {
            seed.transactions = []
            seed.receipts = []
            seed.rules = []
        }
        return AppStore(repository: repo, seed: seed, keychain: keychain, taxCabinetAPI: taxCabinetAPI)
    }

    private func check(sum: Int, register: String = "3000000001",
                       document: String = "1000000001", at: Date? = nil,
                       mac: String? = nil) -> FiscalCheck {
        FiscalCheck(registerNumber: register, documentNumber: document,
                    fiscalTime: at ?? now, fiscalSum: sum, mac: mac)
    }

    private func expense(amount: Int, at: Date? = nil, externalId: String? = nil) -> Transaction {
        Transaction(id: UUID(), date: at ?? now, kind: .expense, category: "",
                   merchant: "Продавець", amount: amount, cardSuffix: "1111",
                   bankId: "monobank", receiptId: nil, splits: [], resolution: .pending,
                   suggestions: [], externalId: externalId, hold: false)
    }

    private let account = MonobankAccount(id: "a1", type: "black", currencyCode: 980,
                                          balance: 0, creditLimit: 0,
                                          maskedPan: ["000000******1111"])

    private func liveRow(_ id: String = "r1", amount: Int = -250_00, at: Date? = nil) -> Transaction {
        MonobankMapper.transaction(
            MonobankStatementItem(id: id, time: Int((at ?? now).timeIntervalSince1970),
                                  description: "Продавець", mcc: 5411, amount: amount,
                                  operationAmount: nil, currencyCode: 980,
                                  commissionRate: 0, cashbackAmount: 0, balance: nil,
                                  hold: false, monoReceiptId: nil, counterName: nil),
            account: account)
    }

    private var aStep: SyncPlan.Step { .forward(account: "a1", from: now - 31 * day, to: now) }

    private func parsed(sum: Int = 100_00, model: String? = "ND-1", mac: String? = nil) -> ParsedCheck {
        ParsedCheck(registerModel: model, fiscalTotal: sum, fiscalTime: now, mac: mac,
                   lines: [ParsedLine(ordinal: 1, name: "Хліб", qtyMilli: 1000,
                                      grossSum: sum, discount: 0, netSum: sum, netUnitPrice: sum)])
    }

    // MARK: scan

    func testScanningCreatesAWaitingReceiptAndEnqueuesIt() throws {
        let s = try makeStore()

        let receipt = s.scan(check(sum: 250_00), now: now)

        XCTAssertTrue(s.receipts.contains { $0.id == receipt.id })
        XCTAssertTrue(receipt.isWaitingForItems, "no fetch has happened yet")
        XCTAssertNil(s.transactions.first { $0.receiptId == receipt.id }, "nothing to match yet")
        let pending = s.receiptQueue.first { $0.receiptId == receipt.id }
        XCTAssertEqual(pending?.attempts, 0)
        XCTAssertEqual(pending?.nextAttempt, ReceiptSchedule.firstAttempt(after: now))
        XCTAssertEqual(pending?.check, check(sum: 250_00))
    }

    func testScanningAPurchaseAlreadyInTheAppAttachesItImmediately() throws {
        let s = try makeStore()
        let tx = expense(amount: -250_00, externalId: "e1")
        s.transactions = [tx]

        let receipt = s.scan(check(sum: 250_00), now: now)

        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, receipt.id)
        // The goods still have to be fetched even though the purchase was
        // found immediately.
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == receipt.id })
    }

    func testScanningTwiceTheSameCheckDoesNotEnqueueItTwice() throws {
        let s = try makeStore()
        let c = check(sum: 100_00)

        let first = s.scan(c, now: now)
        let second = s.scan(c, now: now.addingTimeInterval(30))

        XCTAssertEqual(first.id, second.id, "the fiscal document's identity, not a fresh id per scan")
        XCTAssertEqual(s.receiptQueue.filter { $0.receiptId == first.id }.count, 1)
        XCTAssertEqual(s.receipts.filter { $0.id == first.id }.count, 1)
    }

    // MARK: land / fail

    func testLandingItemsFillsTheReceiptAndLeavesTheQueue() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00), now: now)

        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))

        let landed = s.receipts.first { $0.id == receipt.id }
        XCTAssertEqual(landed?.items.count, 1)
        XCTAssertEqual(landed?.registerModel, "ND-1")
        XCTAssertEqual(landed?.itemsLandedAt, now.addingTimeInterval(90))
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id },
                       "landed items must leave the queue behind")
    }

    func testLandingItemsOnAWipedReceiptIsIgnoredRatherThanResurrectingIt() throws {
        let s = try makeStore()
        let ghost = UUID()

        s.landItems(parsed(), on: ghost, now: now)

        XCTAssertFalse(s.receipts.contains { $0.id == ghost })
        XCTAssertTrue(s.receiptQueue.isEmpty, "nothing should have been conjured into the queue either")
    }

    /// Final review F3/M2: `ReceiptBuilder.macMatches` was specified, built
    /// and tested but never actually called anywhere; the first wiring
    /// routed a mismatch through `failFetch`, which was reverted before
    /// merge — the lookup that fetched this document already matched on
    /// id+fn+sm+date, so a `<MAC>` mismatch is not evidence the document is
    /// wrong, only that the control number could not be confirmed (see
    /// `fiscal_check_2`'s hex `<MAC>` against the other seven's base64, with
    /// no captured QR in this repo to check it against). Failing the fetch
    /// would strand a correctly-fetched receipt for 48h and then mislabel it
    /// as never published. The goods land as normal; the mismatch is kept
    /// only as an inert diagnostic nothing else reads.
    func testAMismatchedControlNumberStillLandsTheGoodsAndRecordsTheMismatch() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00, mac: "AAAA="), now: now)

        s.landItems(parsed(sum: 100_00, mac: "ZZZZ="), on: receipt.id, now: now.addingTimeInterval(90))

        let landed = s.receipts.first { $0.id == receipt.id }
        XCTAssertEqual(landed?.itemsLandedAt, now.addingTimeInterval(90),
                       "a control-number mismatch must not withhold goods the lookup key already confirmed")
        XCTAssertEqual(landed?.items.count, 1)
        XCTAssertTrue(landed?.controlNumberMismatch ?? false,
                      "the mismatch is recorded, just not acted on")
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id },
                       "landed items must leave the queue behind, mismatch or not")
    }

    func testAMatchedControlNumberLeavesTheDiagnosticFalse() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00, mac: "AAAA="), now: now)

        s.landItems(parsed(sum: 100_00, mac: "AAAA="), on: receipt.id, now: now.addingTimeInterval(90))

        let landed = s.receipts.first { $0.id == receipt.id }
        XCTAssertFalse(landed?.controlNumberMismatch ?? true)
    }

    func testAFailedFetchAdvancesTheScheduleAndKeepsTheReceipt() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00), now: now)
        let failAt = now.addingTimeInterval(60)

        s.failFetch(receipt.id, reason: .notPublished, now: failAt)

        XCTAssertTrue(s.receipts.contains { $0.id == receipt.id }, "a failed fetch never deletes the receipt")
        let pending = s.receiptQueue.first { $0.receiptId == receipt.id }
        XCTAssertEqual(pending?.attempts, 1)
        XCTAssertEqual(pending?.nextAttempt, ReceiptSchedule.nextAttempt(afterAttempts: 1, now: failAt))
        XCTAssertNotNil(pending?.lastError)
    }

    // MARK: match

    func testARowArrivingLaterClaimsTheWaitingReceipt() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 250_00), now: now)
        XCTAssertNil(s.transactions.first { $0.receiptId == receipt.id })

        s.ingest([liveRow("r1", amount: -250_00, at: now)], step: aStep, wasEmpty: false)

        let tx = s.transactions.first { $0.externalId == "r1" }
        XCTAssertEqual(tx?.receiptId, receipt.id, "ingest must re-match, not just insert the row")
    }

    func testASecondReceiptCannotStealAPurchaseThatAlreadyHasOne() throws {
        let s = try makeStore()
        let tx = expense(amount: -100_00, externalId: "e1")
        s.transactions = [tx]

        let first = s.scan(check(sum: 100_00, document: "1000000001"), now: now)
        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, first.id)

        let second = s.scan(check(sum: 100_00, document: "1000000002"), now: now)

        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, first.id,
                       "the first receipt keeps the purchase it already claimed")
        XCTAssertTrue(s.looseReceipts.contains { $0.id == second.id },
                      "the second receipt found nothing left to claim")
    }

    // MARK: rescanning the same paper (review, Important 3)

    /// `landItems` removes the queue entry once the goods arrive, but the
    /// `Receipt` itself stays on file — rescanning the same paper after that
    /// point (plausible: it is still in the user's hand) must return that
    /// same receipt rather than mint a second one nothing can ever
    /// auto-match (the transaction's `receiptId` is no longer nil).
    func testRescanningAfterItemsHaveLandedReturnsTheSameReceiptRatherThanMintingATwin() throws {
        let s = try makeStore()
        let c = check(sum: 100_00)
        let receipt = s.scan(c, now: now)
        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id }, "precondition: no longer queued")

        let rescanned = s.scan(c, now: now.addingTimeInterval(200))

        XCTAssertEqual(rescanned.id, receipt.id)
        XCTAssertEqual(s.receipts.filter { $0.id == receipt.id }.count, 1, "never a second receipt for one document")
    }

    /// The other half: a deliberate delete really does let a rescan start
    /// fresh, because `deleteReceipt` removes the record `scan` dedupes
    /// against.
    func testDeletingThenRescanningStartsAFreshReceipt() throws {
        let s = try makeStore()
        let c = check(sum: 100_00)
        let original = s.scan(c, now: now)
        s.deleteReceipt(original.id)

        let rescanned = s.scan(c, now: now.addingTimeInterval(10))

        XCTAssertNotEqual(rescanned.id, original.id, "a deliberate delete-then-rescan is a fresh record")
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == rescanned.id })
    }

    // MARK: the demo sweep (A2)

    /// A2: the one-time demo sweep deletes every receipt no transaction points
    /// at. A receipt scanned seconds ago has no transaction BY DESIGN.
    func testTheDemoSweepSparesAReceiptTheQueueIsStillWaitingOn() throws {
        let s = try makeStore(demoRows: true)
        // A document identity that cannot collide with the bundled demo
        // receipts (which use the same "300000000N"/"100000000N" numbering
        // this file's `check()` default does) — a collision would make `scan`
        // return the EXISTING demo receipt instead of minting and enqueuing a
        // new one, which is exactly the false pass this test must not have.
        let receipt = s.scan(check(sum: 12_34, register: "9000000000", document: "9000000000"), now: now)
        XCTAssertNil(s.transactions.first { $0.receiptId == receipt.id })

        s.ingest([liveRow()], step: aStep, wasEmpty: false)   // triggers the sweep

        XCTAssertTrue(s.receipts.contains { $0.id == receipt.id },
                      "a scan made during the first sync must survive it")
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == receipt.id })
    }

    // MARK: both wipes (A8)

    func testWipingForANewClientEmptiesTheQueueAsWellAsTheReceipts() throws {
        let s = try makeStore()
        _ = s.scan(check(sum: 100_00), now: now)
        XCTAssertFalse(s.receiptQueue.isEmpty)
        let generationBefore = s.receiptGeneration

        s.wipeForNewClient(MonobankClientInfo(clientId: "new-client", name: "N", accounts: []))

        XCTAssertTrue(s.receiptQueue.isEmpty)
        XCTAssertTrue(s.receipts.isEmpty)
        XCTAssertGreaterThan(s.receiptGeneration, generationBefore,
                             "a fetch already in flight for the old dataset must find itself stale")
    }

    func testResettingEverythingEmptiesTheQueueAndBumpsItsGeneration() throws {
        let s = try makeStore()
        _ = s.scan(check(sum: 100_00), now: now)
        let generationBefore = s.receiptGeneration

        s.resetEverything()

        XCTAssertTrue(s.receiptQueue.isEmpty)
        XCTAssertGreaterThan(s.receiptGeneration, generationBefore)
    }

    // MARK: manual attach (A5/A6)

    /// A5/A6: the automatic match is exact, but a HAND-PICKED attach must
    /// still go through with a mismatched sum. «Чек на X, покупка на Y» is an
    /// advisory the owner reviewed in stage 5 and deliberately kept; this
    /// stage tightens the automatic path only, and must not quietly reverse a
    /// decision made on purpose.
    func testAManualAttachIsAllowedEvenWhenTheSumsDisagree() throws {
        let s = try makeStore()
        let tx = expense(amount: -90_00, externalId: "e1")
        s.transactions = [tx]
        // The sums disagree, so the automatic match at scan time must not
        // have already claimed this purchase — otherwise the assertion below
        // would pass without ever exercising the manual path.
        let receipt = s.scan(check(sum: 100_00), now: now)
        XCTAssertNil(s.transactions.first { $0.id == tx.id }?.receiptId,
                    "precondition: the automatic match must have refused a mismatched sum")

        s.attachManually(receipt.id, to: tx.id)

        let attached = s.transactions.first { $0.id == tx.id }
        XCTAssertEqual(attached?.receiptId, receipt.id)
        XCTAssertNotNil(AppStore.mismatch(attached!, receipt), "the advisory still fires")
    }

    /// Review, Important 1: `attach` only ever writes the NEW side. Moving a
    /// receipt from one transaction to another by hand must let the old one
    /// go — pointer and splits both — or the loser is left with a
    /// `receiptId` pointing at nothing reachable and splits describing goods
    /// it can no longer show (exactly what `clearSplits`'s doc comment exists
    /// to prevent).
    func testRepointingAReceiptByHandDetachesTheLoserAndItsSplits() throws {
        let s = try makeStore()
        let txA = expense(amount: -999_00, externalId: "e1")
        let txB = expense(amount: -999_00, externalId: "e2")
        s.transactions = [txA, txB]
        // A sum nothing in `transactions` matches, so the automatic path at
        // scan time never claims either purchase — both attaches below are
        // deliberately manual.
        let receipt = s.scan(check(sum: 1_234_00), now: now)
        s.attachManually(receipt.id, to: txA.id)
        let aIndex = s.transactions.firstIndex { $0.id == txA.id }!
        s.transactions[aIndex].splits = [Split(id: UUID(), name: "Хліб", amount: -999_00, category: "Продукти")]

        s.attachManually(receipt.id, to: txB.id)

        XCTAssertEqual(s.transactions.first { $0.id == txB.id }?.receiptId, receipt.id)
        let loser = s.transactions.first { $0.id == txA.id }
        XCTAssertNil(loser?.receiptId, "the loser must let go of the pointer")
        XCTAssertEqual(loser?.splits, [], "…and the splits describing goods it can no longer show")
        XCTAssertEqual(s.receipts.filter { $0.id == receipt.id }.count, 1,
                       "still exactly one receipt — moved, not duplicated or orphaned")
    }

    // MARK: detach orphaning the queue (final review, F1)

    /// `detachReceipt` used to remove the receipt from `receipts` but leave
    /// its `PendingReceipt` behind: invisible (no `Receipt` -> no card) and
    /// undeletable (`deleteReceipt` is card-only), but still due, so
    /// `ReceiptFetcher` would re-fetch it on every wake for 48h and then
    /// leave it in `receiptQueue.json` forever. Live path: scan a QR that
    /// auto-attaches, then tap «Відкріпити» during the ~1h wait for the
    /// goods.
    func testDetachingDuringTheWaitRemovesTheQueueEntryToo() throws {
        let s = try makeStore()
        let tx = expense(amount: -100_00, externalId: "e1")
        s.transactions = [tx]
        let receipt = s.scan(check(sum: 100_00), now: now)
        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, receipt.id,
                       "precondition: the scan auto-attached")
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == receipt.id }, "precondition: still queued")

        s.detachReceipt(from: tx.id)

        XCTAssertFalse(s.receipts.contains { $0.id == receipt.id })
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id },
                       "an orphaned queue entry would be re-fetched forever and never be deletable")
    }

    /// The other half: a fetch already in flight when the user detaches must
    /// not resurrect the receipt, but it must still clear the queue entry it
    /// was fetching for. `landItems` used to guard on `receipts.firstIndex`
    /// BEFORE dequeuing, so a fetch landing for an already-detached receipt
    /// returned early and never reached the dequeue at all — this is what
    /// proves the fix put the dequeue first.
    func testAFetchThatLandsAfterADetachStillClearsTheQueueEntry() throws {
        let s = try makeStore()
        let tx = expense(amount: -100_00, externalId: "e1")
        s.transactions = [tx]
        let receipt = s.scan(check(sum: 100_00), now: now)
        s.detachReceipt(from: tx.id)
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id },
                       "precondition: the detach itself already dequeued it")

        // A fetch that was already in flight before the detach, landing
        // late — `ReceiptFetcher` holds its own copy of the queue entry, so
        // re-adding it here stands in for that in-flight request.
        s.receiptQueue.append(PendingReceipt(
            receiptId: receipt.id, check: check(sum: 100_00), scannedAt: now, attempts: 0,
            nextAttempt: ReceiptSchedule.firstAttempt(after: now), lastError: nil))

        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))

        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == receipt.id },
                       "landItems must dequeue even when the receipt itself is already gone")
        XCTAssertFalse(s.receipts.contains { $0.id == receipt.id }, "must not resurrect a detached receipt")
    }

    /// `attach`'s "replace the previous receipt" branch has the same hole:
    /// the receipt it displaces is removed from `receipts` but was left in
    /// `receiptQueue`. Reached here through `attachManually`, which is how
    /// the app itself calls into it.
    func testReplacingAnAttachedReceiptDequeuesThePreviousOne() throws {
        let s = try makeStore()
        let tx = expense(amount: -100_00, externalId: "e1")
        s.transactions = [tx]
        let first = s.scan(check(sum: 100_00, document: "1000000001"), now: now)
        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, first.id, "precondition")
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == first.id }, "precondition: still queued")
        let second = s.scan(check(sum: 200_00, document: "1000000002"), now: now)

        s.attachManually(second.id, to: tx.id)

        XCTAssertFalse(s.receipts.contains { $0.id == first.id }, "attach replaces the previous receipt")
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == first.id },
                       "the replaced receipt's queue entry must not be re-fetched forever either")
    }

    // MARK: retry (review, Important 2)

    /// Pins the reasoning behind `retryNow`'s four field resets: nudging only
    /// `nextAttempt` would leave the entry due but still given-up, since
    /// `ReceiptSchedule.hasGivenUp` reads `scannedAt`, and `ReceiptSchedule.due`
    /// excludes a given-up entry no matter what `nextAttempt` says.
    func testRetryingRestartsTheClockSoTheEntryIsDueAgain() throws {
        let s = try makeStore()
        let longAgo = now.addingTimeInterval(-49 * 3600)
        let receipt = s.scan(check(sum: 100_00), now: longAgo)
        s.failFetch(receipt.id, reason: .notPublished, now: longAgo)
        XCTAssertTrue(ReceiptSchedule.due(s.receiptQueue, now: now).isEmpty, "precondition: given up")

        s.retryNow(receipt.id, now: now)

        XCTAssertEqual(ReceiptSchedule.due(s.receiptQueue, now: now).map(\.receiptId), [receipt.id],
                       "a nudged nextAttempt alone leaves it due but still given-up")
        XCTAssertEqual(s.receiptQueue.first?.attempts, 0)
        XCTAssertNil(s.receiptQueue.first?.lastError)
        // Direct, not just via `due()`: with `scannedAt` this far in the past,
        // `failFetch`'s own `nextAttempt` (a few backoff minutes after
        // `longAgo`) is ALREADY `<= now`, so the `due()` assertion above stays
        // green even if `retryNow` forgot to touch `nextAttempt` at all —
        // confirmed by actually dropping that line and rerunning this test.
        // This is the assertion that line is pinned by.
        XCTAssertEqual(s.receiptQueue.first?.nextAttempt, now)
        XCTAssertEqual(s.receipts.first { $0.id == receipt.id }?.scannedAt, longAgo,
                       "the record of when the user actually scanned is not rewritten")
    }

    // MARK: delete

    func testDeletingAReceiptRemovesItFromTheQueueAndTheStore() throws {
        let s = try makeStore()
        let loose = s.scan(check(sum: 100_00, document: "1000000001"), now: now)
        XCTAssertTrue(s.receiptQueue.contains { $0.receiptId == loose.id })

        s.deleteReceipt(loose.id)

        XCTAssertFalse(s.receipts.contains { $0.id == loose.id })
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == loose.id })

        // The same must hold for a receipt that IS attached — going through
        // `detachReceipt` rather than a bare array removal, so the
        // transaction's link and splits are cleared too.
        let tx = expense(amount: -50_00, externalId: "e1")
        s.transactions = [tx]
        let attached = s.scan(check(sum: 50_00, document: "1000000002"), now: now)
        XCTAssertEqual(s.transactions.first { $0.id == tx.id }?.receiptId, attached.id)

        s.deleteReceipt(attached.id)

        XCTAssertFalse(s.receipts.contains { $0.id == attached.id })
        XCTAssertNil(s.transactions.first { $0.id == tx.id }?.receiptId)
        XCTAssertFalse(s.receiptQueue.contains { $0.receiptId == attached.id })
    }

    // MARK: persistence

    func testTheQueueSurvivesARelaunch() async throws {
        let repo = MemoryRepository()
        let s = try makeStore(repo)
        let receipt = s.scan(check(sum: 100_00), now: now)
        // The real 300 ms debounce, not persistNow(): this must fail if
        // `scan` drops its persist().
        try await Task.sleep(for: .milliseconds(500))

        let reloaded = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        XCTAssertTrue(reloaded.receiptQueue.contains { $0.receiptId == receipt.id })
        XCTAssertTrue(reloaded.receipts.contains { $0.id == receipt.id })
    }

    // MARK: receiptCards (R1)

    /// A receipt still waiting inside its retry window is work in progress,
    /// not a question for the user — showing it as a card would ask them to
    /// answer something the app is already handling.
    func testAReceiptStillInsideItsRetryWindowIsNotACard() throws {
        let s = try makeStore()
        _ = s.scan(check(sum: 100_00), now: now)

        XCTAssertTrue(s.receiptCards(now: now).isEmpty)
    }

    func testAReceiptWithLandedItemsAndNoMatchIsANoPurchaseCard() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00), now: now)
        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))

        guard case .some(.noPurchase(let card)) = s.receiptCards(now: now).first(where: { $0.id == receipt.id }) else {
            return XCTFail("expected a .noPurchase card")
        }
        XCTAssertEqual(card.id, receipt.id)
    }

    func testAReceiptThatHasGivenUpIsANotPublishedCard() throws {
        let s = try makeStore()
        let longAgo = now.addingTimeInterval(-49 * 3600)   // past the 48 h window
        let receipt = s.scan(check(sum: 100_00), now: longAgo)
        // F6: `hasGivenUp` also requires `attempts > 0` — "gave up" means "we
        // asked and were refused", not merely "a long time passed".
        s.failFetch(receipt.id, reason: .notPublished, now: longAgo)

        guard case .some(.notPublished(let card)) = s.receiptCards(now: now).first(where: { $0.id == receipt.id }) else {
            return XCTFail("expected a .notPublished card")
        }
        XCTAssertEqual(card.id, receipt.id)
    }

    // MARK: itemsWaiting — board #185

    /// **The card that makes «combined with the categorization itself» true.**
    ///
    /// The owner asked for one flow. Before this, a receipt whose goods
    /// published hours after the purchase was categorized left them no way
    /// back to those items except finding the transaction again in the feed
    /// and expanding it — and nothing anywhere said there was anything to
    /// find.
    func testAnAttachedReceiptWithUnsortedItemsIsAnItemsWaitingCard() throws {
        let s = try makeStore()
        let tx = expense(amount: -100_00, externalId: "e1")
        s.transactions = [tx]
        let receipt = s.scan(check(sum: 100_00), now: now)
        XCTAssertEqual(s.transactions.first?.receiptId, receipt.id,
                       "precondition: the automatic match claimed the purchase")

        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))

        guard case .some(.itemsWaiting(let card)) =
                s.receiptCards(now: now).first(where: { $0.id == receipt.id }) else {
            return XCTFail("expected an .itemsWaiting card")
        }
        XCTAssertEqual(card.id, receipt.id)
        XCTAssertEqual(card.items.count, 1, "the card counts what there is to sort")
    }

    /// The other half of the same rule, and the one that keeps the queue from
    /// nagging: once the split is confirmed there is nothing left to do.
    func testConfirmingTheSplitRemovesTheItemsWaitingCard() throws {
        let s = try makeStore()
        s.transactions = [expense(amount: -100_00, externalId: "e1")]
        let receipt = s.scan(check(sum: 100_00), now: now)
        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))
        XCTAssertEqual(s.receiptCards(now: now).count, 1, "precondition: it is offered")

        let outcome = s.confirmSplits(for: s.transactions[0].id)
        guard case .ok = outcome else { return XCTFail("expected the split to confirm: \(outcome)") }

        XCTAssertTrue(s.receiptCards(now: now).isEmpty,
                      "a sorted receipt must stop asking to be sorted")
    }

    /// A receipt whose goods have NOT landed is still work in progress, and
    /// the whole point of the card is that the person is not made to wait for
    /// it — so it must not appear as something for them to do.
    func testAReceiptStillWaitingForItsGoodsIsNotAnItemsWaitingCard() throws {
        let s = try makeStore()
        s.transactions = [expense(amount: -100_00, externalId: "e1")]
        _ = s.scan(check(sum: 100_00), now: now)

        XCTAssertTrue(s.receiptCards(now: now).isEmpty)
    }

    /// A LOOSE receipt with items is a different question — «which purchase
    /// was this?» — and it already has its own card. Offering both would ask
    /// the person to sort goods onto a purchase that has not been chosen.
    func testALooseReceiptWithItemsStaysANoPurchaseCardAndNotBoth() throws {
        let s = try makeStore()
        let receipt = s.scan(check(sum: 100_00), now: now)
        s.landItems(parsed(sum: 100_00), on: receipt.id, now: now.addingTimeInterval(90))

        let cards = s.receiptCards(now: now)
        XCTAssertEqual(cards.count, 1, "one receipt asks one question at a time")
        guard case .some(.noPurchase) = cards.first else {
            return XCTFail("a receipt with no purchase is still asking which purchase")
        }
    }

    /// A receipt the tax service answered with no goods at all — the state
    /// every real on-device scan of an unrecognised QR produces. There is
    /// nothing to sort, and offering to sort nothing is worse than silence.
    func testAReceiptWithNoItemsIsNotOfferedForSorting() throws {
        let s = try makeStore()
        s.transactions = [expense(amount: -100_00, externalId: "e1")]
        let receipt = s.scan(check(sum: 100_00), now: now)
        let empty = ParsedCheck(registerModel: "ND-1", fiscalTotal: 100_00,
                                fiscalTime: now, mac: nil, lines: [])
        s.landItems(empty, on: receipt.id, now: now.addingTimeInterval(90))

        XCTAssertTrue(s.receiptCards(now: now).isEmpty)
    }

    /// The two questions come first: they are blocked on the person, while
    /// this one is work the app has already finished its half of.
    func testTheQuestionsAreOfferedBeforeTheWork() throws {
        let s = try makeStore()
        s.transactions = [expense(amount: -100_00, externalId: "e1")]
        let sorted = s.scan(check(sum: 100_00), now: now)
        s.landItems(parsed(sum: 100_00), on: sorted.id, now: now.addingTimeInterval(90))

        let loose = s.scan(check(sum: 55_00, document: "1000000002"), now: now)
        s.landItems(parsed(sum: 55_00), on: loose.id, now: now.addingTimeInterval(90))

        let cards = s.receiptCards(now: now)
        XCTAssertEqual(cards.count, 2)
        guard case .noPurchase = cards[0] else { return XCTFail("the question comes first") }
        guard case .itemsWaiting = cards[1] else { return XCTFail("then the work") }
    }

    // MARK: PendingReceipt persistence (R18)

    /// The queue is now persisted state, so its round trip belongs here — and
    /// through the app's own coders, not a freshly configured one: a round
    /// trip through different configuration proves less than it appears to.
    func testPendingReceiptRoundTripsThroughTheAppsOwnCoders() throws {
        let pending = PendingReceipt(receiptId: UUID(), check: check(sum: 123_45),
                                     scannedAt: now, attempts: 2,
                                     nextAttempt: now.addingTimeInterval(300),
                                     lastError: "notPublished")

        let data = try SeedLoader.encoder.encode(pending)
        let decoded = try SeedLoader.decoder.decode(PendingReceipt.self, from: data)

        XCTAssertEqual(decoded, pending)
    }

    // MARK: wiring the fetcher (task 12)

    /// `makeReceiptFetcher`'s `now`/`due` closures take an injected clock —
    /// `fetchDueReceipts(now:)` — for the same reason `receiptCards(now:)`
    /// takes it explicitly: the 48-hour `ReceiptSchedule.hasGivenUp` boundary
    /// this wiring depends on (via `ReceiptSchedule.due`) must be something a
    /// test can walk without waiting in real time. Every test below passes
    /// `now: { self.now }` — this file's own fixed clock — rather than letting the
    /// fetcher default to the real wall clock; a fixed `Date()` read at the
    /// wiring level is exactly what silently deadlocked this task's first
    /// pass: a receipt scanned at this file's fixed `now` (over a year
    /// before the real "today" this suite runs on) looked "given up" against
    /// the REAL clock, `due()` came back empty, and a gated fake tax cabinet
    /// was never asked — so a test waiting on that request hung forever.
    ///
    /// Scanned two minutes before `now`, not at it: `ReceiptSchedule.firstAttempt`
    /// adds a minute, so a receipt scanned exactly at the clock `due()` reads
    /// would not yet be due.
    private var dueScan: Date { now.addingTimeInterval(-120) }

    /// Mirrors `startSyncIfConnected`'s own UI-fixture gate — see its
    /// comment on `AppStore+Sync.swift`: real UI suites launch under
    /// `-skipOnboarding` against a bundled fixture several of them assert
    /// exact totals against, and a live fetch would mutate it out from under
    /// them on every launch. `skipOnboarding`/`noDemoData` are parameters on
    /// `fetchDueReceiptsIfAllowed` (defaulting to the real `Launch` flags in
    /// production) precisely so this is reachable in a test at all: the real
    /// flags are fixed for a process's whole life, and this bundle is never
    /// launched with `-skipOnboarding`.
    func testTheUiFixtureLaunchDoesNotFetchReceipts() async throws {
        let s = try makeStore()
        _ = s.scan(check(sum: 100_00), now: dueScan)

        let outcome = await s.fetchDueReceiptsIfAllowed(now: { self.now }, skipOnboarding: true, noDemoData: false)

        XCTAssertNil(outcome, "the UI fixture launch must suppress the fetch entirely")
    }

    /// `-noDemoData` is the one `-skipOnboarding` scenario that WANTS this to
    /// run — there is no bundled fixture there to disturb. Asserts an actual
    /// drain (`.drained(1)`, via the default `TaxCabinetStub(mode: .ok)`),
    /// not just "non-nil" — a receipt already given up would also read
    /// non-nil (`.idle`) and pass without the gate having let anything
    /// through at all.
    func testAnEmptyAppLaunchDoesFetchReceipts() async throws {
        let s = try makeStore()
        _ = s.scan(check(sum: 100_00), now: dueScan)

        let outcome = await s.fetchDueReceiptsIfAllowed(now: { self.now }, skipOnboarding: true, noDemoData: true)

        XCTAssertEqual(outcome, .drained(1))
    }

    /// The other half of `due()`'s filter, and the piece this task's own
    /// wiring had never actually exercised end to end: a receipt scanned
    /// more than 48 hours before the clock the fetcher reads must be skipped
    /// rather than asked about — `ReceiptSchedule.hasGivenUp`, reached this
    /// time through the real wired `fetchDueReceipts`, not called directly.
    func testAWiredFetchSkipsAGivenUpReceipt() async throws {
        let api = GatedTaxCabinetAPI()
        let s = try makeStore(taxCabinetAPI: api)
        let longAgo = now.addingTimeInterval(-49 * 3600)   // past the 48 h window
        let receipt = s.scan(check(sum: 100_00), now: longAgo)
        // F6: `hasGivenUp` also requires `attempts > 0` — without an actual
        // failed ask, this receipt is merely old, not given up, and the
        // fetcher below would (correctly, post-fix) try it instead of
        // skipping it.
        s.failFetch(receipt.id, reason: .notPublished, now: longAgo)

        let outcome = await s.fetchDueReceipts(now: { self.now })

        XCTAssertEqual(outcome, .idle, "a given-up receipt is never due, so there was nothing to ask")
        let didCall = await api.didAnswerAnything
        XCTAssertFalse(didCall, "the tax cabinet must never have been asked about a given-up receipt")
    }

    /// "One fetcher for the process, not one per call" — `AppStore.receiptFetcher`'s
    /// own doc comment — had zero coverage: every gated test elsewhere in
    /// this file calls `fetchDueReceipts` exactly once, so none of them can
    /// see whether a SECOND call rebuilds it. Confirmed by hand: replacing
    /// `if receiptFetcher == nil { … }` with an unconditional assignment left
    /// this whole suite green until this test was added — a fresh actor per
    /// call would forget `lastRequest` (fire immediately, defeating the 3 s
    /// pacer) and any live stand-down, silently, with nothing else here able
    /// to notice.
    func testOneFetcherServesTheWholeProcessNotOnePerCall() async throws {
        let s = try makeStore()
        _ = await s.fetchDueReceipts(now: { self.now })
        let first = s.receiptFetcher

        _ = await s.fetchDueReceipts(now: { self.now })

        XCTAssertTrue(first === s.receiptFetcher, "one fetcher per process — a fresh actor fires immediately")
    }

    // MARK: the dataset a fetch was started against being wiped mid-flight (task 12, highest-risk item)

    /// The receipt-fetch exposure that mirrors `SyncStoreTests`'
    /// `testAdoptingANewClientMidRunDropsTheWindowThatWasAlreadyInFlight`,
    /// one host over: `wipeForNewClient` runs only after the user agrees to
    /// start over, and a `ReceiptFetcher` request already in flight for the
    /// PREVIOUS person cannot be stopped — it is an actor parked inside a
    /// tax-cabinet request. Its result must land nowhere.
    func testWipingForANewClientMidFetchDropsTheResultAlreadyInFlight() async throws {
        let api = GatedTaxCabinetAPI()
        let s = try makeStore(taxCabinetAPI: api)
        _ = s.scan(check(sum: 100_00), now: dueScan)

        let run = Task { await s.fetchDueReceipts(now: { self.now }) }
        await api.waitForRequest()

        s.wipeForNewClient(MonobankClientInfo(clientId: "someone-else", name: "n", accounts: []))
        await api.answer()
        _ = await run.value

        XCTAssertTrue(s.receipts.isEmpty,
                      "the previous person's receipt must not survive into the new person's dataset")
        XCTAssertTrue(s.receiptQueue.isEmpty)
    }

    /// The generation check itself, isolated from the array-clearing
    /// `wipeForNewClient` also performs: `abandonReceiptFetch()` alone bumps
    /// `receiptGeneration` and releases `receiptFetcher`, but — deliberately,
    /// for this test — leaves the queue entry in place, with the same id a
    /// `fail` arriving late would still match. `failFetch` DOES guard against
    /// a missing id on its own (`AppStore+Receipts.swift:130`) — that is not
    /// what is under test here. Isolating the abandon from the array-clearing
    /// wipes is what proves the GENERATION check specifically: proven by hand
    /// per the task brief, dropping it from the `fail` closure in
    /// `AppStore.makeReceiptFetcher` makes this fail on the `attempts`
    /// assertion below — the whole reason this is a separate test from the
    /// one above, whose id-based guard alone already keeps it green.
    func testAFailFromAnAbandonedGenerationDoesNotAdvanceTheBackoff() async throws {
        let api = GatedTaxCabinetAPI()
        await api.setOutcome(.failure(.notPublished))
        let s = try makeStore(taxCabinetAPI: api)
        let receipt = s.scan(check(sum: 100_00), now: dueScan)
        let attemptsBefore = s.receiptQueue.first { $0.receiptId == receipt.id }?.attempts

        let run = Task { await s.fetchDueReceipts(now: { self.now }) }
        await api.waitForRequest()

        s.abandonReceiptFetch()
        await api.answer()
        _ = await run.value

        XCTAssertEqual(s.receiptQueue.first { $0.receiptId == receipt.id }?.attempts, attemptsBefore,
                       "a fail belonging to an abandoned generation must not advance this entry's backoff")
    }

    /// The `commit` closure's own generation check, isolated the same way —
    /// found NECESSARY, not redundant, despite `landItems`'s defensive
    /// id-lookup: `abandonReceiptFetch()` alone leaves the receipt in
    /// `receipts` (only a full wipe clears it), so that lookup finds a
    /// match regardless. Confirmed by hand: dropping the generation check
    /// from the `commit` closure leaves this file's whole suite GREEN — the
    /// two-person exposure this task exists for is real, but a test built
    /// only around the full `wipeForNewClient`/`resetEverything` paths would
    /// never have proven it, since both already clear `receipts` before a
    /// late commit could arrive.
    func testACommitFromAnAbandonedGenerationDoesNotLandItems() async throws {
        let api = GatedTaxCabinetAPI()
        await api.setOutcome(.success(parsed(sum: 100_00)))
        let s = try makeStore(taxCabinetAPI: api)
        let receipt = s.scan(check(sum: 100_00), now: dueScan)

        let run = Task { await s.fetchDueReceipts(now: { self.now }) }
        await api.waitForRequest()

        s.abandonReceiptFetch()
        await api.answer()
        _ = await run.value

        let stillWaiting = s.receipts.first { $0.id == receipt.id }
        XCTAssertNil(stillWaiting?.itemsLandedAt,
                     "a commit belonging to an abandoned generation must not land items on this receipt")
        XCTAssertTrue(stillWaiting?.items.isEmpty ?? true)
    }
}

/// A tax cabinet whose lookup parks until the test lets it answer, so a wipe
/// (or a bare `abandonReceiptFetch()`) can land in the middle of a fetch
/// already in flight. Mirrors `SyncStoreTests`' `GatedAPI`, one host over.
private actor GatedTaxCabinetAPI: TaxCabinetAPI {
    private var waiting: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var didCall = false
    private var outcome: Result<ParsedCheck, TaxCabinetError> = .failure(.notPublished)

    func setOutcome(_ outcome: Result<ParsedCheck, TaxCabinetError>) { self.outcome = outcome }

    var didAnswerAnything: Bool { didCall }

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        didCall = true
        arrival?.resume()
        arrival = nil
        // `waiting` is assigned before the suspension, and this actor is not
        // re-entered until then, so an `answer()` racing this cannot be lost.
        await withCheckedContinuation { waiting = $0 }
        switch outcome {
        case .success(let parsed): return parsed
        case .failure(let error): throw error
        }
    }

    /// Returns once the fetcher is parked inside `check`.
    func waitForRequest() async {
        guard !didCall else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func answer() { waiting?.resume(); waiting = nil }
}
