import XCTest
@testable import MonitorFinance

@MainActor
final class CardSelectionTests: XCTestCase {
    private func account(_ id: String, enabled: Bool?) -> Account {
        Account(id: id, suffix: "*" + String(id.suffix(4)), type: "black",
                currency: "UAH", balance: 0, creditLimit: nil, syncEnabled: enabled)
    }

    private func makeStore(accounts: [Account]) -> AppStore {
        let seed = SeedBundle(
            transactions: [],
            banks: [Bank(id: "monobank", displayName: "monobank", status: .available,
                         connected: true, accounts: accounts)],
            categories: [], rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    func testNilMeansEnabledAndFalseFilters() {
        let store = makeStore(accounts: [account("acc-1111", enabled: nil),
                                         account("acc-2222", enabled: false),
                                         account("acc-3333", enabled: true)])
        XCTAssertEqual(store.syncAccounts.map(\.id), ["acc-1111", "acc-3333"])
    }

    func testABanksJSONWithoutTheFieldStillDecodes() throws {
        let json = """
        {"id":"a","suffix":"*1","type":"black","currency":"UAH","balance":5}
        """
        let decoded = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertNil(decoded.syncEnabled)
    }

    func testSetSyncEnabledFlipsAndPersistsTheFlag() {
        let store = makeStore(accounts: [account("acc-1111", enabled: nil)])
        store.setSyncEnabled(bankId: "monobank", accountId: "acc-1111", false)
        XCTAssertEqual(store.banks[0].accounts[0].syncEnabled, false)
        XCTAssertTrue(store.syncAccounts.isEmpty)
    }

    func testReconnectPreservesTheChoice() {
        let store = makeStore(accounts: [account("acc-1111", enabled: false),
                                         account("acc-2222", enabled: nil)])
        // applyAccounts rebuilds from clientInfo; the flag must survive by id.
        let info = MonobankClientInfo(
            clientId: "c", name: "n",
            accounts: [MonobankAccount(id: "acc-1111", type: "black", currencyCode: 980,
                                       balance: 10, creditLimit: 0, maskedPan: ["537541******1111"]),
                       MonobankAccount(id: "acc-2222", type: "white", currencyCode: 980,
                                       balance: 20, creditLimit: 0, maskedPan: ["537541******2222"])])
        store.applyAccounts(info, bankId: "monobank")
        XCTAssertEqual(store.banks[0].accounts.first { $0.id == "acc-1111" }?.syncEnabled, false)
        XCTAssertNil(store.banks[0].accounts.first { $0.id == "acc-2222" }?.syncEnabled)
    }

    func testProgressCountsOnlyEnabledAccounts() {
        let store = makeStore(accounts: [account("acc-1111", enabled: nil),
                                         account("acc-2222", enabled: false)])
        store.syncState.depthMonths = 3
        store.isSyncing = true
        let now = Date()
        store.syncState.cursors["acc-1111"] = {
            var c = SyncState.Cursor(); c.newest = now
            c.oldest = now.addingTimeInterval(-SyncPlan.window); return c
        }()
        // A DISABLED card's stale cursor must not inflate `done`.
        store.syncState.cursors["acc-2222"] = {
            var c = SyncState.Cursor(); c.newest = now
            c.oldest = now.addingTimeInterval(-SyncPlan.window * 3); return c
        }()
        let progress = store.syncProgress
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total,
                       SyncPlan.totalWindows(depthMonths: 3, accounts: 1))
    }

    /// `BankDetailView`'s toggles make this reachable with one tap where it
    /// wasn't before: every card disabled still leaves `isSyncing` true and
    /// `depthMonths > 0`, so without the extra guard `syncProgress` would
    /// compute `max(1, depth) * 0 = 0` and the status view would render
    /// «Завантажуємо покупки… 0 з 0» while nothing is being fetched.
    func testProgressIsNilWhenEveryCardIsDisabled() {
        let store = makeStore(accounts: [account("acc-1111", enabled: false),
                                         account("acc-2222", enabled: false)])
        store.syncState.depthMonths = 3
        store.isSyncing = true
        XCTAssertNil(store.syncProgress)
    }
}
