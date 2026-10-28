import XCTest
@testable import MonitorFinance

/// Board #148 — the list of imported statements, and the two-way delete.
///
/// The owner asked for both halves and for the choice to be theirs: «ask the
/// user whether to delete just the file or with transactions». So there are
/// two operations here, not one with a flag, and the interesting one is the
/// second: **it must remove only the rows the statement CREATED.**
///
/// A purchase the notification letters already delivered is merged into the
/// letter's row rather than added (`PrivatCrossSource`, in `applyStatement`).
/// That row existed before the file and would still exist without it. Taking
/// it would mean "delete the statement I imported by mistake" quietly deletes
/// history that arrived by email — which is the one outcome this feature must
/// never produce.
@MainActor
final class StatementImportTests: XCTestCase {
    private var sample: Data { Data(base64Encoded: PrivatFixtureData.sampleBase64)! }

    private func makeStore(transactions: [Transaction] = []) -> AppStore {
        let seed = SeedBundle(
            transactions: transactions,
            banks: [Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                         connected: false, accounts: [])],
            categories: [], rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func statementRow(amountMinor: Int = -12_550, balanceMinor: Int = 903_450,
                              date: Date = .init(timeIntervalSince1970: 1_780_000_000))
    -> PrivatRow {
        PrivatRow(date: date, category: "", cardSuffix: "*2299",
                  descriptionText: "Супермаркет Тест-Маркет, м. Вигадане",
                  amountMinor: amountMinor, currency: "UAH",
                  balanceMinor: balanceMinor, balanceCurrency: "UAH")
    }

    private func statement(_ rows: [PrivatRow]) -> PrivatStatement {
        PrivatStatement(rows: rows, skippedNonUAH: 0, period: nil)
    }

    // MARK: - the record

    func testAnImportIsRecordedUnderTheNameThePersonWillRecognise() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")

        let record = try XCTUnwrap(store.statementImports.last)
        XCTAssertEqual(record.filename, "виписка-серпень.xlsx")
        XCTAssertEqual(record.created.count, 12, "every row this file brought")
        XCTAssertEqual(record.merged, 0)
    }

    /// A re-import creates nothing and must still be recorded.
    ///
    /// "I imported that file and it was all already here" is an answer the
    /// list has to be able to give — an import that vanishes silently looks
    /// like one that failed.
    func testAReimportIsRecordedEvenThoughItAddedNothing() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")

        XCTAssertEqual(store.statementImports.count, 2)
        let second = try XCTUnwrap(store.statementImports.last)
        XCTAssertTrue(second.created.isEmpty, "it created nothing")
        XCTAssertEqual(second.merged, 12)
    }

    // MARK: - «Видалити лише файл»

    func testDeletingOnlyTheFileLeavesEveryTransaction() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")
        let record = try XCTUnwrap(store.statementImports.last)

        store.forgetStatementImport(record.id)

        XCTAssertTrue(store.statementImports.isEmpty, "the record is gone")
        XCTAssertEqual(store.transactions.count, 12,
                       "a statement is a delivery, not the data")
    }

    // MARK: - «Видалити разом з операціями»

    func testDeletingWithTransactionsRemovesTheRowsTheFileCreated() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")
        let record = try XCTUnwrap(store.statementImports.last)

        store.deleteStatementImport(record.id)

        XCTAssertTrue(store.statementImports.isEmpty)
        XCTAssertTrue(store.transactions.isEmpty, "all twelve came from that file")
    }

    /// **The test this whole feature turns on.**
    ///
    /// A row the statement MERGED into arrived by email first. Deleting the
    /// statement must leave it: it is not this file's row, and it would still
    /// be here had the file never been imported.
    func testARowTheStatementMergedIntoSurvivesTheDelete() throws {
        // A letter's row: the email identity, and the amount/balance pair that
        // `PrivatCrossSource` matches a statement row on.
        let letterRow = Transaction(
            id: UUID(), date: .init(timeIntervalSince1970: 1_780_000_000),
            kind: .expense, category: "", merchant: "Тест-Маркет",
            amount: -12_550, cardSuffix: "*2299", bankId: "privatbank",
            receiptId: nil, splits: [], resolution: .pending, suggestions: [],
            externalId: PrivatEmailMapper.externalIdPrefix + "user|7", hold: nil,
            balanceAfterMinor: 903_450)
        let store = makeStore(transactions: [letterRow])

        // The same purchase in a statement, plus one the statement alone has.
        let summary = store.applyStatement(
            statement([statementRow(),
                       statementRow(amountMinor: -40_000, balanceMinor: 863_450,
                                    date: .init(timeIntervalSince1970: 1_780_100_000))]),
            filename: "виписка-серпень.xlsx")
        XCTAssertEqual(summary.merged, 1, "the letter's row was merged into, not added")
        XCTAssertEqual(summary.imported, 1)

        let record = try XCTUnwrap(store.statementImports.last)
        XCTAssertEqual(record.created.count, 1,
                       "only the row the file brought into being is its own")
        XCTAssertFalse(record.created.contains(letterRow.id),
                       "a merged-into row is not this file's to delete")

        store.deleteStatementImport(record.id)

        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(store.transactions.first?.id, letterRow.id,
                       "the email's row survives; deleting a statement must not "
                       + "take history that came from somewhere else")
    }

    // MARK: - the cost, stated before the tap

    func testTheCostCountsRowsAndHowManyWereAlreadySorted() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")
        let record = try XCTUnwrap(store.statementImports.last)

        XCTAssertEqual(store.statementDeletionCost(record).rows, 12)

        // **Measured, not assumed.** An import does not leave every row
        // `.pending`: the rules and patterns run inside `ingestRows`, so some
        // of this fixture arrives already answered. Asserting a baseline of
        // zero here failed, and the honest fix is to take the baseline from
        // the store rather than to write a number into the test.
        let baseline = store.statementDeletionCost(record).decided

        // Two rows answered BY HAND — the work a delete would destroy, and the
        // number the confirmation has to say out loud before the tap.
        let stillOpen = record.created.filter { id in
            store.transactions.first { $0.id == id }?.resolution == .pending
        }.prefix(2)
        XCTAssertEqual(stillOpen.count, 2, "the fixture must leave something to answer")
        for id in stillOpen {
            if let i = store.transactions.firstIndex(where: { $0.id == id }) {
                store.transactions[i].resolution = .user
            }
        }
        XCTAssertEqual(store.statementDeletionCost(record).decided, baseline + 2)
    }

    /// A row deleted by hand is not a cost of deleting the statement.
    func testTheCostCountsOnlyRowsThatAreStillThere() throws {
        let store = makeStore()
        _ = try store.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")
        let record = try XCTUnwrap(store.statementImports.last)

        store.transactions.removeAll { $0.id == record.created[0] }

        XCTAssertEqual(store.statementDeletionCost(record).rows, 11)
    }

    // MARK: - it survives a relaunch

    func testTheListOutlivesTheProcess() throws {
        let repository = MemoryRepository()
        let seed = SeedBundle(
            transactions: [],
            banks: [Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                         connected: false, accounts: [])],
            categories: [], rules: [], receipts: [], productGroups: [])
        let service = "ua.monitorfinance.tests.\(UUID().uuidString)"

        let first = AppStore(repository: repository, seed: seed,
                             keychain: Keychain(service: service))
        _ = try first.importPrivatStatement(sample, filename: "виписка-серпень.xlsx")

        let second = AppStore(repository: repository, seed: seed,
                              keychain: Keychain(service: service))
        XCTAssertEqual(second.statementImports.count, 1)
        XCTAssertEqual(second.statementImports.first?.filename, "виписка-серпень.xlsx")
        XCTAssertEqual(second.statementImports.first?.created.count, 12,
                       "the ids have to survive too, or the undo cannot work")
    }
}
