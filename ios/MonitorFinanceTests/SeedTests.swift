import XCTest
@testable import MonitorFinance

final class SeedTests: XCTestCase {
    func testBundledSeedDecodesCompletely() throws {
        let seed = try SeedLoader.load()
        XCTAssertEqual(seed.transactions.count, 62)
        XCTAssertEqual(seed.banks.map(\.id), ["monobank", "privatbank"])
        XCTAssertEqual(seed.banks[0].accounts.count, 4)
        XCTAssertFalse(seed.categories.isEmpty)
        // Non-empty, matching the `categories` check above — this test is
        // "decodes completely," not "decodes to a specific sample count";
        // the sample count itself is Task 1's business and is asserted
        // precisely in `testTheBundledSamplesDecodeAsReceipts` below.
        XCTAssertFalse(seed.receipts.isEmpty)
    }

    func testAmountsAreSignedByKind() throws {
        let seed = try SeedLoader.load()
        for t in seed.transactions where t.kind != .transfer {
            XCTAssertEqual(t.amount < 0, t.kind == .expense, t.merchant)
        }
        XCTAssertTrue(seed.transactions.contains { $0.kind == .transfer && $0.amount > 0 })
        XCTAssertTrue(seed.transactions.contains { $0.kind == .transfer && $0.amount < 0 })
    }

    func testDatesCarryKyivLocalTime() throws {
        let seed = try SeedLoader.load()
        let last = try XCTUnwrap(seed.transactions.max(by: { $0.date < $1.date }))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: last.date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 8, 21, 18, 12])
    }

    func testRoundTripThroughTheSharedCoders() throws {
        let seed = try SeedLoader.load()
        let data = try SeedLoader.encoder.encode(seed.transactions)
        let back = try SeedLoader.decoder.decode([Transaction].self, from: data)
        XCTAssertEqual(back, seed.transactions)
    }

    func testTheBundledSamplesDecodeAsReceipts() throws {
        let seed = try SeedLoader.load()

        // A floor, not an exact count: Task 1 already grew this from 3 to 5
        // and nothing here forbids a later task adding another. Never
        // shrinking below the original baseline still catches a build
        // script that drops samples outright, without breaking every time
        // one is added for an unrelated reason.
        XCTAssertGreaterThanOrEqual(seed.receipts.count, 3)

        // Distinct document numbers matter beyond decoding: ScannerView's
        // sample picker keys each row's accessibility identifier as
        // "scanner.sample.\(documentNumber)" — a collision would make two
        // sample rows indistinguishable to a UI test, not just to a human.
        XCTAssertEqual(Set(seed.receipts.map(\.documentNumber)).count, seed.receipts.count)

        for r in seed.receipts {
            XCTAssertFalse(r.items.isEmpty, r.sellerName)
            XCTAssertGreaterThan(r.fiscalSum, 0, r.sellerName)
            XCTAssertEqual(r.items.reduce(0) { $0 + $1.sum }, r.fiscalSum, r.sellerName)
        }
    }

    func testReferenceDataStandsAloneWithoutDemoData() throws {
        let reference = try SeedLoader.loadReference()
        XCTAssertEqual(reference.banks.map(\.id), ["monobank", "privatbank"])
        XCTAssertTrue(reference.banks.allSatisfy { $0.accounts.isEmpty },
                      "accounts are the owner's, not reference data")
        XCTAssertFalse(reference.categories.isEmpty)
        XCTAssertEqual(reference.productGroups.count, 21)
    }

    /// In Debug the merged bundle still looks exactly as it always did, which
    /// is why no other test in this target had to change.
    func testTheMergedBundleStillCarriesTheDemoDataInDebug() throws {
        let seed = try SeedLoader.load()
        XCTAssertEqual(seed.transactions.count, 62)
        XCTAssertEqual(seed.banks[0].accounts.count, 4)
        // Five, not eight: board #15 dropped the three keyed to a masked card
        // number. They taught the sheet's own-card-transfer category, which is
        // no longer a category — and `GenericMerchant` has refused to apply a
        // rule for a masked card since board #7, so they had already stopped
        // doing anything.
        XCTAssertEqual(seed.rules.count, 5)
    }

    func testUnknownBankStatusDecodesAsComingSoonNotAnError() throws {
        let json = #"{"id":"x","displayName":"X","status":"hologram","connected":false,"accounts":[]}"#
        let bank = try JSONDecoder().decode(Bank.self, from: Data(json.utf8))
        XCTAssertEqual(bank.status, .comingSoon,
                       "this build must not drop the whole banks array over a raw value a future build adds")
    }

    func testStatementStatusRoundTrips() throws {
        let bank = Bank(id: "privatbank", displayName: "ПриватБанк", status: .statement,
                        connected: false, accounts: [])
        let data = try JSONEncoder().encode(bank)
        XCTAssertEqual(try JSONDecoder().decode(Bank.self, from: data).status, .statement)
    }

    @MainActor
    func testPersistedStatusIsReconciledFromTheSeed() throws {
        let repo = MemoryRepository()
        // `connected: true` with a real account is the user's own data — the
        // persisted bank and the seed bank differ ONLY in `status`, so an
        // implementation that copied the whole seed `Bank` over the
        // persisted one (wiping connection state and accounts) would pass
        // just as happily as one that copies `status`/`displayName` alone.
        // Asserting both survive is what tells the two apart.
        try repo.save([Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                            connected: true, accounts: [Account(id: "acc1", suffix: "*1111", type: "black",
                                                                 currency: "UAH", balance: 100_00, creditLimit: nil)])],
                      as: "banks")
        let seed = SeedBundle(transactions: [],
                              banks: [Bank(id: "privatbank", displayName: "ПриватБанк",
                                           status: .statement, connected: false, accounts: [])],
                              categories: [], rules: [], receipts: [], productGroups: [])
        let store = AppStore(repository: repo, seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertEqual(store.banks.first?.status, .statement,
                       "status is the app's knowledge, not the user's data — the seed wins")
        XCTAssertEqual(store.banks.first?.connected, true,
                       "connected is the user's own data — the seed must not overwrite it")
        XCTAssertEqual(store.banks.first?.accounts.map(\.id), ["acc1"],
                       "accounts are the user's own data — the seed must not wipe them")
    }

    func testShippedSeedMarksPrivatbankAsStatement() throws {
        // Same loading call every other test in this file uses — the test
        // bundle is hosted by the app, so the main bundle's seed is in reach.
        let seed = try SeedLoader.load()
        XCTAssertEqual(seed.banks.first { $0.id == "privatbank" }?.status, .statement)
    }
}
