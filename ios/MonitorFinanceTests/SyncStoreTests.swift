import XCTest
@testable import MonitorFinance

@MainActor
final class SyncStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)
    private let day: TimeInterval = 86_400

    /// A store with no transactions at all — the state a fresh install is in
    /// once the seed no longer ships (Task 8).
    private func store(_ repo: MemoryRepository = MemoryRepository()) -> AppStore {
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        return AppStore(repository: repo, seed: seed, keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private let account = MonobankAccount(id: "a1", type: "black", currencyCode: 980,
                                          balance: 0, creditLimit: 0,
                                          maskedPan: ["000000******1111"])

    private func row(_ id: String, amount: Int = -34_000, at: Date? = nil,
                     hold: Bool = false, mcc: Int? = 5411,
                     originalMcc: Int? = nil,
                     balanceAfterMinor: Int? = nil) -> Transaction {
        var tx = MonobankMapper.transaction(
            MonobankStatementItem(id: id, time: Int((at ?? now).timeIntervalSince1970),
                                  description: "Продавець", mcc: mcc,
                                  originalMcc: originalMcc, amount: amount,
                                  operationAmount: nil, currencyCode: 980,
                                  commissionRate: 0, cashbackAmount: 0, balance: nil,
                                  hold: hold, monoReceiptId: nil, counterName: nil),
            account: account)
        // No monobank row ever carries one — the field is PrivatBank's, and
        // `ingestRows` is the merge both banks share. Set here rather than
        // routed through `PrivatMapper` so the coalesce below is tested in the
        // same shape as `mcc`'s, one field at a time.
        tx.balanceAfterMinor = balanceAfterMinor
        return tx
    }

    private func forward(_ from: Date, _ to: Date) -> SyncPlan.Step {
        .forward(account: "a1", from: from, to: to)
    }

    // MARK: insert

    func testIngestingRowsAddsThemAndAdvancesTheCursorTogether() {
        let s = store()
        s.ingest([row("r1"), row("r2")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions.count, 2)
        XCTAssertEqual(s.syncState.cursors["a1"]?.newest, now)
        XCTAssertEqual(s.syncState.cursors["a1"]?.oldest, now - 31 * day)
        XCTAssertNotNil(s.syncState.lastSuccess)
    }

    /// `to` is the device clock at planning time. A phone whose clock ran ahead
    /// would park `newest` in the future, and once the clock is corrected the
    /// planner's `now.timeIntervalSince(newest)` stays negative for the whole
    /// length of the skew — that account silently stops syncing forward for a
    /// week. The cursor may never claim to know about the future.
    func testAForwardCursorIsNeverParkedInTheFuture() {
        let s = store()
        let ahead = Date().addingTimeInterval(7 * day)
        s.ingest([row("r1")], step: forward(ahead - 31 * day, ahead), wasEmpty: false)
        guard let newest = s.syncState.cursors["a1"]?.newest else {
            return XCTFail("the forward commit must still advance the cursor")
        }
        XCTAssertLessThan(newest, ahead, "a clock that ran ahead must not poison the cursor")
        XCTAssertLessThanOrEqual(newest, Date())
    }

    func testTheSameWindowIngestedTwiceDoesNotDuplicate() {
        let s = store()
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions.count, 1)
    }

    // MARK: the merge rule

    /// The test that matters. Both halves: asserting only the first passes for
    /// an implementation that ignores re-fetches entirely.
    func testARefetchUpdatesTheBankSFieldsAndKeepsTheUserS() {
        let s = store()
        s.ingest([row("r1", amount: -34_000, hold: true)],
                 step: forward(now - 31 * day, now), wasEmpty: false)
        _ = s.confirm(s.transactions[0].id, as: "Продукти")
        XCTAssertEqual(s.transactions[0].category, "Продукти")

        // It settles at a different amount.
        s.ingest([row("r1", amount: -35_500, hold: false)],
                 step: forward(now - 3 * day, now), wasEmpty: false)

        XCTAssertEqual(s.transactions.count, 1)
        XCTAssertEqual(s.transactions[0].amount, -35_500, "the bank owns the amount")
        XCTAssertEqual(s.transactions[0].hold, false, "the bank owns hold")
        XCTAssertEqual(s.transactions[0].category, "Продукти", "the user owns the category")
        XCTAssertEqual(s.transactions[0].resolution, .user)
    }

    /// The backfill this field depends on. Every row synced before `mcc`
    /// existed carries nil, and the 31-day statement window is the only place
    /// the code can still be read — so a re-fetch that ignored it would leave
    /// a permanent hole in exactly the data the field was added to collect.
    func testARefetchFillsInAnMCCTheStoredRowNeverHad() {
        let s = store()
        s.ingest([row("r1", mcc: nil)], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertNil(s.transactions[0].mcc, "the precondition: a row from before the field")

        s.ingest([row("r1", mcc: 5411)], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].mcc, 5411, "the re-fetch is the only chance to fill it")
    }

    /// The other direction, and the reason the merge coalesces instead of
    /// assigning: a response that omits the code must not blank one already
    /// held, because nothing can ever ask for it again.
    func testARefetchWithoutAnMCCDoesNotBlankTheStoredOne() {
        let s = store()
        s.ingest([row("r1", mcc: 5411)], step: forward(now - 31 * day, now), wasEmpty: false)
        s.ingest([row("r1", mcc: nil)], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].mcc, 5411)
    }

    /// Board #56. `originalMcc` arrived later than `mcc`, so the population it
    /// has to backfill is larger: every row already stored WITH a code has no
    /// original beside it. Both directions of the coalesce in one test,
    /// because a plain assignment passes the first half and fails the second.
    func testARefetchBackfillsTheOriginalMCCAndNeverBlanksIt() {
        let s = store()
        s.ingest([row("r1", mcc: 7829)], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertNil(s.transactions[0].originalMcc, "the precondition: a row from before the field")

        s.ingest([row("r1", mcc: 7829, originalMcc: 4899)],
                 step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].originalMcc, 4899, "the window is the only chance")

        s.ingest([row("r1", mcc: 7829)], step: forward(now - 2 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].originalMcc, 4899,
                       "a response that omits it must not erase what is held")
    }

    /// The third coalesce in that block, and the one with teeth: a
    /// `balanceAfterMinor` is the ONLY thing the two PrivatBank sources can be
    /// matched on, so a row that lost its balance stops being recognisable as
    /// the purchase a letter already delivered — and lands twice, forever.
    /// Both directions in one test, because a plain assignment passes the
    /// first half and fails the second.
    func testARefetchBackfillsTheBalanceAndNeverBlanksIt() {
        let s = store()
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertNil(s.transactions[0].balanceAfterMinor,
                     "the precondition: a row from before the field")

        s.ingest([row("r1", balanceAfterMinor: 903_450)],
                 step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].balanceAfterMinor, 903_450,
                       "a re-import is the only chance to fill it in")

        s.ingest([row("r1")], step: forward(now - 2 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].balanceAfterMinor, 903_450,
                       "a source that sends no balance must not erase one that is held")
    }

    func testARefetchDoesNotResurrectAKindTheUserChanged() {
        let s = store()
        s.ingest([row("r1", amount: -50_000)], step: forward(now - 31 * day, now), wasEmpty: false)
        s.transactions[0].kind = .transfer
        s.ingest([row("r1", amount: -50_000)], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].kind, .transfer,
                       "the bank sets kind on insert only")
    }

    func testARefetchDoesNotDropSplitsOrAReceipt() {
        let s = store()
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        let id = s.transactions[0].id
        s.transactions[0].splits = [Split(id: UUID(), name: "Хліб", amount: 3_400, category: "Хліб")]
        s.transactions[0].receiptId = UUID()
        let receipt = s.transactions[0].receiptId
        s.ingest([row("r1")], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions.first { $0.id == id }?.splits.count, 1)
        XCTAssertEqual(s.transactions.first { $0.id == id }?.receiptId, receipt)
    }

    // MARK: cursors

    func testABackwardStepDeepensOldestAndCountsAnEmptyStreak() {
        let s = store()
        s.setSyncDepth(0)                                    // «Усе, що є»
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        s.ingest([], step: .backward(account: "a1", from: now - 62 * day, to: now - 31 * day),
                 wasEmpty: true)
        XCTAssertEqual(s.syncState.cursors["a1"]?.oldest, now - 62 * day)
        XCTAssertEqual(s.syncState.cursors["a1"]?.emptyStreak, 1)
        XCTAssertFalse(s.syncState.cursors["a1"]?.exhausted ?? true)

        s.ingest([], step: .backward(account: "a1", from: now - 93 * day, to: now - 62 * day),
                 wasEmpty: true)
        XCTAssertTrue(s.syncState.cursors["a1"]?.exhausted ?? false,
                      "two empty windows in a row is the end of the history")
    }

    func testANonEmptyWindowResetsTheStreak() {
        let s = store()
        s.setSyncDepth(0)
        s.ingest([], step: .backward(account: "a1", from: now - 62 * day, to: now - 31 * day),
                 wasEmpty: true)
        s.ingest([row("r9", at: now - 70 * day)],
                 step: .backward(account: "a1", from: now - 93 * day, to: now - 62 * day),
                 wasEmpty: false)
        XCTAssertEqual(s.syncState.cursors["a1"]?.emptyStreak, 0)
    }

    func testReachingTheChosenDepthExhaustsTheCursor() {
        let s = store()
        s.setSyncDepth(1)
        let floor = SyncPlan.depthFloor(depthMonths: 1, now: Date())!
        s.ingest([], step: .backward(account: "a1", from: floor, to: floor + day), wasEmpty: false)
        XCTAssertTrue(s.syncState.cursors["a1"]?.exhausted ?? false)
    }

    /// Found by Task 5's review. `exhausted` is decided against the depth floor
    /// in force at the time and the planner never re-evaluates it, so a cursor
    /// left exhausted after the user asks for MORE history never backfills
    /// again — the extra months silently never arrive.
    func testRaisingTheDepthLetsAnExhaustedCursorResume() {
        let s = store()
        s.setSyncDepth(3)
        s.syncState.cursors["a1"] = .init(newest: now, oldest: now - 90 * day,
                                          exhausted: true, emptyStreak: 2)
        s.setSyncDepth(12)
        XCTAssertEqual(s.syncState.cursors["a1"]?.exhausted, false)
        XCTAssertEqual(s.syncState.cursors["a1"]?.emptyStreak, 0)
        XCTAssertEqual(s.syncState.cursors["a1"]?.oldest, now - 90 * day,
                       "the depth changed, not the history already fetched")
    }

    func testSettingTheSameDepthChangesNothing() {
        let s = store()
        s.setSyncDepth(3)
        s.syncState.cursors["a1"] = .init(newest: now, oldest: now - 90 * day,
                                          exhausted: true, emptyStreak: 2)
        s.setSyncDepth(3)
        XCTAssertEqual(s.syncState.cursors["a1"]?.exhausted, true,
                       "a no-op must not restart a finished backfill")
    }

    // MARK: persistence

    func testIngestPersistsImmediatelyRatherThanOnADebounce() throws {
        let repo = MemoryRepository()
        let s = store(repo)
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        // NOT calling persistNow() here — the point is that ingest did.
        let saved = try repo.load("transactions", as: [Transaction].self)
        let cursor = try repo.load("sync", as: SyncState.self)
        XCTAssertEqual(saved?.count, 1)
        XCTAssertEqual(cursor?.cursors["a1"]?.newest, now)
    }

    // MARK: client identity

    private func info(_ id: String) -> MonobankClientInfo {
        MonobankClientInfo(clientId: id, name: "Тест", accounts: [account])
    }

    func testTheFirstTokenAdoptsItsClient() {
        let s = store()
        XCTAssertEqual(s.adoptClient(info("client-1")), .firstTime)
        XCTAssertNotNil(s.syncState.clientHash)
    }

    func testTheSameClientIsRecognised() {
        let s = store()
        _ = s.adoptClient(info("client-1"))
        XCTAssertEqual(s.adoptClient(info("client-1")), .sameClient)
    }

    /// Merging two people's money silently is the worst failure this app could
    /// have. Re-install, shared phone, a partner's token pasted by mistake.
    func testADifferentClientIsRefusedRatherThanMerged() {
        let s = store()
        _ = s.adoptClient(info("client-1"))
        XCTAssertEqual(s.adoptClient(info("client-2")), .differentClient)
    }

    func testTheClientIdItselfIsNeverStored() throws {
        let repo = MemoryRepository()
        let s = store(repo)
        _ = s.adoptClient(info("client-secret-id"))
        s.persistNow()
        for (_, data) in repo.files {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("client-secret-id"))
        }
    }

    func testWipingForANewClientClearsRowsAndCursorsButKeepsTheDepth() {
        let s = store()
        s.setSyncDepth(6)
        _ = s.adoptClient(info("client-1"))
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        // Seeded non-default so the post-wipe assertions below are not
        // vacuously true against SyncState's own zero/false defaults — a
        // left-alone emailCursor would otherwise claim every email letter up
        // to it was already imported, unreachable forever behind a dataset
        // that no longer has them.
        s.syncState.emailCursor = 42
        s.syncState.emailNeedsReconnect = true
        s.wipeForNewClient(info("client-2"))
        XCTAssertTrue(s.transactions.isEmpty)
        XCTAssertTrue(s.syncState.cursors.isEmpty)
        XCTAssertEqual(s.syncState.depthMonths, 6)
        XCTAssertEqual(s.adoptClient(info("client-2")), .sameClient)
        XCTAssertEqual(s.syncState.emailCursor, 0)
        XCTAssertFalse(s.syncState.emailNeedsReconnect)
    }

    // MARK: accounts

    func testApplyingAccountsKeepsOnlyUAHAndFormatsTheSuffix() {
        let s = store()
        let usd = MonobankAccount(id: "a2", type: "white", currencyCode: 840,
                                  balance: 5, creditLimit: 0, maskedPan: ["000000******2222"])
        s.applyAccounts(MonobankClientInfo(clientId: "c", name: "n", accounts: [account, usd]),
                        bankId: "monobank")
        let bank = s.banks.first { $0.id == "monobank" }
        XCTAssertEqual(bank?.accounts.map(\.suffix), ["*1111"])
        XCTAssertEqual(bank?.accounts.first?.currency, "UAH")
        XCTAssertEqual(s.syncAccounts.map(\.id), ["a1"])
    }

    // MARK: the one-time demo sweep

    func testTheFirstSuccessfulCommitDeletesDemoRowsExactlyOnce() {
        let repo = MemoryRepository()
        var seed = try! SeedLoader.load()
        seed.transactions = Array(seed.transactions.prefix(5))   // externalId == nil
        let s = AppStore(repository: repo, seed: seed, keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertEqual(s.transactions.count, 5)

        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions.map(\.externalId), ["r1"], "demo rows are gone")
        XCTAssertTrue(s.syncState.seedCleared)

        // A row inserted by hand afterwards must NOT be swept: the sweep runs once.
        s.transactions.append(seed.transactions[0])
        s.ingest([row("r2")], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions.count, 3)
    }

    // MARK: what the sweep may and may not delete (board #53)

    /// A receipt whose goods have landed and which matches no purchase is a
    /// `.noPurchase` card in Розібрати — an ordinary, designed state (D5),
    /// on screen asking to be attached by hand. It has left `receiptQueue`
    /// (the fetch is done) and no row references it.
    ///
    /// The sweep used to delete "every receipt no surviving row references and
    /// nothing has queued", which reads as a definition of orphan and is not
    /// one: it deleted precisely the receipt the user was being asked about.
    func testTheSweepKeepsAScannedReceiptThatHasNotFoundItsPurchase() {
        var seed = try! SeedLoader.load()
        seed.transactions = Array(seed.transactions.prefix(3))   // externalId == nil
        seed.receipts = []                                        // nothing seeded
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        let scanned = loose(UUID())
        s.receipts = [scanned]
        XCTAssertTrue(s.receiptQueue.isEmpty, "precondition: the fetch is done, so it is not queued")

        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)

        XCTAssertEqual(s.receipts.map(\.id), [scanned.id],
                       "a receipt a human scanned is not the seed's to delete")
    }

    /// The other side of the same rule: the seed's own receipts go with the
    /// seed's own rows, which is what the sweep is for.
    func testTheSweepStillDropsTheSeedsOwnReceipts() {
        var seed = try! SeedLoader.load()
        seed.transactions = Array(seed.transactions.prefix(3))
        let seededReceipt = loose(UUID())
        seed.receipts = [seededReceipt]
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertEqual(s.receipts.map(\.id), [seededReceipt.id], "precondition")

        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)

        XCTAssertTrue(s.receipts.isEmpty, "the demo's receipts leave with the demo's rows")
    }

    /// Provenance, not attachment. A receipt the user scanned onto a DEMO row
    /// loses its row to the sweep — and must still keep the receipt, which
    /// then becomes the `.noPurchase` card D5 describes. Attachment cannot be
    /// the test, because this receipt is referenced by nothing afterwards.
    func testAScannedReceiptSurvivesEvenWhenTheRowItWasOnIsSwept() {
        var seed = try! SeedLoader.load()
        seed.transactions = Array(seed.transactions.prefix(3))
        seed.receipts = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        let scanned = loose(UUID())
        s.receipts = [scanned]
        s.transactions[0].receiptId = scanned.id

        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)

        XCTAssertTrue(s.transactions.allSatisfy { $0.externalId != nil }, "the demo rows went")
        XCTAssertEqual(s.receipts.map(\.id), [scanned.id],
                       "the scan outlives the row it was attached to")
    }

    /// A receipt with its goods already landed — what `receiptCards` turns
    /// into a `.noPurchase` card once nothing references it.
    private func loose(_ id: UUID) -> Receipt {
        Receipt(id: id, scannedAt: now, registerNumber: "3000000001", documentNumber: "7",
                fiscalTime: now, fiscalSum: 12_300, sellerName: "Продавець-Приклад",
                items: [], registerModel: nil, itemsLandedAt: now)
    }

    func testAnEmptyFirstWindowStillSweepsBecauseTheCommitSucceeded() {
        var seed = try! SeedLoader.load()
        seed.transactions = Array(seed.transactions.prefix(3))
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        s.ingest([], step: forward(now - 31 * day, now), wasEmpty: true)
        XCTAssertTrue(s.transactions.isEmpty)
        XCTAssertTrue(s.syncState.seedCleared)
    }

    /// `testTheFirstSuccessfulCommitDeletesDemoRowsExactlyOnce` starts with five
    /// demo rows already present, so its first `ingest` never takes the "no
    /// demo rows to sweep" path — it can't tell a correct sweep from one that
    /// re-arms itself apart. This starts from zero rows, so the first `ingest`
    /// DOES take that path, and only a sweep that disarms on it protects a row
    /// added by hand afterwards.
    func testTheSweepDisarmsEvenWhenThereWasNothingToSweep() {
        let s = store()                                        // zero transactions
        s.ingest([], step: forward(now - 31 * day, now), wasEmpty: true)
        XCTAssertTrue(s.syncState.seedCleared,
                      "the sweep must arm on the first commit even with nothing to sweep")

        // A row added by hand afterwards looks exactly like a demo row: no externalId.
        let seed = try! SeedLoader.load()
        s.transactions.append(seed.transactions[0])
        let handAddedId = s.transactions[0].id

        s.ingest([row("r1")], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertTrue(s.transactions.contains { $0.id == handAddedId },
                      "a disarmed sweep must not eat a row the user added later")
    }

    // MARK: applying a learned rule to a new row

    /// The owner's design is "ask once per shop and remember". Without this a
    /// newly synced row ignores the rule and the queue asks again after every
    /// single sync.
    func testANewRowInheritsACategoryRuleTheUserAlreadyTaught() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: "Продукти", ambiguous: false, kind: nil)]
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].category, "Продукти")
        XCTAssertEqual(s.transactions[0].resolution, .rule,
                       "the rule decided this, not the person")
    }

    func testANewRowInheritsATransferRule() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: nil, ambiguous: false, kind: .transfer)]
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].kind, .transfer)
        XCTAssertEqual(s.transactions[0].category, "")
        XCTAssertEqual(s.transactions[0].resolution, .rule)
    }

    /// Ambiguous means the user said this merchant lands in different
    /// categories at different times. Asking is the point.
    func testAnAmbiguousRuleStillAsks() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: nil, ambiguous: true, kind: nil)]
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].resolution, .pending)
        XCTAssertEqual(s.transactions[0].category, "")
    }

    /// The merge rule outranks the rule table: a re-fetch must not re-decide a
    /// row the user already settled by hand.
    func testARefetchNeverReappliesARuleOverAHumanDecision() {
        let s = store()
        s.ingest([row("r1")], step: forward(now - 31 * day, now), wasEmpty: false)
        _ = s.confirm(s.transactions[0].id, as: "Кафе")
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: "Продукти", ambiguous: false, kind: nil)]
        s.ingest([row("r1")], step: forward(now - 3 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].category, "Кафе",
                       "an existing row is never re-decided")
    }

    // MARK: rule scope — review finding, kind-blind rule application

    /// A category rule is learned from one kind at a time — `MerchantGroup`
    /// splits income and expense into independent decisions, so a category
    /// taught by confirming an expense must not silently decide a same-
    /// merchant income row. Without `scope`, this row would arrive already
    /// `.rule`-resolved with a spending category on a salary.
    func testACategoryRuleLearnedFromAnExpenseDoesNotDecideANewIncomeRow() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: "Продукти", ambiguous: false, kind: nil, scope: .expense)]
        s.ingest([row("r1", amount: 50_000)], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].kind, .income)
        XCTAssertEqual(s.transactions[0].resolution, .pending,
                       "a rule learned from an expense must not decide an income row")
        XCTAssertEqual(s.transactions[0].category, BudgetMath.defaultIncomeCategory,
                       "left at the mapper's own income default, untouched by the rule")
    }

    /// The other side of the same boundary: a rule DOES apply to a future
    /// row of the kind it was actually learned from.
    func testACategoryRuleLearnedFromAnIncomeRowDoesDecideANewIncomeRow() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: "Зарплата", ambiguous: false, kind: nil, scope: .income)]
        s.ingest([row("r1", amount: 50_000)], step: forward(now - 31 * day, now), wasEmpty: false)
        XCTAssertEqual(s.transactions[0].category, "Зарплата")
        XCTAssertEqual(s.transactions[0].resolution, .rule)
    }

    /// A transfer rule is `scope: nil` — a merchant that moves money between
    /// the owner's own accounts is doing that whichever direction the sign
    /// points, so it must type a future row of EITHER kind.
    func testATransferRuleAppliesToBothKinds() {
        let s = store()
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Продавець"),
                        category: nil, ambiguous: false, kind: .transfer, scope: nil)]
        s.ingest([row("r1", amount: -34_000), row("r2", amount: 50_000)],
                step: forward(now - 31 * day, now), wasEmpty: false)
        for tx in s.transactions {
            XCTAssertEqual(tx.kind, .transfer,
                           "a scope-nil rule must apply regardless of the incoming row's kind")
            XCTAssertEqual(tx.resolution, .rule)
        }
    }

    // MARK: foreground activation and the background wake's one card

    private let account2 = MonobankAccount(id: "a2", type: "black", currencyCode: 980,
                                           balance: 0, creditLimit: 0,
                                           maskedPan: ["000000******2222"])

    /// A store already connected to monobank, with real accounts applied —
    /// `FakeMonobankAPI` (from `SyncEngineTests`) stands in for the bank so
    /// `startSync` has something to actually call.
    private func connectedStore(api: MonobankAPI, accounts: [MonobankAccount]) -> AppStore {
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"),
                         api: api)
        s.connect(bankId: "monobank", token: "t")
        s.applyAccounts(MonobankClientInfo(clientId: "c", name: "n", accounts: accounts),
                        bankId: "monobank")
        return s
    }

    /// The bug the review caught: a session whose first-ever sync never
    /// committed a window (offline, bank down, cancelled) has `lastSuccess ==
    /// nil` forever, since only a commit sets it. `startSyncIfConnected` must
    /// still be reachable in that state, or the app is stranded until iOS
    /// next grants a background wake — hours or days away, and never at all
    /// with Background App Refresh off.
    func testForegroundActivationStartsASyncEvenWhenNothingHasEverSucceeded() async {
        let api = FakeMonobankAPI()
        await api.setFallback([])
        let s = connectedStore(api: api, accounts: [account])
        XCTAssertNil(s.syncState.lastSuccess, "a session that has never synced must still be eligible")
        _ = await s.startSyncIfConnected(maxSteps: 1)
        let calls = await api.recorded()
        XCTAssertFalse(calls.isEmpty,
                       "a connected bank with no prior success must still be asked")
    }

    /// The condition that must still gate it: an unconnected bank is never
    /// asked, `lastSuccess` or not.
    func testForegroundActivationAsksNothingWithoutAConnectedBank() async {
        let api = FakeMonobankAPI()
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"),
                         api: api)
        let outcome = await s.startSyncIfConnected(maxSteps: 1)
        XCTAssertNil(outcome, "no monobank connection at all must not start a sync")
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }

    /// `syncOnlyAccount` is the background wake's "one wake, one card" leash
    /// — see `BackgroundRefresh.register`, which sets it to
    /// `busiestAccount(...)` before calling `startSync(maxSteps: 1)`.
    func testSyncOnlyAccountRestrictsTheEngineToOneCard() async {
        let api = FakeMonobankAPI()
        await api.setFallback([])
        let s = connectedStore(api: api, accounts: [account, account2])
        s.syncOnlyAccount = "a2"
        _ = await s.startSync(maxSteps: 1)
        let asked = Set((await api.recorded()).map(\.accountId))
        XCTAssertEqual(asked, ["a2"], "only the account named by syncOnlyAccount may be asked")
    }

    /// The normal, foreground case: nothing narrows the choice.
    func testWithNoSyncOnlyAccountEveryUAHAccountIsEligible() {
        let s = connectedStore(api: FakeMonobankAPI(), accounts: [account, account2])
        XCTAssertNil(s.syncOnlyAccount)
        XCTAssertEqual(Set(s.syncEligibleAccounts.map(\.id)), Set(["a1", "a2"]))
    }

    // MARK: the fourth state — a run that stopped and said nothing

    /// The bug: `SyncEngine` returns `.stopped(.offline)`, `isSyncing` goes
    /// false, `needsReconnect` stays false, and `SyncStatusView` renders
    /// NOTHING. A first launch with no connectivity showed «Тут з'являться
    /// ваші покупки…» with no spinner, no error and no explanation, forever.
    func testARunThatFailedLeavesAnExplanationBehind() async {
        let api = FakeMonobankAPI()
        await api.script([.failure(.offline("boom"))])
        let s = connectedStore(api: api, accounts: [account])
        let outcome = await s.startSync(maxSteps: 1)
        XCTAssertEqual(outcome, .stopped(.offline))
        XCTAssertEqual(s.syncState.lastStop, SyncEngine.Stop.offline.rawValue)
        XCTAssertNotNil(SyncEngine.Stop(rawValue: s.syncState.lastStop ?? "")?.userMessage,
                        "a stop that is stored must be one the user can be told about")
    }

    /// …and it must not outlive the next run that worked. A stale «Немає
    /// зв'язку» over a screenful of fresh purchases is worse than silence.
    func testARunThatWorkedClearsAStaleExplanation() async {
        let api = FakeMonobankAPI()
        await api.setFallback([])
        let s = connectedStore(api: api, accounts: [account])
        s.syncState.lastStop = SyncEngine.Stop.offline.rawValue
        _ = await s.startSync(maxSteps: 1)
        XCTAssertNil(s.syncState.lastStop)
    }

    /// `.budget` is how EVERY bounded run ends: pull-to-refresh and every
    /// background wake ask for exactly one window. Reporting it would put an
    /// error line on screen after a refresh that worked perfectly.
    func testAskingForOneWindowIsNotAFailure() async {
        let api = FakeMonobankAPI()
        await api.setFallback([])
        let s = connectedStore(api: api, accounts: [account, account2])
        let outcome = await s.startSync(maxSteps: 1)
        XCTAssertEqual(outcome, .stopped(.budget))
        XCTAssertNil(s.syncState.lastStop)
    }

    /// «Усе, що є» has no planned total — it stops on empty windows, not on a
    /// date — so `totalWindows` degenerates to the account count and the line
    /// pinned at «2 з 2» while the backfill carried on. No count is honest;
    /// a wrong one is not.
    func testTheProgressCountIsWithheldForEverythingThereIs() {
        let s = connectedStore(api: FakeMonobankAPI(), accounts: [account, account2])
        s.isSyncing = true
        s.syncState.depthMonths = 3
        XCTAssertEqual(s.syncProgress?.total, 6, "a bounded depth still counts its windows")
        s.syncState.depthMonths = 0
        XCTAssertNil(s.syncProgress, "«Усе, що є» must not claim a total it does not have")
    }

    // MARK: wiping the dataset a run was started against

    /// A store parked mid-request, with one live row waiting to come back.
    private func gatedRun(_ api: GatedAPI) async -> (AppStore, Task<SyncEngine.Outcome, Never>) {
        await api.setRows([MonobankStatementItem(
            id: "live-1", time: Int(now.timeIntervalSince1970), description: "Продавець",
            mcc: 5411, amount: -34_000, operationAmount: nil, currencyCode: 980,
            commissionRate: 0, cashbackAmount: 0, balance: nil, hold: false,
            monoReceiptId: nil, counterName: nil)])
        let s = connectedStore(api: api, accounts: [account])
        let run = Task { await s.startSync(maxSteps: 1) }
        await api.waitForRequest()
        return (s, run)
    }

    /// A first-connect backfill runs for minutes, and «Видалити все» is one
    /// tap away the whole time.
    ///
    /// `resetEverything` wiped the repository, the Keychain and every
    /// collection but left the engine running — and `SyncEngine.run` reads the
    /// token ONCE into a local before its loop, so an emptied Keychain does
    /// not stop it. Its next window then committed straight back into the
    /// freshly reset store: `seedCleared` flipped, live rows were appended,
    /// cursors were written, and `persistNow()` recreated the directory that
    /// had just been deleted. The user was left sitting in onboarding on top
    /// of a half-synced live dataset with a stale `clientHash`.
    func testAResetMidRunDropsTheWindowThatWasAlreadyInFlight() async {
        let api = GatedAPI()
        let (s, run) = await gatedRun(api)

        s.resetEverything()          // «Видалити все», with the bank call in flight
        await api.answer()           // and the window nobody wants comes back
        _ = await run.value

        XCTAssertFalse(s.transactions.contains { $0.externalId == "live-1" },
                       "a window fetched for a dataset that no longer exists must not be written back")
        XCTAssertTrue(s.syncState.cursors.isEmpty, "no cursor may survive the wipe")
        XCTAssertNil(s.syncState.lastSuccess)
        XCTAssertFalse(s.syncState.seedCleared, "the reset restored the seed; the sweep must not re-run")
        XCTAssertFalse(s.settings.onboarded, "the app must stay in the fresh-install state")
        XCTAssertNil(s.syncEngine, "the engine belonged to the dataset that was just deleted")
        XCTAssertFalse(s.isSyncing, "a reset app must not sit under a spinner it can never clear")
    }

    /// The same exposure with a second person's token. `wipeForNewClient` runs
    /// only after the user agrees to start over, and the run started against
    /// the FIRST person's dataset is still in flight — so its window would
    /// land in the second person's. Two people's money must never end up in
    /// one dataset.
    func testAdoptingANewClientMidRunDropsTheWindowThatWasAlreadyInFlight() async {
        let api = GatedAPI()
        let (s, run) = await gatedRun(api)

        s.wipeForNewClient(MonobankClientInfo(clientId: "someone-else", name: "n", accounts: []))
        await api.answer()
        _ = await run.value

        XCTAssertTrue(s.transactions.isEmpty,
                      "the previous person's run must not deposit rows in the new person's dataset")
        XCTAssertTrue(s.syncState.cursors.isEmpty)
        XCTAssertNil(s.syncState.lastSuccess)
        XCTAssertEqual(s.syncState.clientHash, AppStore.clientHash("someone-else"))
    }

    // MARK: ingestRows

    func testIngestRowsCountsImportedAndMerged() {
        let s = store()
        let first = s.ingestRows([row("a"), row("b")])
        XCTAssertEqual(first.imported, 2)
        XCTAssertEqual(first.merged, 0)
        let again = s.ingestRows([row("a"), row("b")])
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.merged, 2)
        XCTAssertEqual(s.transactions.count, 2)
    }

    func testIngestRowsLeavesUserFieldsAlone() {
        let s = store()
        let original = row("a")
        s.ingestRows([original])
        s.confirm(original.id, as: "Тварини")
        var refetched = original
        refetched.merchant = "Оновлена назва"
        s.ingestRows([refetched])
        let stored = s.transactions.first { $0.id == original.id }!
        XCTAssertEqual(stored.merchant, "Оновлена назва", "the bank owns merchant")
        XCTAssertEqual(stored.category, "Тварини", "the user owns category")
        XCTAssertEqual(stored.resolution, .user)
    }
}

/// A bank whose statement call parks until the test lets it answer, so a wipe
/// can land in the middle of a window that is already in flight. Nothing about
/// the real `MonobankClient` makes this observable otherwise: the request is
/// the only place a run spends real time, and a stub that answers immediately
/// has already committed before the test regains control.
private actor GatedAPI: MonobankAPI {
    private var waiting: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var didCall = false
    private var rows: [MonobankStatementItem] = []

    func setRows(_ rows: [MonobankStatementItem]) { self.rows = rows }

    func clientInfo(token: String) async throws -> MonobankClientInfo {
        MonobankClientInfo(clientId: "c", name: "n", accounts: [])
    }

    func statement(token: String, accountId: String,
                   from: Date, to: Date) async throws -> [MonobankStatementItem] {
        didCall = true
        arrival?.resume()
        arrival = nil
        // `waiting` is assigned before the suspension, and this actor is not
        // re-entered until then, so an `answer()` racing this cannot be lost.
        await withCheckedContinuation { waiting = $0 }
        return rows
    }

    /// Returns once the engine is parked inside `statement`.
    func waitForRequest() async {
        guard !didCall else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func answer() { waiting?.resume(); waiting = nil }
}
