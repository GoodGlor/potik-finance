import XCTest
@testable import MonitorFinance

@MainActor
final class AppStoreImportTests: XCTestCase {
    private var sample: Data { Data(base64Encoded: PrivatFixtureData.sampleBase64)! }

    private func makeStore(transactions: [Transaction] = [], rules: [Rule] = []) -> AppStore {
        let seed = SeedBundle(
            transactions: transactions,
            banks: [Bank(id: "monobank", displayName: "monobank", status: .available,
                         connected: false, accounts: []),
                    Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                         connected: false, accounts: [])],
            categories: [], rules: rules, receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }
    // Same construction style as SyncStoreTests: a per-test keychain
    // service, and the `api:` default is never called by an import.

    func testImportLandsRowsAndSummaryCounts() throws {
        let store = makeStore()
        let summary = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        XCTAssertEqual(summary.imported, 12)
        XCTAssertEqual(summary.merged, 0)
        XCTAssertEqual(summary.skippedNonUAH, 2)
        XCTAssertEqual(summary.cardSuffixes, ["*1111", "*2222"])
        XCTAssertEqual(store.transactions.count, 12)
    }

    func testReimportIsIdempotent() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        let second = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.merged, 12)
        XCTAssertEqual(store.transactions.count, 12)
    }

    func testAccountsUpsertPerSuffixWithNewestBalance() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        let bank = store.banks.first { $0.id == "privatbank" }!
        XCTAssertTrue(bank.connected)
        XCTAssertEqual(bank.accounts.map(\.suffix).sorted(), ["*1111", "*2222"])
        XCTAssertEqual(bank.accounts.first { $0.suffix == "*1111" }?.balance, 8885_00)
        XCTAssertEqual(bank.accounts.first { $0.suffix == "*2222" }?.balance, 700_00)
        // The empty-card interest row and the USD card created no account.
        XCTAssertEqual(bank.accounts.count, 2)
    }

    func testARuleTheUserTaughtDecidesFirst() throws {
        let store = makeStore(rules: [Rule(merchantKey: "крамниця хвіст",
                                           category: "Тварини", ambiguous: false)])
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        let decided = store.transactions.filter { $0.merchant == "Крамниця Хвіст" }
        XCTAssertEqual(decided.count, 2)
        XCTAssertTrue(decided.allSatisfy { $0.resolution == .rule && $0.category == "Тварини" })
    }

    func testTransfersNeverEnterTheQueue() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        let transfers = store.transactions.filter { $0.kind == .transfer }
        // Two, not three: board #6 took the cash withdrawal out of this set.
        // The fixture's other pair name the owner's own card, and those are
        // the only rows that may skip the queue.
        XCTAssertEqual(transfers.count, 2)
        XCTAssertTrue(transfers.allSatisfy {
            $0.merchant.lowercased().contains("своєї картки")
                || $0.merchant.lowercased().contains("свою картку")
        }, transfers.map(\.merchant).description)
        XCTAssertTrue(transfers.allSatisfy { $0.resolution == .transfer })
        XCTAssertFalse(store.pendingGroups.contains { $0.kind == .transfer })
    }

    /// The row that left the set above, followed end to end: it is spending
    /// now, it reaches the queue, and the chip there offers the app's own word
    /// for cash. Before #6 it was `.transfer` — invisible in the queue and
    /// subtracted from nothing, so the money simply vanished from the app.
    func testTheCashWithdrawalReachesTheQueueAsSpending() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        let cash = try XCTUnwrap(store.transactions.first {
            $0.merchant.lowercased().contains("банкомат")
        })
        XCTAssertEqual(cash.kind, .expense)
        XCTAssertEqual(cash.resolution, .pending)
        // Board #14 moved the translation from the row to the chip: the row
        // keeps the bank's own word, and the CARD is where «Готівка» appears.
        XCTAssertEqual(cash.suggestions, ["Зняття готівки"])
        let card = try XCTUnwrap(store.pendingGroups.first { $0.rowIds.contains(cash.id) },
                                 "a pending expense that reaches no queue card is unanswerable")
        XCTAssertEqual(card.suggestion, BudgetMath.cashCategory)
        XCTAssertEqual(Derived.totals([cash]).spent, abs(cash.amount))
    }

    func testDemoRowsAreClearedByAPrivatFirstImport() throws {
        let demo = Transaction(id: UUID(), date: .init(timeIntervalSince1970: 1_780_000_000),
                               kind: .expense, category: "Продукти", merchant: "Демо",
                               amount: -100, cardSuffix: "*0000", bankId: "monobank",
                               receiptId: nil, splits: [], resolution: .rule,
                               suggestions: [], externalId: nil, hold: nil)
        let store = makeStore(transactions: [demo])
        _ = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        XCTAssertFalse(store.transactions.contains { $0.externalId == nil },
                       "the demo sweep runs inside ingestRows")
    }

    func testReimportPreservesTheUsersSyncChoice() throws {
        let store = makeStore()
        if let b = store.banks.firstIndex(where: { $0.id == "privatbank" }) {
            store.banks[b].accounts.append(Account(
                id: "privat-1111", suffix: "*1111", type: "card",
                currency: "UAH", balance: 0, creditLimit: nil, syncEnabled: false))
        }
        let summary = try store.importPrivatStatement(sample, filename: "виписка-тест.xlsx")
        XCTAssertEqual(summary.cardSuffixes, ["*1111", "*2222"])
        let bank = store.banks.first { $0.id == "privatbank" }!
        let card = bank.accounts.first { $0.id == "privat-1111" }
        XCTAssertEqual(card?.balance, 8885_00)
        XCTAssertEqual(card?.syncEnabled, false,
                       "the upsert must update .balance in place, never rebuild the account")
    }

    func testGarbageThrowsWithoutTouchingTheStore() {
        let store = makeStore()
        XCTAssertThrowsError(try store.importPrivatStatement(Data("сміття".utf8), filename: "виписка-тест.xlsx"))
        XCTAssertEqual(store.transactions.count, 0)
        XCTAssertFalse(store.banks.first { $0.id == "privatbank" }!.connected)
    }
}
