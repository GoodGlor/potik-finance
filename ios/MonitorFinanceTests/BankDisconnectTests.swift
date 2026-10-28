import XCTest
@testable import MonitorFinance

/// Board #157 — disconnecting a bank asks whether its transactions go too.
///
/// The owner: «I think you need to ask the user when he deletes the bank
/// whether to delete transactions as well.» Keeping them stays the DEFAULT —
/// `disconnect`'s own comment has said «History stays — it is the user's, not
/// the bank's» from the beginning. What was missing was the other answer.
///
/// **The interesting assertion is what "the bank's transactions" means.** A
/// statement can answer that exactly, because `StatementImport.created` records
/// the ids one file brought into being; a bank has no such record. The card
/// weighed two readings and this file pins the one that was chosen, because the
/// wrong answer here is silent.
@MainActor
final class BankDisconnectTests: XCTestCase {

    private func makeStore(_ transactions: [Transaction]) -> AppStore {
        let seed = SeedBundle(
            transactions: transactions,
            banks: [Bank(id: "monobank", displayName: "monobank", status: .available,
                         connected: true, accounts: []),
                    Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                         connected: true, accounts: [])],
            categories: [], rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    /// Invented merchants, per the project's fixture rule — a seed merchant in
    /// Swift source is what the privacy guard exists to catch.
    private func row(_ bankId: String, _ resolution: Resolution = .pending) -> Transaction {
        Transaction(id: UUID(), date: .init(timeIntervalSince1970: 1_780_000_000),
                    kind: .expense, category: "", merchant: "Крамниця-Вигадана",
                    amount: -4_200, cardSuffix: "*1111", bankId: bankId,
                    receiptId: nil, splits: [], resolution: resolution, suggestions: [])
    }

    // MARK: the cost, stated before the tap

    func testTheCostCountsThisBanksRowsAndHowManyWereAlreadySorted() {
        let store = makeStore([row("monobank"), row("monobank", .user), row("monobank", .rule),
                               row("privatbank"), row("privatbank", .user)])

        let cost = store.bankDisconnectCost(bankId: "monobank")

        XCTAssertEqual(cost.rows, 3)
        XCTAssertEqual(cost.decided, 2, "a row already answered carries work no re-import returns")
        XCTAssertEqual(store.bankDisconnectCost(bankId: "privatbank").rows, 2,
                       "one bank's cost must not count another's rows")
    }

    /// A row deleted by hand is not a cost of doing this — the same rule
    /// `statementDeletionCost` follows.
    func testTheCostCountsOnlyRowsThatAreStillThere() {
        let store = makeStore([row("monobank"), row("monobank")])
        // The id is read BEFORE the mutation: `store.transactions[0]` inside
        // `removeAll`'s own closure is overlapping access to the same array,
        // and it does not fail an assertion — it traps, taking the rest of the
        // class's run with it.
        let byHand = store.transactions[0].id
        store.transactions.removeAll { $0.id == byHand }

        XCTAssertEqual(store.bankDisconnectCost(bankId: "monobank").rows, 1)
    }

    func testABankWithNoRowsCostsNothing() {
        let store = makeStore([row("privatbank")])
        let cost = store.bankDisconnectCost(bankId: "monobank")
        XCTAssertEqual(cost.rows, 0)
        XCTAssertEqual(cost.decided, 0)
    }

    // MARK: keeping them is still the default

    func testDisconnectingAloneLeavesEveryTransaction() {
        let store = makeStore([row("monobank"), row("monobank"), row("privatbank")])

        store.disconnect(bankId: "monobank")

        XCTAssertEqual(store.transactions.count, 3, "history is the user's, not the bank's")
        XCTAssertTrue(store.connectedBanks.allSatisfy { $0.id != "monobank" })
    }

    // MARK: removing them

    func testRemovingTakesThisBanksRowsAndNobodyElses() {
        let store = makeStore([row("monobank"), row("monobank"), row("privatbank")])

        store.removeTransactions(ofBank: "monobank")

        XCTAssertEqual(store.transactions.map(\.bankId), ["privatbank"])
    }

    /// **The decision the card demanded be pinned, with its cost stated.**
    ///
    /// A PrivatBank row can arrive by letter AND by statement — `applyStatement`
    /// merges them through `PrivatCrossSource` — so "everything with this
    /// bankId" takes rows a `StatementImport` also claims. That is deliberate.
    /// The alternative leaves a disconnected bank with transactions still in
    /// the feed, still carrying its `bankId`, and no screen anywhere offering
    /// to remove them: the person answered «разом з операціями» and the
    /// operations stayed.
    func testRemovingTakesRowsAStatementAlsoClaims() {
        let store = makeStore([row("privatbank"), row("privatbank")])
        let claimed = store.transactions.map(\.id)
        store.appendStatementImport(StatementImport(
            filename: "виписка-вигадана.xlsx", importedAt: .now,
            created: claimed, merged: 0, from: nil, to: nil))

        store.removeTransactions(ofBank: "privatbank")

        XCTAssertTrue(store.transactions.isEmpty)
    }

    /// The other half of that decision, and what keeps the two lists agreeing.
    ///
    /// A statement record whose rows are all gone would otherwise stay listed,
    /// offering «Видалити разом з операціями» for transactions that no longer
    /// exist — an undo that silently does nothing.
    func testAStatementLeftWithNoRowsStopsBeingListed() {
        let store = makeStore([row("privatbank")])
        store.appendStatementImport(StatementImport(
            filename: "виписка-вигадана.xlsx", importedAt: .now,
            created: store.transactions.map(\.id), merged: 0, from: nil, to: nil))

        store.removeTransactions(ofBank: "privatbank")

        XCTAssertTrue(store.statementImports.isEmpty,
                      "a record that can no longer undo anything must not offer to")
    }

    /// A record that still has SOME rows keeps its place — it can still undo
    /// those, and dropping it would lose a real undo.
    func testAStatementThatStillHasRowsSurvives() {
        let store = makeStore([row("privatbank"), row("monobank")])
        let mine = store.transactions.filter { $0.bankId == "privatbank" }.map(\.id)
        let theirs = store.transactions.filter { $0.bankId == "monobank" }.map(\.id)
        store.appendStatementImport(StatementImport(
            filename: "виписка-вигадана.xlsx", importedAt: .now,
            created: mine + theirs, merged: 0, from: nil, to: nil))

        store.removeTransactions(ofBank: "privatbank")

        XCTAssertEqual(store.statementImports.count, 1)
    }

    /// **`receiptQueue` is not touched, and board #148 learned this the
    /// expensive way.** Its entries are keyed by RECEIPT, not by transaction,
    /// so clearing them here would throw away receipts still waiting on the tax
    /// cabinet for their goods. A receipt whose transaction goes away becomes
    /// loose, which `matchLooseReceipts` already models.
    func testTheReceiptQueueIsLeftAlone() {
        let store = makeStore([row("monobank")])
        let before = store.receiptQueue

        store.removeTransactions(ofBank: "monobank")

        XCTAssertEqual(store.receiptQueue, before)
    }

    // MARK: board #166 — the door stops locking behind the person

    /// **The defect, stated as a requirement.** `BanksSettingsView` lists
    /// `connectedBanks`, so disconnecting removed the only row that led to the
    /// only screen offering «Відключити разом з операціями» — the choice was
    /// offered once, at the instant of disconnecting, and never again. The rows
    /// stayed in the feed, the queue, Home and statistics, and the only route
    /// left was «Скинути додаток».
    func testADisconnectedBankThatStillOwnsRowsIsListedAsPast() {
        let store = makeStore([row("monobank"), row("privatbank")])

        store.disconnect(bankId: "monobank")

        XCTAssertEqual(store.pastBanks.map(\.id), ["monobank"])
        XCTAssertFalse(store.connectedBanks.contains { $0.id == "monobank" },
                       "it is past, not connected — the two lists do not overlap")
    }

    /// Nothing to act on means nothing to open. Listing it anyway would grow
    /// the section forever into a museum of banks somebody once tried.
    func testADisconnectedBankWithNoRowsIsNotListed() {
        let store = makeStore([row("monobank")])

        store.disconnect(bankId: "monobank")
        store.removeTransactions(ofBank: "monobank")

        XCTAssertTrue(store.pastBanks.isEmpty)
    }

    /// A connected bank is never past, however many rows it owns — otherwise
    /// every bank would appear twice.
    func testAConnectedBankIsNeverPast() {
        let store = makeStore([row("monobank"), row("privatbank")])

        XCTAssertTrue(store.pastBanks.isEmpty)
    }

    /// The whole point of the section: from there, the rows can actually go —
    /// and the statements list is kept honest at the same time, exactly as
    /// `removeTransactions(ofBank:)` already does for the connected path.
    func testRemovingAPastBanksRowsAlsoPrunesItsEmptyStatements() {
        let store = makeStore([row("privatbank"), row("privatbank")])
        let mine = store.transactions.filter { $0.bankId == "privatbank" }.map(\.id)
        store.appendStatementImport(StatementImport(
            filename: "виписка-вигадана.xlsx", importedAt: .now,
            created: mine, merged: 0, from: nil, to: nil))
        store.disconnect(bankId: "privatbank")
        XCTAssertEqual(store.pastBanks.map(\.id), ["privatbank"])

        store.removeTransactions(ofBank: "privatbank")

        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertTrue(store.statementImports.isEmpty,
                      "a record whose rows are all gone cannot go on offering an undo")
        XCTAssertTrue(store.pastBanks.isEmpty,
                      "with nothing left to act on the row stops being listed")
    }
}
