import SwiftUI      // LocalizedStringKey, for board #175's outcome labels
import XCTest
@testable import MonitorFinance

@MainActor
final class PrivatEmailStoreTests: XCTestCase {
    private final class FakeEmailAPI: PrivatEmailAPI {
        var registration = PrivatEmailRegistration(userId: "u9", secret: "s9",
                                                   email: "u-t@in.example.test")
        var registerError: PrivatEmailError?
        var registerCalls = 0
        func register() async throws -> PrivatEmailRegistration {
            registerCalls += 1
            if let registerError { throw registerError }
            return registration
        }
        var pages: [PrivatEmailPage] = []
        var transactionsError: PrivatEmailError?
        var transactionCalls = 0
        func transactions(credentials: PrivatEmailCredentials,
                          since: Int, limit: Int) async throws -> PrivatEmailPage {
            transactionCalls += 1
            if let transactionsError { throw transactionsError }
            return pages.isEmpty ? .init(transactions: [], nextCursor: since)
                                  : pages.removeFirst()
        }
        var pendingResult = PrivatEmailPending(confirmations: [], parseFailures: 0)
        var pendingError: PrivatEmailError?
        func pendingLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailPending {
            if let pendingError { throw pendingError }
            return pendingResult
        }
        var statusResult = PrivatEmailStatus(email: "u-t@in.example.test",
                                             lastLetterAt: nil, transactionsTotal: 0)
        var statusError: PrivatEmailError?
        var statusCalls = 0
        func status(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatus {
            statusCalls += 1
            if let statusError { throw statusError }
            return statusResult
        }
        var deleteError: PrivatEmailError?
        var deleteCalls = 0
        func deleteAccount(credentials: PrivatEmailCredentials) async throws {
            deleteCalls += 1
            if let deleteError { throw deleteError }
        }

        // Board #97 — emailed statements.
        var waiting: [PrivatEmailStatement] = []
        var statementsError: PrivatEmailError?
        func statements(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatements {
            if let statementsError { throw statementsError }
            return .init(statements: waiting)
        }
        /// Defaults to the SAME invented xlsx the file-picker stub feeds, so a
        /// test that follows a statement through `importPrivatStatement`
        /// exercises the real parser rather than a stand-in for it.
        var bytes: Data = PrivatStatementStub.sampleData
        var bytesError: PrivatEmailError?
        var bytesCalls = 0
        func statementBytes(credentials: PrivatEmailCredentials, id: Int) async throws -> Data {
            bytesCalls += 1
            if let bytesError { throw bytesError }
            return bytes
        }
        var consumed: [Int] = []
        var consumeError: PrivatEmailError?
        func consumeStatement(credentials: PrivatEmailCredentials, id: Int) async throws {
            if let consumeError { throw consumeError }
            consumed.append(id)
        }

        // Board #145 — a statement that arrived as a link. No `linkBytes`,
        // because nothing on this side ever fetches what a link points at.
        var waitingLinks: [PrivatEmailStatementLink] = []
        var linksError: PrivatEmailError?
        func statementLinks(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatementLinks {
            if let linksError { throw linksError }
            return .init(links: waitingLinks)
        }
        var consumedLinks: [Int] = []
        var consumeLinkError: PrivatEmailError?
        func consumeStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws {
            if let consumeLinkError { throw consumeLinkError }
            consumedLinks.append(id)
        }

        // Board #171 — the server follows a link it already holds. `linkBytes`
        // is still absent: nothing on THIS side ever fetches a URL, and the
        // one thing that does lives in `app/statement_fetch.py`.
        var downloadedLinks: [Int] = []
        var downloadLinkError: PrivatEmailError?
        var downloaded = PrivatEmailStatement(id: 91, filename: "vypyska-vygadana.xlsx",
                                              sizeBytes: 512,
                                              receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
        func downloadStatementLink(credentials: PrivatEmailCredentials,
                                   id: Int) async throws -> PrivatEmailStatement {
            downloadedLinks.append(id)
            if let downloadLinkError { throw downloadLinkError }
            return downloaded
        }

        // Board #175 — the last few letters, as metadata. Invented values, and
        // no `body` field to invent one for: the shape has none.
        var recent: [PrivatEmailRecentLetter] = []
        var recentError: PrivatEmailError?
        func recentLetters(credentials: PrivatEmailCredentials) async throws
            -> PrivatEmailRecentLetters {
            if let recentError { throw recentError }
            return .init(letters: recent)
        }

        // Board #186. Recorded rather than stubbed out: `queuedReceipts` is
        // what `ReceiptServerTests` asserts a scan actually posted.
        var queuedReceipts: [FiscalCheck] = []
        var readyReceiptRows: [PrivatEmailReceipt] = []
        var consumedReceipts: [Int] = []

        func queueReceipt(credentials: PrivatEmailCredentials, check: FiscalCheck) async throws {
            queuedReceipts.append(check)
        }

        func readyReceipts(credentials: PrivatEmailCredentials) async throws
            -> [PrivatEmailReceipt] {
            readyReceiptRows
        }

        func consumeReceipt(credentials: PrivatEmailCredentials, id: Int) async throws {
            consumedReceipts.append(id)
        }
    }

    /// Same shape `ConnectTests` builds a monobank store with — a real
    /// `Keychain` under a per-test service, so nothing here can bleed into
    /// another test or a real device's Keychain.
    private func makeStore(_ repo: MemoryRepository = MemoryRepository())
        -> (AppStore, FakeEmailAPI) {
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        let api = FakeEmailAPI()
        let store = AppStore(repository: repo, seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"),
                             emailAPI: api)
        return (store, api)
    }

    func testRegistrationLandsInTheKeychain() async {
        let (store, api) = makeStore()          // helper: injected FakeEmailAPI
        let outcome = await store.registerPrivatEmail()
        XCTAssertEqual(outcome, .registered("u-t@in.example.test"))
        XCTAssertEqual(store.privatEmailCredentials,
                       PrivatEmailCredentials(userId: "u9", secret: "s9"))
        XCTAssertEqual(store.privatEmailAddress, "u-t@in.example.test")
        _ = api
    }

    func testASecondRegisterDoesNotBurnTheAccount() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        let outcome = await store.registerPrivatEmail()
        XCTAssertEqual(outcome, .alreadyRegistered("u-t@in.example.test"))
    }

    func testA429SurfacesAndStoresNothing() async {
        let (store, api) = makeStore()
        api.registerError = .rateLimited
        let outcome = await store.registerPrivatEmail()
        XCTAssertEqual(outcome, .failed(.rateLimited))
        XCTAssertNil(store.privatEmailCredentials)
    }

    /// A `forgetPrivatEmail()` + re-register lands against a NEW server
    /// account whose row ids restart at 1 — a left-alone cursor would tell
    /// that account "everything up to N is already imported" and its own
    /// letters would never arrive. Fix-round-3 finding 1.
    func testReRegisteringResetsTheEmailCursor() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: PrivatEmailStub.rows, nextCursor: 5)]
        _ = await store.syncPrivatEmail()
        XCTAssertEqual(store.syncState.emailCursor, 5)

        store.forgetPrivatEmail()
        api.registration = PrivatEmailRegistration(userId: "u10", secret: "s10",
                                                   email: "u-t2@in.example.test")
        let outcome = await store.registerPrivatEmail()
        XCTAssertEqual(outcome, .registered("u-t2@in.example.test"))
        XCTAssertEqual(store.syncState.emailCursor, 0)
    }

    // MARK: - Board #111 — the anchor that outlives the secret

    /// **The flag has to live where the secret does not.**
    ///
    /// It is written to `sync.json`, not the Keychain, precisely so it survives
    /// the case it exists for: a restore onto a new phone brings the data back
    /// without the secret, because the secret is stored `…ThisDeviceOnly` and
    /// is deliberately left out of backups.
    ///
    /// Asserted through the repository rather than through `store.syncState`,
    /// because "in memory" is not the property that matters here.
    func testAnIssuedAddressIsRememberedOutsideTheKeychain() async {
        let repo = MemoryRepository()
        let (store, _) = makeStore(repo)
        XCTAssertFalse(store.syncState.emailAddressIssued, "nothing issued yet")
        _ = await store.registerPrivatEmail()
        let written = try? repo.load("sync", as: SyncState.self)
        XCTAssertEqual(written?.emailAddressIssued, true,
                       "the flag must be on disk, where a restore can bring it back")
    }

    /// A disconnect is the one way an address stops existing **on purpose**, so
    /// after it there is no old forwarding rule left to warn anybody about —
    /// and the next offer is an ordinary first one, not a replacement.
    ///
    /// This is also the owner's own report: «it changes every time I delete the
    /// mail». That path is correct, and the reissue warning must not appear on
    /// it, or the fix for the silent case would turn the correct case into a
    /// scary one.
    func testChangingTheAddressClearsTheFlagSoTheNextOfferIsAnOrdinaryOne() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        XCTAssertTrue(store.syncState.emailAddressIssued)
        _ = await store.changePrivatEmailAddress()
        XCTAssertFalse(store.syncState.emailAddressIssued,
                       "a deliberate address change leaves no old address to warn about")
        XCTAssertEqual(PrivatEmailSetupView.arrival(
            hasCredentials: store.privatEmailCredentials != nil,
            address: store.privatEmailAddress ?? "",
            hadIssuedAddress: store.syncState.emailAddressIssued), .offer)
    }

    /// **The migration, and the one person it is for.**
    ///
    /// Every install that already holds an address predates this field, so its
    /// `sync.json` has no key for it — and the person this guard protects is
    /// exactly somebody restoring such an install onto a new phone. Defaulting
    /// to `false` would leave them in the silent case the card is about.
    ///
    /// A consumed cursor means letters arrived, which means an address was
    /// issued.
    func testAnOlderSyncFileWithAConsumedCursorCountsAsIssued() throws {
        let older = Data(#"{"emailCursor": 7}"#.utf8)
        let decoded = try JSONDecoder().decode(SyncState.self, from: older)
        XCTAssertTrue(decoded.emailAddressIssued,
                      "letters arrived, so an address was issued — even with no key for it")

        let untouched = try JSONDecoder().decode(SyncState.self, from: Data("{}".utf8))
        XCTAssertFalse(untouched.emailAddressIssued,
                       "…but a file that never synced a letter must not claim one")
    }

    // MARK: - Board #97, a statement emailed to the issued address

    /// **The bytes go through the file picker's own entry point.**
    ///
    /// That is the card's decision made structural rather than promised:
    /// `PrivatStatementParser` stays the only parser in the system, so a
    /// statement that arrives by mail is parsed by the same code, against the
    /// same fixtures, as one picked from Files.
    func testAnEmailedStatementBecomesTransactions() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.waiting = [.init(id: 7, filename: "vypyska.xlsx", sizeBytes: 3138,
                             receivedAt: Date(timeIntervalSince1970: 1_787_890_000))]

        let waiting = try await store.privatEmailStatements()
        XCTAssertEqual(waiting.count, 1)
        let summary = try await store.importEmailedStatement(waiting[0])
        XCTAssertGreaterThan(summary.imported, 0, "the emailed statement must land as history")
        XCTAssertEqual(api.consumed, [7], "…and stop being offered once it has")
    }

    /// **The card's third box, asserted rather than assumed.**
    ///
    /// The same purchase arrives twice: once as a notification letter, once in
    /// the emailed statement. The two sources cannot produce the same
    /// `externalId`, so nothing but `PrivatCrossSource` stands between the
    /// person and a doubled history — and the whole point of routing these
    /// bytes through `importPrivatStatement` is that it already does.
    ///
    /// Built from the STUB statement's own rows so the two sides genuinely
    /// describe one purchase: the amount/balance pair is what the matcher
    /// keys on, and inventing a pair by hand would prove only that unrelated
    /// rows stay unrelated.
    func testAPurchaseDeliveredByLetterIsNotDoubledByTheEmailedStatement() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()

        // First the statement, so its rows are the known truth.
        api.waiting = [.init(id: 1, filename: "vypyska.xlsx", sizeBytes: 3138,
                             receivedAt: Date(timeIntervalSince1970: 1_787_890_000))]
        let first = try await store.privatEmailStatements()
        let fromStatement = try await store.importEmailedStatement(first[0])
        XCTAssertGreaterThan(fromStatement.imported, 0)
        let afterStatement = store.transactions.count

        // Now the SAME file again — the case a second forward would cause.
        // `applyStatement`'s own identity dedup must absorb it whole.
        api.waiting = [.init(id: 2, filename: "vypyska.xlsx", sizeBytes: 3138,
                             receivedAt: Date(timeIntervalSince1970: 1_787_895_000))]
        let second = try await store.privatEmailStatements()
        let again = try await store.importEmailedStatement(second[0])
        XCTAssertEqual(again.imported, 0, "the same statement twice must add nothing")
        XCTAssertEqual(store.transactions.count, afterStatement,
                       "a re-forwarded statement must not double a person's history")
    }

    /// **Consumed only after the import succeeded**, so a person whose import
    /// failed still has the file on the server to try again with.
    func testAFailedImportLeavesTheStatementOnTheServer() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.waiting = [.init(id: 3, filename: "vypyska.xlsx", sizeBytes: 10,
                             receivedAt: Date())]
        api.bytes = Data("not an xlsx at all".utf8)

        let waiting = try await store.privatEmailStatements()
        do {
            _ = try await store.importEmailedStatement(waiting[0])
            XCTFail("bytes that are not a spreadsheet must not import")
        } catch {
            // expected
        }
        XCTAssertEqual(api.consumed, [],
                       "a statement whose import failed must still be there to retry")
    }

    /// A dead secret must be reported as one here too, or the screen would
    /// offer «спробуйте ще раз» against an account that no longer exists.
    func testAnUnauthorizedStatementCallFlagsTheReconnect() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.statementsError = .unauthorized
        _ = try? await store.privatEmailStatements()
        XCTAssertTrue(store.syncState.emailNeedsReconnect)
    }

    func testForgetClearsTheKeychain() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.forgetPrivatEmail()
        XCTAssertNil(store.privatEmailCredentials)
        XCTAssertNil(store.privatEmailAddress)
    }

    /// The parked must-fix from #90. The Keychain writes in
    /// `registerPrivatEmail` are immediate; `persist()` debounces 300 ms, so a
    /// kill inside that window left the NEW credentials beside the OLD cursor
    /// — and the symptom is "no letters ever arrive", silently.
    ///
    /// The seed is deliberately non-default: `emailCursor == 0` is the
    /// struct's own initial value, so asserting 0 against a file that was
    /// never written would pass for the wrong reason.
    func testRegistrationWritesTheCursorWithoutWaitingForTheDebounce() async {
        let repo = MemoryRepository()
        let (store, _) = makeStore(repo)
        store.syncState.emailCursor = 42
        store.persistNow()
        _ = await store.registerPrivatEmail()
        let written = try? repo.load("sync", as: SyncState.self)
        XCTAssertEqual(written?.emailCursor, 0,
                       "the reset must be on disk before the 300 ms debounce could fire")
    }

    /// Email is a MODE of the PrivatBank entry, so connecting it connects the
    /// bank — the same flip `applyStatement` does, and what puts the bank in
    /// Налаштування → Банки and offers onboarding its «Готово».
    func testRegisteringConnectsThePrivatBankEntry() async {
        let (store, _) = makeStore()
        XCTAssertEqual(store.banks.first { $0.id == "privatbank" }?.connected, false)
        _ = await store.registerPrivatEmail()
        XCTAssertEqual(store.banks.first { $0.id == "privatbank" }?.connected, true)
    }

    /// The guard #90 widened and nothing covered: it gates on credentials
    /// ALONE, treating a missing stored address as recoverable rather than as
    /// "never registered". Without this test, reverting it to the old
    /// credentials-AND-address `&&` stays green — and that revert burns one of
    /// the five registrations an hour this IP gets AND mints a phantom second
    /// account whose row ids restart at 1.
    func testCredentialsWithNoStoredAddressDoNotRegisterAgain() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        store.keychain.delete(AppStore.emailAddressKey)   // the partial-write state
        let before = api.registerCalls
        let outcome = await store.registerPrivatEmail()
        XCTAssertEqual(outcome, .alreadyRegistered(""))
        XCTAssertEqual(api.registerCalls, before, "a missing address must not mint a second account")
        XCTAssertEqual(store.privatEmailCredentials,
                       PrivatEmailCredentials(userId: "u9", secret: "s9"))
    }

    // MARK: changing the address — the ONE destructive path (board #158)
    //
    // These were the `disconnect` tests. The behaviour they pin did not
    // change; what changed is which button reaches it. «Відключити пошту» no
    // longer deletes anything, so every assertion here now belongs to
    // «Змінити адресу», which is the only thing that ends an address.

    func testChangingTheAddressDeletesTheServerAccountAndForgetsTheSecret() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        store.syncState.emailCursor = 42
        let outcome = await store.changePrivatEmailAddress()
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertEqual(api.deleteCalls, 1, "the issued address must stop accepting mail")
        XCTAssertNil(store.privatEmailCredentials)
        XCTAssertNil(store.privatEmailAddress)
        XCTAssertEqual(store.syncState.emailCursor, 0)
    }

    /// A failed delete must NOT forget the local half: the account would keep
    /// accepting this person's letters forever with nothing on the phone left
    /// to reach it, and re-registering would orphan it permanently.
    func testAFailedDeleteKeepsTheSecretSoTheAccountCanStillBeReached() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        store.syncState.emailCursor = 42
        api.deleteError = .offline("no route")
        let outcome = await store.changePrivatEmailAddress()
        XCTAssertEqual(outcome, .failed(.offline("no route")))
        XCTAssertNotNil(store.privatEmailCredentials)
        XCTAssertEqual(store.syncState.emailCursor, 42, "nothing local changes on a failed delete")
    }

    /// The escape hatch: the person was told the address will stay alive and
    /// chose to forget it here anyway. Without it, no signal means no way to
    /// change the address at all.
    func testForcingPastAFailedDeleteForgetsLocally() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .offline("no route")
        let outcome = await store.changePrivatEmailAddress(force: true)
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertNil(store.privatEmailCredentials)
    }

    /// 401 means the account is already gone (or its secret is dead). There is
    /// nothing left to delete, so refusing to forget the local half would
    /// strand the person on credentials that can never work again.
    func testA401OnDeleteCountsAsAlreadyGone() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .unauthorized
        let outcome = await store.changePrivatEmailAddress()
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertNil(store.privatEmailCredentials)
    }

    func testChangingTheAddressWhenNothingIsConnectedAsksTheBackendNothing() async {
        let (store, api) = makeStore()
        let outcome = await store.changePrivatEmailAddress()
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertEqual(api.deleteCalls, 0)
    }

    // MARK: what the screens read

    /// `.alreadyRegistered("")` is reachable whenever the stored pair outlived
    /// its address. `/status` is the backend's own answer to "which address did
    /// I issue you", so a successful call heals the Keychain and the screen
    /// never has to render an empty string.
    func testStatusHealsAnAddressThatWentMissing() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        store.keychain.delete(AppStore.emailAddressKey)
        api.statusResult = .init(email: "u-healed@in.example.test",
                                 lastLetterAt: nil, transactionsTotal: 3)
        let status = try await store.privatEmailStatus()
        XCTAssertEqual(status.transactionsTotal, 3)
        XCTAssertEqual(store.privatEmailAddress, "u-healed@in.example.test")
    }

    /// A 401 from any read means what a 401 from a page means: the secret is
    /// dead, sync must stop, and the flag is what puts «підключіть пошту
    /// заново» on Головна.
    func testA401FromStatusFlagsTheReconnect() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.statusError = .unauthorized
        do {
            _ = try await store.privatEmailStatus()
            XCTFail("a 401 must reach the caller, not be swallowed")
        } catch {
            XCTAssertEqual(error as? PrivatEmailError, .unauthorized)
        }
        XCTAssertTrue(store.syncState.emailNeedsReconnect)
    }

    /// The other direction: an ordinary success must not touch the flag. A
    /// post-condition of `false` against a field that starts `false` would pass
    /// vacuously, so it is seeded true first.
    func testASuccessfulReadLeavesTheReconnectFlagAlone() async throws {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.syncState.emailNeedsReconnect = true
        _ = try await store.privatEmailPending()
        XCTAssertTrue(store.syncState.emailNeedsReconnect,
                      "a read must neither raise nor clear the flag — only registering clears it")
    }

    func testAskingForStatusWithNoCredentialsNeverReachesTheBackend() async {
        let (store, api) = makeStore()
        do {
            _ = try await store.privatEmailStatus()
            XCTFail("no credentials must not produce a status")
        } catch {
            XCTAssertEqual(error as? PrivatEmailError, .unauthorized)
        }
        XCTAssertEqual(api.statusCalls, 0)
    }

    /// The two counters both screens read. Derived from the externalId prefix
    /// rather than stored, so a wipe cannot leave a counter disagreeing with
    /// the rows it counts.
    ///
    /// **The store is seeded with a NON-letter row first, dated after every
    /// letter.** Without it both assertions pass for a counter that ignores
    /// the prefix entirely and simply counts everything — measured: that
    /// mutation survived the first version of this test, because a store
    /// holding nothing but letters cannot tell the two apart.
    func testTheDerivedCountersSeeOnlyLetterRows() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        store.transactions.append(Transaction(
            id: UUID(), date: Date(timeIntervalSince1970: 1_788_000_000), kind: .expense,
            category: "Інше", merchant: "Не з листа", amount: -1_000, cardSuffix: "*2299",
            bankId: "privatbank", receiptId: nil, splits: [], resolution: .user,
            suggestions: [], externalId: PrivatMapper.externalIdPrefix + "not-a-letter"))
        api.pages = [.init(transactions: PrivatEmailStub.rows, nextCursor: 5)]
        _ = await store.syncPrivatEmail()
        // Four of the stub's five rows are UAH; the USD one is skipped. The
        // statement row above must not be counted, and must not win the date.
        XCTAssertEqual(store.privatEmailRowCount, 4)
        XCTAssertEqual(store.privatEmailNewestDate, PrivatEmailStub.rows[3].occurredAt,
                       "the newest letter this phone holds — not the newest row of any kind")
    }

    // MARK: sync loop

    func testAPageBecomesPendingRowsAndTheCursorAdvances() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: PrivatEmailStub.rows, nextCursor: 5)]
        let result = await store.syncPrivatEmail()
        // 5 stub rows: 4 UAH in, 1 USD skipped.
        XCTAssertEqual(result?.imported, 4)
        XCTAssertEqual(store.syncState.emailCursor, 5)
        XCTAssertTrue(store.transactions.contains {
            $0.externalId == "privat-email|u9|1" && $0.resolution == .pending })
    }

    func testARedeliveredPageMergesInsteadOfDuplicating() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: PrivatEmailStub.rows, nextCursor: 5)]
        _ = await store.syncPrivatEmail()
        let count = store.transactions.count
        // Redelivered with row 1's bank-owned amount changed. Asserting only
        // "imported == 0, count unchanged" is equally true of a loop that
        // never called `ingestRows` on the second page at all — the amount
        // check on the STORED row is what proves the merge path actually ran.
        var redelivered = PrivatEmailStub.rows
        redelivered[0].amountMinor = -99_900
        api.pages = [.init(transactions: redelivered, nextCursor: 5)]
        let second = await store.syncPrivatEmail()
        XCTAssertEqual(second?.imported, 0)
        XCTAssertEqual(second?.merged, 4)
        XCTAssertEqual(store.transactions.count, count)
        XCTAssertEqual(store.transactions.first { $0.externalId == "privat-email|u9|1" }?.amount,
                       -99_900)
    }

    /// One backend row, parameterised by id, for the paging tests below — a
    /// full page needs `AppStore.emailPageLimit` distinct rows and the 5-row
    /// `PrivatEmailStub.rows` fixture is nowhere near big enough.
    private func emailRow(_ id: Int) -> PrivatEmailTransaction {
        .init(id: id, occurredAt: Date(timeIntervalSince1970: 1_787_900_000 + Double(id)),
              amountMinor: -100, currency: "UAH", cardSuffix: "5*99",
              merchantRaw: "Email Fixture Merchant", balanceAfterMinor: nil)
    }

    func testATwoPageBackfillConsumesBothPages() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let limit = AppStore.emailPageLimit
        let firstPage = (1...limit).map(emailRow)
        let secondPage = [emailRow(limit + 1), emailRow(limit + 2)]
        api.pages = [.init(transactions: firstPage, nextCursor: limit),
                     .init(transactions: secondPage, nextCursor: limit + 2)]
        let result = await store.syncPrivatEmail()
        XCTAssertEqual(result?.imported, limit + 2)
        XCTAssertEqual(api.transactionCalls, 2)
        XCTAssertEqual(store.syncState.emailCursor, limit + 2)
    }

    func testMaxPagesBoundsTheLoop() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let limit = AppStore.emailPageLimit
        let firstPage = (1...limit).map(emailRow)
        let secondPage = [emailRow(limit + 1)]
        api.pages = [.init(transactions: firstPage, nextCursor: limit),
                     .init(transactions: secondPage, nextCursor: limit + 1)]
        _ = await store.syncPrivatEmail(maxPages: 1)
        XCTAssertEqual(api.transactionCalls, 1)
    }

    func testANonAuthErrorLeavesTheCursorAndReconnectFlagAlone() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.transactionsError = .offline("stub offline")
        _ = await store.syncPrivatEmail()
        XCTAssertFalse(store.syncState.emailNeedsReconnect)
        XCTAssertEqual(store.syncState.emailCursor, 0)
    }

    /// The real backend orders by an integer primary key and cannot produce
    /// this in practice — but the loop trusts a network value, and a page
    /// that stays full while `nextCursor` never advances must stop instead of
    /// spinning the main actor forever. Two full-and-stalled pages queued so
    /// a broken guard would still terminate the test (via `api.pages`
    /// running out) rather than hang the run — the assertion on
    /// `transactionCalls` is what actually pins the fix.
    func testAStalledCursorStopsTheLoopInsteadOfSpinning() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let limit = AppStore.emailPageLimit
        let stalledPage = (1...limit).map(emailRow)
        api.pages = [.init(transactions: stalledPage, nextCursor: 0),
                     .init(transactions: stalledPage, nextCursor: 0)]
        let result = await store.syncPrivatEmail()
        XCTAssertEqual(result?.imported, limit)
        XCTAssertEqual(api.transactionCalls, 1)
    }

    func testA401StopsSyncUntilReconnect() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.transactionsError = .unauthorized       // add to FakeEmailAPI
        _ = await store.syncPrivatEmail()
        XCTAssertTrue(store.syncState.emailNeedsReconnect)
        // `await` cannot sit inside XCTAssertNil's (non-async) autoclosure
        // argument, so the outcome is captured first — same as `ConnectTests`.
        let retry = await store.syncPrivatEmailIfConnected()
        XCTAssertNil(retry)
    }

    func testNoCredentialsMeansNoRequest() async {
        let (store, api) = makeStore()
        let outcome = await store.syncPrivatEmailIfConnected()
        XCTAssertNil(outcome)
        XCTAssertEqual(api.transactionCalls, 0)     // add a counter to FakeEmailAPI
    }

    // MARK: cross-source dedup — one purchase, two sources, one row

    /// A statement row for the same purchase `PrivatEmailStub.rows[0]`
    /// describes: the same amount and the same balance, and deliberately
    /// nothing else in common — last-four masking, seconds, Privat's own
    /// description. Every string here is invented.
    private func statementRow(
        date: Date, amountMinor: Int = -12_550, balanceMinor: Int = 903_450,
        cardSuffix: String = "*2299",
        description: String = "Супермаркет Тест-Маркет, м. Вигадане",
        category: String = "") -> PrivatRow {
        PrivatRow(date: date, category: category, cardSuffix: cardSuffix,
                  descriptionText: description, amountMinor: amountMinor,
                  currency: "UAH", balanceMinor: balanceMinor,
                  balanceCurrency: "UAH")
    }

    private func statement(_ rows: [PrivatRow]) -> PrivatStatement {
        PrivatStatement(rows: rows, skippedNonUAH: 0, period: nil)
    }

    func testAStatementRowForAnAlreadySyncedLetterMerges() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        // A letter: -125.50, balance 9 034.50, card 5*99, minute precision.
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let before = store.transactions.count

        // The same purchase as a statement row: seconds precision, last-4
        // suffix, different description — and the SAME amount and balance.
        let row = statementRow(date: PrivatEmailStub.rows[0]
                                   .occurredAt.addingTimeInterval(47))
        let summary = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(store.transactions.count, before)   // no duplicate
        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(summary.imported, 0)
    }

    func testALetterForAnAlreadyImportedRowIsDropped() async throws {
        let (store, api) = makeStore()
        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt)
        _ = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        let before = store.transactions.count
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        let result = await store.syncPrivatEmail()
        XCTAssertEqual(store.transactions.count, before)
        XCTAssertEqual(result?.imported, 0)
        XCTAssertEqual(result?.merged, 1)
        // The cursor still advanced — a dropped duplicate must not re-fetch.
        XCTAssertEqual(store.syncState.emailCursor, 1)
    }

    func testAMatchedRowAdoptsTheStatementSuggestion() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let emailRowId = try XCTUnwrap(store.transactions.first {
            $0.externalId == "privat-email|u9|1" }?.id)

        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt,
                               category: "Супермаркети та продукти")
        _ = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        let survivor = try XCTUnwrap(store.transactions.first { $0.id == emailRowId })
        // Still the queue's row, now carrying the statement's category the way
        // a fresh statement row would — verbatim, translated only at the chip.
        XCTAssertEqual(survivor.resolution, .pending)
        XCTAssertEqual(survivor.suggestions, ["Супермаркети та продукти"])
    }

    func testADecidedRowIsNotTouchedByAMatch() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let emailRowId = try XCTUnwrap(store.transactions.first {
            $0.externalId == "privat-email|u9|1" }?.id)
        // The user decides the row before the statement arrives — the store's
        // real confirm path, the same one the queue's card calls.
        store.confirm(emailRowId, as: "Продукти")
        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt,
                               category: "Супермаркети та продукти")
        _ = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        let survivor = try XCTUnwrap(store.transactions.first { $0.id == emailRowId })
        XCTAssertEqual(survivor.category, "Продукти")       // untouched
        XCTAssertNotEqual(survivor.resolution, .pending)
        XCTAssertEqual(survivor.suggestions, [])            // no late suggestion
    }

    /// Importing the same export twice must stay a merge, and must not append
    /// the statement's word to a suggestion list that already holds it.
    func testReimportingTheSameStatementStaysOneRowWithOneSuggestion() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt,
                               category: "Супермаркети та продукти")
        _ = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        let count = store.transactions.count
        let second = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(store.transactions.count, count)
        XCTAssertEqual(second.merged, 1)
        XCTAssertEqual(store.transactions.first { $0.externalId == "privat-email|u9|1" }?
                        .suggestions, ["Супермаркети та продукти"])
    }

    /// One letter is one purchase. Two statement rows carrying the same
    /// amount+balance pair must not BOTH vanish into it — the second is a real
    /// purchase and there is nothing left to recover it from. A running balance
    /// makes the pair all but unrepeatable, and "all but" is not a reason to
    /// lose a row. Without the match being consumed, `imported` here is 0.
    func testTwoStatementRowsCannotBothVanishIntoOneLetter() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let before = store.transactions.count

        let a = statementRow(date: PrivatEmailStub.rows[0].occurredAt)
        let b = statementRow(date: PrivatEmailStub.rows[0].occurredAt
                                 .addingTimeInterval(60))
        let summary = store.applyStatement(statement([a, b]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(store.transactions.count, before + 1)
    }

    /// The same property in the other direction: one statement row cannot
    /// swallow two letters from one page.
    func testTwoLettersCannotBothVanishIntoOneStatementRow() async throws {
        let (store, api) = makeStore()
        _ = store.applyStatement(statement([
            statementRow(date: PrivatEmailStub.rows[0].occurredAt)]),
            filename: "виписка-тест.xlsx")
        let before = store.transactions.count
        _ = await store.registerPrivatEmail()
        // Two letters, one purchase's worth of numbers each — the same amount
        // and the same balance, a minute apart.
        var second = PrivatEmailStub.rows[0]
        second.id = 2
        second.occurredAt = PrivatEmailStub.rows[0].occurredAt.addingTimeInterval(60)
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0], second],
                           nextCursor: 2)]
        let result = await store.syncPrivatEmail()
        XCTAssertEqual(result?.merged, 1)
        XCTAssertEqual(result?.imported, 1)
        XCTAssertEqual(store.transactions.count, before + 1)
    }

    /// The same property as the test above, but the two letters land on
    /// DIFFERENT pages of one run — the shape a per-call guard cannot see,
    /// because rebuilding the statement index on every call to
    /// `withoutRowsTheStatementAlreadyBrought` would find the row "available"
    /// again on page 2. Fix-round-3 finding 2.
    func testTwoLettersOnDifferentPagesCannotBothVanishIntoOneStatementRow() async throws {
        let (store, api) = makeStore()
        _ = store.applyStatement(statement([
            statementRow(date: PrivatEmailStub.rows[0].occurredAt)]),
            filename: "виписка-тест.xlsx")
        let before = store.transactions.count
        _ = await store.registerPrivatEmail()

        let limit = AppStore.emailPageLimit
        // 199 filler rows carrying no balance (so they can never match the
        // statement's cross-source key), plus the FIRST matching letter as
        // the page's last row — filling page 1 to exactly `limit` so the
        // loop is forced to fetch a second page for the second letter.
        var firstLetter = PrivatEmailStub.rows[0]
        firstLetter.id = limit
        var fillers = (1..<limit).map(emailRow)
        fillers.append(firstLetter)

        var secondLetter = PrivatEmailStub.rows[0]
        secondLetter.id = limit + 1
        secondLetter.occurredAt = PrivatEmailStub.rows[0].occurredAt.addingTimeInterval(60)

        api.pages = [.init(transactions: fillers, nextCursor: limit),
                     .init(transactions: [secondLetter], nextCursor: limit + 1)]
        let result = await store.syncPrivatEmail()
        XCTAssertEqual(api.transactionCalls, 2)
        // Page 1's letter consumes the statement row; page 2's must find it
        // already gone and land as its own purchase, not a second merge.
        XCTAssertEqual(result?.merged, 1)
        XCTAssertEqual(result?.imported, limit)   // 199 fillers + the second letter
        XCTAssertEqual(store.transactions.count, before + limit)
    }

    /// The guards, at the store level: same amount, same balance, but another
    /// card — two rows, because merging them would destroy a real purchase.
    func testAMatchingAmountOnAnotherCardStillLandsTwice() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let before = store.transactions.count
        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt,
                               cardSuffix: "*1111")
        let summary = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(store.transactions.count, before + 1)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.merged, 0)
    }

    func testAStatementRowMoreThanThirtySixHoursLaterIsItsOwnPurchase() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let before = store.transactions.count
        let row = statementRow(date: PrivatEmailStub.rows[0]
                                   .occurredAt.addingTimeInterval(36 * 3600 + 60))
        _ = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(store.transactions.count, before + 1)
    }

    /// The account/balance half of the import reads `statement.rows` directly,
    /// so a row dropped from ingestion must still give its card a balance —
    /// otherwise the very first statement after an email backfill would leave
    /// the person with no Privat account at all.
    func testADroppedRowStillCreatesItsAccountAndBalance() async throws {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: [PrivatEmailStub.rows[0]], nextCursor: 1)]
        _ = await store.syncPrivatEmail()
        let row = statementRow(date: PrivatEmailStub.rows[0].occurredAt)
        let summary = store.applyStatement(statement([row]), filename: "виписка-тест.xlsx")
        XCTAssertEqual(summary.cardSuffixes, ["*2299"])
        let account = store.banks.first { $0.id == "privatbank" }?
            .accounts.first { $0.suffix == "*2299" }
        XCTAssertEqual(account?.balance, 903_450)
    }

    func testRowsAndCursorPersistTogether() async throws {
        let repo = MemoryRepository()
        let (store, api) = makeStore(repo)
        _ = await store.registerPrivatEmail()
        api.pages = [.init(transactions: PrivatEmailStub.rows, nextCursor: 5)]
        _ = await store.syncPrivatEmail()
        // persistNow() ran inside the loop — the repository already holds both.
        let saved = try repo.load("sync", as: SyncState.self)
        XCTAssertEqual(saved?.emailCursor, 5)
    }

    // MARK: the address is stable — board #158

    /// **The card, in one test.** Disconnect must keep everything.
    ///
    /// #91 deleted the account here, and its reasoning was sound in itself: an
    /// address nobody reads should stop collecting a person's mail. What it did
    /// not weigh is that there is NO ROUTE BACK — `/register` mints a new
    /// random address and the backend has no "give me my old mailbox" call — so
    /// the one irreplaceable thing in the app was also the easiest to destroy.
    func testDisconnectingKeepsTheAddressTheSecretAndTheAccount() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let address = store.privatEmailAddress
        store.syncState.emailCursor = 42

        store.pausePrivatEmail()

        XCTAssertEqual(api.deleteCalls, 0, "a disconnect must not touch the server account")
        XCTAssertNotNil(store.privatEmailCredentials)
        XCTAssertEqual(store.privatEmailAddress, address)
        XCTAssertFalse(store.privatEmailIsActive, "paused means letters stop arriving")
    }

    /// The cursor is reset only when the address actually changes.
    ///
    /// Same address means the same rows behind it, so a reset would re-import
    /// every letter this phone already holds — and the person would watch a
    /// resume duplicate months of history for no reason they could see.
    func testAPauseLeavesTheCursorAloneAndAChangeResetsIt() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.syncState.emailCursor = 42

        store.pausePrivatEmail()
        XCTAssertEqual(store.syncState.emailCursor, 42, "same address, same rows")

        store.resumePrivatEmail()
        XCTAssertEqual(store.syncState.emailCursor, 42)

        _ = await store.changePrivatEmailAddress()
        XCTAssertEqual(store.syncState.emailCursor, 0,
                       "a new account's row ids restart at 1")
    }

    /// Disconnect, reconnect, **same address, no registration** — the owner's
    /// own words: «I want the same mailbox to be issued on the phone».
    func testReconnectingReusesTheSameAddressWithoutRegisteringAgain() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let address = store.privatEmailAddress
        let registrations = api.registerCalls

        store.pausePrivatEmail()
        store.resumePrivatEmail()

        XCTAssertEqual(store.privatEmailAddress, address, "a different address is the bug")
        XCTAssertEqual(api.registerCalls, registrations, "resuming must mint nothing")
        XCTAssertTrue(store.privatEmailIsActive)
    }

    /// A paused address still exists and its secret still works, so gating the
    /// import on `privatEmailCredentials` alone would keep pulling letters
    /// after the person asked it to stop.
    func testAPausedImportPullsNothing() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.pausePrivatEmail()

        let result = await store.syncPrivatEmail()

        XCTAssertNil(result, "a paused mailbox must not import")
    }

    /// Changing the address un-pauses it. Left true, somebody would change
    /// their address and then watch nothing arrive at the new one.
    func testChangingTheAddressWhilePausedLeavesTheNewOneLive() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.pausePrivatEmail()

        _ = await store.changePrivatEmailAddress()
        _ = await store.registerPrivatEmail()

        XCTAssertFalse(store.syncState.emailPaused)
        XCTAssertTrue(store.privatEmailIsActive)
    }

    /// **«Видалити все» must not leave an orphan.**
    ///
    /// `resetEverything` wipes the Keychain, and the secret is the only thing
    /// that can ever reach the account again — so a wipe on its own left a live
    /// mailbox nobody could read, going on collecting `from` and `subject` for
    /// every letter, forever.
    func testTheServerAccountCanBeDeletedBeforeAWipe() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()

        let outcome = await store.deletePrivatEmailAccount()

        XCTAssertEqual(outcome, .disconnected)
        XCTAssertEqual(api.deleteCalls, 1)
    }

    /// The screen decides what to do about a failed delete, so this reports it
    /// rather than swallowing it — and it must not have wiped the local half in
    /// the meantime, or "cancel" would have nothing left to cancel.
    func testAFailedAccountDeleteIsReportedAndChangesNothingLocally() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .offline("no route")

        let outcome = await store.deletePrivatEmailAccount()

        XCTAssertEqual(outcome, .failed(.offline("no route")))
        XCTAssertNotNil(store.privatEmailCredentials,
                        "nothing local may change until the person answers")
    }

    // MARK: board #175 — the last few letters

    /// **The state this feature exists for.** A letter that arrived and was
    /// not understood is filed `kind == "transaction"` by the backend — it is
    /// unmistakably bank content — so anything reading the kind before the
    /// flag would call a failure a success.
    func testAnUnreadableLetterIsNotReportedAsAnAddedTransaction() {
        let failed = PrivatEmailRecentLetter(
            id: 1, receivedAt: .now, from: "ПриватБанк <info@pb.ua>",
            subject: "Вигаданий лист", kind: "transaction", parseFailed: true)
        let worked = PrivatEmailRecentLetter(
            id: 2, receivedAt: .now, from: "ПриватБанк <info@pb.ua>",
            subject: "Вигаданий лист", kind: "transaction", parseFailed: false)

        XCTAssertNotEqual(PrivatEmailSetupView.outcome(of: failed),
                          PrivatEmailSetupView.outcome(of: worked),
                          "the two states this list exists to tell apart must not read alike")
        XCTAssertEqual(PrivatEmailSetupView.outcome(of: failed), "не вдалося прочитати")
    }

    // MARK: board #187 — two waiting statements must not read alike

    /// **The property the whole card is about**, as an assertion: two waiting
    /// statements have to differ on screen. Every button used to read
    /// «Завантажити виписку», so with two waiting a person had to guess.
    func testTwoWaitingStatementsDoNotReadAlike() {
        let first = PrivatEmailStatement(id: 1, filename: "vypyska-a.xlsx",
                                         sizeBytes: 12_800,
                                         receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
        let second = PrivatEmailStatement(id: 2, filename: "vypyska-b.xlsx",
                                          sizeBytes: 25_600,
                                          receivedAt: Date(timeIntervalSince1970: 1_787_630_000))

        XCTAssertNotEqual(first.filename, second.filename,
                          "the filename is what the row leads with")
        XCTAssertNotEqual(PrivatEmailSetupView.statementDetail(first, .uk),
                          PrivatEmailSetupView.statementDetail(second, .uk),
                          "…and the line under it must differ too, in case the bank "
                          + "ever names two files the same")
    }

    /// Size and arrival, and **nothing that claims to be the period**. The span
    /// a statement covers lives inside the xlsx and the app learns it by
    /// parsing — which is the download this line helps somebody choose. A
    /// guessed period would be worse than none: somebody would pick by it.
    func testTheStatementLineShowsOnlyWhatIsActuallyKnown() {
        let item = PrivatEmailStatement(id: 1, filename: "vypyska-a.xlsx",
                                        sizeBytes: 12_800,
                                        receivedAt: Date(timeIntervalSince1970: 1_787_890_000))

        let line = PrivatEmailSetupView.statementDetail(item, .uk)
        XCTAssertTrue(line.contains("13"), "12 800 bytes rounds to 13 KB: \(line)")
        XCTAssertTrue(line.contains("КБ"), line)
        XCTAssertTrue(line.contains(PrivatEmailSetupView.stamp.string(from: item.receivedAt)), line)
    }

    /// The unit is translated; the numbers are not. Same rule `stamp` follows
    /// — a numeric format reads the same in both languages.
    func testTheSizeUnitFollowsTheInterfaceLanguage() {
        let item = PrivatEmailStatement(id: 1, filename: "vypyska-a.xlsx",
                                        sizeBytes: 12_800,
                                        receivedAt: Date(timeIntervalSince1970: 1_787_890_000))

        XCTAssertTrue(PrivatEmailSetupView.statementDetail(item, .en).contains("KB"),
                      PrivatEmailSetupView.statementDetail(item, .en))
        XCTAssertFalse(PrivatEmailSetupView.statementDetail(item, .en).contains("КБ"),
                       "the Cyrillic unit must not survive into English")
    }

    /// A file smaller than a kilobyte still has a size, and «0 КБ» reads as
    /// «empty» — which would be a reason not to download the only statement
    /// somebody has.
    func testATinyStatementDoesNotReadAsEmpty() {
        let tiny = PrivatEmailStatement(id: 1, filename: "vypyska-a.xlsx", sizeBytes: 200,
                                        receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
        XCTAssertTrue(PrivatEmailSetupView.statementDetail(tiny, .uk).hasPrefix("1 "),
                      PrivatEmailSetupView.statementDetail(tiny, .uk))
    }

    /// A kind this build has never heard of must render, not crash and not
    /// decode-fail. That is why `kind` is a String rather than an enum.
    func testAnUnknownKindStillReads() {
        let future = PrivatEmailRecentLetter(
            id: 1, receivedAt: .now, from: "Хтось <someone@example.test>",
            subject: "Вигаданий лист", kind: "something-invented-later",
            parseFailed: false)

        XCTAssertEqual(PrivatEmailSetupView.outcome(of: future), "не банківський лист")
    }

    func testEachKnownKindSaysWhatBecameOfTheLetter() {
        func outcome(_ kind: String) -> LocalizedStringKey {
            PrivatEmailSetupView.outcome(of: .init(
                id: 1, receivedAt: .now, from: "ПриватБанк <info@pb.ua>",
                subject: "Вигаданий лист", kind: kind, parseFailed: false))
        }

        XCTAssertEqual(outcome("transaction"), "операція додана")
        XCTAssertEqual(outcome("forwarding_confirmation"), "код підтвердження")
        XCTAssertEqual(outcome("statement_link"), "виписка")
    }

    /// A backend predating the route answers 404, and an absent capability is
    /// not an error worth painting over a screen whose every other part works
    /// — the forwarding CODE lives on that screen.
    func testAnOlderBackendJustHasNoLettersToShow() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.recentError = .server(404, "not found")

        let letters = await store.privatEmailRecentLetters()

        XCTAssertTrue(letters.isEmpty)
        XCTAssertNil(store.syncState.lastStop, "a missing route is not a sync failure")
    }

    /// A real failure is not lost either: a dead secret still gets recorded on
    /// its way past, exactly as `privatEmailStatements` does.
    func testADeadSecretFoundHereStillFlagsTheReconnect() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.recentError = .unauthorized

        _ = await store.privatEmailRecentLetters()

        XCTAssertTrue(store.syncState.emailNeedsReconnect)
    }

    // MARK: board #171 — the server follows the link, on a tap

    /// **The whole point: the bytes reach the same parser.**
    ///
    /// The download answers with an ordinary `PrivatEmailStatement`, so the
    /// import goes through `importEmailedStatement` — the entry point the file
    /// picker and the emailed-attachment path already use. Board #97's
    /// decision holds without a line of new parsing code, and
    /// `applyStatement`'s cross-source dedup comes along for free.
    func testFollowingALinkImportsThroughTheOrdinaryStatementPath() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.downloaded = .init(id: 91, filename: "vypyska-vygadana.xlsx",
                               sizeBytes: PrivatStatementStub.sampleData.count,
                               receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
        api.bytes = PrivatStatementStub.sampleData
        let link = PrivatEmailStatementLink(id: 8_145, url: "https://example.test/stub",
                                            receivedAt: Date(timeIntervalSince1970: 1_787_890_000))

        let summary = try? await store.downloadStatementLink(link)

        XCTAssertEqual(api.downloadedLinks, [8_145], "the LINK's id, not the statement's")
        XCTAssertNotNil(summary)
        XCTAssertGreaterThan(summary?.imported ?? 0, 0,
                             "the fetched file has to reach the parser, not just the disk")
        XCTAssertEqual(api.consumed, [91],
                       "the statement is consumed once it has landed, like any other")
    }

    /// A failed download must not consume anything. The link stays listed
    /// because «Відкрити посилання» is the fallback, and a link the app has
    /// quietly forgotten cannot be opened by hand.
    func testAFailedDownloadConsumesNothing() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.downloadLinkError = .server(422, "what came back is not a spreadsheet")
        let link = PrivatEmailStatementLink(id: 8_145, url: "https://example.test/stub",
                                            receivedAt: .now)

        var thrown: Error?
        do { _ = try await store.downloadStatementLink(link) } catch { thrown = error }

        XCTAssertNotNil(thrown, "the screen decides what to say, so this must not be swallowed")
        XCTAssertEqual(api.consumed, [], "nothing was imported, so nothing may be consumed")
    }

    /// A dead secret found here means the same thing it means anywhere else,
    /// and the app has one place that records it.
    func testAnUnauthorizedDownloadFlagsTheReconnect() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.downloadLinkError = .unauthorized
        let link = PrivatEmailStatementLink(id: 8_145, url: "https://example.test/stub",
                                            receivedAt: .now)

        _ = try? await store.downloadStatementLink(link)

        XCTAssertTrue(store.syncState.emailNeedsReconnect)
    }

    /// **Nothing on this side ever fetches a URL**, and that is structural
    /// rather than a habit: `PrivatEmailAPI` has no call that takes one. The
    /// only thing that follows a link is `app/statement_fetch.py`, behind a
    /// host allowlist the phone could not enforce and should not try to.
    func testTheLinkURLIsNeverWhatIsRequested() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.bytes = PrivatStatementStub.sampleData
        api.downloaded = .init(id: 91, filename: "vypyska-vygadana.xlsx",
                               sizeBytes: PrivatStatementStub.sampleData.count,
                               receivedAt: .now)
        let link = PrivatEmailStatementLink(id: 8_145, url: "https://example.test/stub",
                                            receivedAt: .now)

        _ = try? await store.downloadStatementLink(link)

        XCTAssertEqual(api.downloadedLinks, [link.id],
                       "the server is asked by ID; the URL never leaves the phone as a request")
    }

    // MARK: board #170 — ending the mailbox on purpose

    /// **The gap this card closes.** Before it, `deletePrivatEmailAccount` had
    /// no caller: the server account could be deleted but the phone went on
    /// holding the credentials, so the screen still showed a live address for a
    /// mailbox that no longer existed. Nothing ended a mailbox at all.
    func testDeletingTheAddressEndsBothHalves() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()

        let outcome = await store.deletePrivatEmailAddress()

        XCTAssertEqual(outcome, .disconnected)
        XCTAssertEqual(api.deleteCalls, 1, "the server account has to actually go")
        XCTAssertNil(store.privatEmailCredentials)
        XCTAssertNil(store.privatEmailAddress)
        XCTAssertFalse(store.syncState.emailAddressIssued,
                       "board #111's flag is what offers a REPLACEMENT — after a "
                       + "deliberate delete the next offer is an ordinary first one")
    }

    /// A deliberate delete is not a reset. Somebody ending their mailbox has
    /// not asked to lose what they already bought, and folding either act into
    /// the other is what board #168's screenshot rejected.
    func testDeletingTheAddressKeepsTheTransactions() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        // Invented merchant and suffix, per the project's fixture rule — the
        // seed's own values may never appear in source, and this repo is public.
        store.transactions = [Transaction(id: UUID(), date: Date(), kind: .expense,
                                          category: "Покупки", merchant: "Крамниця-Вигадана",
                                          amount: -123_45, cardSuffix: "*7777",
                                          bankId: "privatbank", receiptId: nil,
                                          splits: [], resolution: .user, suggestions: [])]

        _ = await store.deletePrivatEmailAddress()

        XCTAssertEqual(store.transactions.count, 1,
                       "the purchases are on the phone, not in the mailbox")
    }

    /// The cursor moves only when the address itself ends. A new registration
    /// is a new server account whose row ids restart at 1, so a cursor left at
    /// N would claim everything up to N had already been imported.
    func testDeletingTheAddressResetsTheCursorAndThePause() async {
        let (store, _) = makeStore()
        _ = await store.registerPrivatEmail()
        store.syncState.emailCursor = 42
        store.pausePrivatEmail()

        _ = await store.deletePrivatEmailAddress()

        XCTAssertEqual(store.syncState.emailCursor, 0)
        XCTAssertFalse(store.syncState.emailPaused)
    }

    /// Board #158's shape, restored by #170: a failed request **asks** rather
    /// than proceeding anyway. Wiping the local half regardless is what leaves
    /// a live address nobody can read.
    func testAFailedDeleteKeepsTheAddressAndSaysSo() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .offline("no route")

        let outcome = await store.deletePrivatEmailAddress()

        XCTAssertEqual(outcome, .failed(.offline("no route")))
        XCTAssertNotNil(store.privatEmailCredentials,
                        "a person who has not answered yet must still have an address")
        XCTAssertTrue(store.syncState.emailAddressIssued)
    }

    /// The offline escape, offered second and never first. It is the
    /// second-best answer on purpose — the account stays alive with nobody able
    /// to read it — but a person with no signal must not be trapped.
    func testForcingPastAFailedDeleteStillEndsTheLocalHalf() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .offline("no route")

        let outcome = await store.deletePrivatEmailAddress(force: true)

        XCTAssertEqual(outcome, .disconnected)
        XCTAssertNil(store.privatEmailCredentials)
        XCTAssertFalse(store.syncState.emailAddressIssued)
    }

    /// A dead secret is not a failure to report: there is nothing left to
    /// delete, and refusing would strand the person on credentials that can
    /// never work again.
    func testAnAlreadyGoneAccountDeletesCleanly() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.deleteError = .unauthorized

        let outcome = await store.deletePrivatEmailAddress()

        XCTAssertEqual(outcome, .disconnected)
        XCTAssertNil(store.privatEmailCredentials)
    }

    /// «Змінити адресу» and «Видалити адресу назавжди» are the same
    /// destruction — they differ only in what the screen offers next. Pinned so
    /// the two cannot drift apart in the flags they reset.
    func testChangingAndDeletingLeaveTheSameState() async {
        let (changed, _) = makeStore()
        _ = await changed.registerPrivatEmail()
        changed.syncState.emailCursor = 9
        _ = await changed.changePrivatEmailAddress()

        let (deleted, _) = makeStore()
        _ = await deleted.registerPrivatEmail()
        deleted.syncState.emailCursor = 9
        _ = await deleted.deletePrivatEmailAddress()

        XCTAssertEqual(changed.privatEmailCredentials, deleted.privatEmailCredentials)
        XCTAssertEqual(changed.syncState.emailCursor, deleted.syncState.emailCursor)
        XCTAssertEqual(changed.syncState.emailAddressIssued,
                       deleted.syncState.emailAddressIssued)
        XCTAssertEqual(changed.syncState.emailPaused, deleted.syncState.emailPaused)
    }


    // MARK: board #145 — the statement that arrives as a link

    func testAWaitingLinkIsOffered() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.waitingLinks = [.init(id: 7, url: "https://socauth.privatbank.ua/cp/api/out_click.php?token=a",
                                  receivedAt: Date(timeIntervalSince1970: 1_787_890_000))]

        let links = await store.privatEmailStatementLinks()

        XCTAssertEqual(links.map(\.id), [7])
        XCTAssertEqual(links.first?.host, "socauth.privatbank.ua",
                       "the host is what the person is shown — a tracking URL is unreadable")
    }

    /// A backend that predates this card answers 404, and that is not an error
    /// worth putting on a screen: an older server simply has no links.
    func testAnOlderBackendIsNotAnError() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.linksError = .server(404, "not found")

        let links = await store.privatEmailStatementLinks()

        XCTAssertEqual(links, [])
    }

    /// Any other failure is swallowed too — but through `noteIfUnauthorized`,
    /// so a dead secret still reaches the screen that says so.
    func testADeadSecretIsStillNoticed() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.linksError = .unauthorized

        _ = await store.privatEmailStatementLinks()

        XCTAssertTrue(store.syncState.emailNeedsReconnect)
    }

    func testDismissingALinkStopsItBeingOffered() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        let link = PrivatEmailStatementLink(id: 7, url: "https://privatbank.ua/x",
                                            receivedAt: Date(timeIntervalSince1970: 1_787_890_000))

        await store.forgetStatementLink(link)

        XCTAssertEqual(api.consumedLinks, [7])
    }

    /// The consume is `try?` on purpose: the person has already been handed
    /// the link, so failing that gesture because a bookkeeping call did not
    /// land would report a problem they do not have.
    func testAFailedDismissIsNotReportedToThePerson() async {
        let (store, api) = makeStore()
        _ = await store.registerPrivatEmail()
        api.consumeLinkError = .offline("no route")

        await store.forgetStatementLink(
            .init(id: 7, url: "https://privatbank.ua/x", receivedAt: .now))

        XCTAssertEqual(api.consumedLinks, [], "precondition: the call really did fail")
    }

}
