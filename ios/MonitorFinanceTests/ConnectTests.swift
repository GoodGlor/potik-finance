import XCTest
@testable import MonitorFinance

@MainActor
final class ConnectTests: XCTestCase {

    private func store(_ mode: Launch.StubMode) -> AppStore {
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"),
                        api: MonobankStub(mode: mode))
    }

    func testAGoodTokenConnectsAndStoresTheToken() async {
        let s = store(.ok)
        // `await` cannot sit inside XCTAssertEqual's (non-async) autoclosure
        // argument, so the outcome is captured first — same assertion.
        let outcome = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        XCTAssertEqual(outcome, .connected)
        XCTAssertTrue(s.banks.first { $0.id == "monobank" }?.connected ?? false)
        XCTAssertEqual(s.token(for: "monobank"), "tok1")
    }

    func testTheRealAccountsReplaceTheSeededOnes() async {
        let s = store(.ok)
        _ = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        XCTAssertEqual(s.banks.first { $0.id == "monobank" }?.accounts.map(\.suffix),
                       ["*1111", "*2222"])
        XCTAssertEqual(s.syncAccounts.count, 2)
    }

    /// Nothing is saved on a bad token — not the token, not the connection.
    func testABadTokenSavesNothing() async {
        let s = store(.fail403)
        let outcome = await s.verifyAndConnect(bankId: "monobank", token: "bad")
        XCTAssertEqual(outcome, .failed(.invalidToken))
        XCTAssertFalse(s.banks.first { $0.id == "monobank" }?.connected ?? true)
        XCTAssertNil(s.token(for: "monobank"))
    }

    func testARateLimitIsItsOwnOutcomeSoTheUICanCountDown() async {
        let outcome = await store(.fail429).verifyAndConnect(bankId: "monobank", token: "t")
        XCTAssertEqual(outcome, .failed(.rateLimited))
    }

    func testBeingOfflineIsItsOwnOutcome() async {
        guard case .failed(.offline) = await store(.offline)
            .verifyAndConnect(bankId: "monobank", token: "t") else {
            return XCTFail("expected .failed(.offline)")
        }
    }

    /// Reconnecting the same person resumes; a different person is a question,
    /// never a silent merge.
    func testReconnectingTheSameClientJustConnects() async {
        let s = store(.ok)
        _ = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        let outcome = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        XCTAssertEqual(outcome, .connected)
    }

    func testADifferentClientIsReportedRatherThanConnected() async {
        let s = store(.ok)
        s.syncState.clientHash = AppStore.clientHash("somebody-else")
        guard case .differentClient = await s.verifyAndConnect(bankId: "monobank", token: "t") else {
            return XCTFail("expected .differentClient")
        }
        XCTAssertFalse(s.banks.first { $0.id == "monobank" }?.connected ?? true,
                       "nothing is connected until the user decides")
    }

    func testAcceptingANewClientWipesTheOldHistory() async {
        let s = store(.ok)
        _ = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        s.ingest([MonobankMapper.transaction(
            MonobankStatementItem(id: "r1", time: 1, description: "x", mcc: nil, amount: -1,
                                  operationAmount: nil, currencyCode: 980, commissionRate: 0,
                                  cashbackAmount: 0, balance: nil, hold: false,
                                  monoReceiptId: nil, counterName: nil),
            account: s.syncAccounts[0])],
            step: .forward(account: s.syncAccounts[0].id,
                           from: Date(timeIntervalSince1970: 0),
                           to: Date(timeIntervalSince1970: 100)),
            wasEmpty: false)
        XCTAssertEqual(s.transactions.count, 1)

        let other = MonobankClientInfo(clientId: "other", name: "n", accounts: [])
        s.acceptNewClient(bankId: "monobank", token: "tok2", info: other)
        XCTAssertTrue(s.transactions.isEmpty)
        XCTAssertEqual(s.token(for: "monobank"), "tok2")
    }

    /// A 403 during sync sets this; a good token must clear it or the banner
    /// never goes away.
    func testConnectingClearsAPendingReconnectFlag() async {
        let s = store(.ok)
        s.markNeedsReconnect()
        _ = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        XCTAssertFalse(s.syncState.needsReconnect)
    }

    /// Spec §2: disconnecting keeps the history AND the cursors, so
    /// reconnecting the same person resumes instead of re-fetching a year.
    func testDisconnectingKeepsTheHistoryAndTheCursors() async {
        let s = store(.ok)
        _ = await s.verifyAndConnect(bankId: "monobank", token: "tok1")
        s.syncState.cursors["a1"] = .init(newest: Date(), oldest: Date(),
                                          exhausted: false, emptyStreak: 0)
        s.transactions = [MonobankMapper.transaction(
            MonobankStatementItem(id: "r1", time: 1, description: "x", mcc: nil, amount: -1,
                                  operationAmount: nil, currencyCode: 980, commissionRate: 0,
                                  cashbackAmount: 0, balance: nil, hold: false,
                                  monoReceiptId: nil, counterName: nil),
            account: s.syncAccounts[0])]

        s.disconnect(bankId: "monobank")

        XCTAssertNil(s.token(for: "monobank"))
        XCTAssertEqual(s.transactions.count, 1, "history is the user's, not the bank's")
        XCTAssertNotNil(s.syncState.cursors["a1"], "reconnecting must resume, not restart")
        XCTAssertNotNil(s.syncState.clientHash)
    }

    // MARK: the depth screen's promise

    func testTheEstimateMatchesWhatTheEngineWillActuallyDo() {
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 1, accounts: 2), 61)
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 12, accounts: 2), 23 * 61)
    }
}
