import XCTest
@testable import MonitorFinance

@MainActor
final class BackgroundRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)
    private let day: TimeInterval = 86_400

    private func account(_ id: String, _ pan: String) -> MonobankAccount {
        MonobankAccount(id: id, type: "black", currencyCode: 980, balance: 0,
                        creditLimit: 0, maskedPan: [pan])
    }

    private func tx(_ suffix: String, daysAgo: Int) -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(-Double(daysAgo) * day),
                    kind: .expense, category: "", merchant: "Продавець", amount: -1000,
                    cardSuffix: suffix, bankId: "monobank", receiptId: nil, splits: [],
                    resolution: .pending, suggestions: [],
                    externalId: UUID().uuidString, hold: false)
    }

    private let cards = [MonobankAccount(id: "a1", type: "black", currencyCode: 980,
                                         balance: 0, creditLimit: 0,
                                         maskedPan: ["000000******1111"]),
                         MonobankAccount(id: "a2", type: "white", currencyCode: 980,
                                         balance: 0, creditLimit: 0,
                                         maskedPan: ["000000******2222"])]

    /// Named for what it asserts. "Most recent activity" said the opposite —
    /// the card with the newest row LOSES here — and would send the next
    /// reader to fix a bug that does not exist.
    func testTheCardWithTheMostRowsWinsNotTheNewestRow() {
        let rows = (0..<10).map { _ in tx("*2222", daysAgo: 10) } + [tx("*1111", daysAgo: 1)]
        XCTAssertEqual(BackgroundRefresh.busiestAccount(rows, accounts: cards, now: now), "a2",
                       "busiest means most rows in the window, not the newest row")
    }

    /// Rows older than the window must not decide today's one request.
    func testOnlyTheLastNinetyDaysCount() {
        let rows = (0..<50).map { _ in tx("*2222", daysAgo: 200) } + [tx("*1111", daysAgo: 3)]
        XCTAssertEqual(BackgroundRefresh.busiestAccount(rows, accounts: cards, now: now), "a1")
    }

    func testWithNoHistoryItStillPicksAnAccountRatherThanNothing() {
        XCTAssertEqual(BackgroundRefresh.busiestAccount([], accounts: cards, now: now), "a1")
    }

    func testWithNoAccountsThereIsNothingToPick() {
        XCTAssertNil(BackgroundRefresh.busiestAccount([tx("*1111", daysAgo: 1)],
                                                      accounts: [], now: now))
    }

    func testTiesAreBrokenStablyByAccountOrder() {
        let rows = [tx("*1111", daysAgo: 1), tx("*2222", daysAgo: 1)]
        XCTAssertEqual(BackgroundRefresh.busiestAccount(rows, accounts: cards, now: now), "a1")
    }

    // MARK: what the wake tells iOS it achieved

    /// `setTaskCompleted(success: true)` ran unconditionally, including when
    /// the expiration handler cancelled the work and nothing was fetched. iOS
    /// budgets future wakes on that answer, so a wake that lied about being
    /// productive costs the app the wakes it actually needs.
    /// The receipt half is `.idle` and the email half is `nil` throughout
    /// this test, so every assertion here is exercising the SYNC half alone,
    /// exactly as it did before `wasProductive` grew a second and third
    /// argument.
    func testAWakeThatSpentItsOneRequestCountsAsProductive() {
        // `maxSteps: 1` is exactly how this wake is bounded, so hitting the
        // budget is the INTENDED end of a wake that worked.
        XCTAssertTrue(BackgroundRefresh.wasProductive(.stopped(.budget), .idle, nil))
        XCTAssertTrue(BackgroundRefresh.wasProductive(.completed, .idle, nil))
        // Nothing was due. Asking was still correct.
        XCTAssertTrue(BackgroundRefresh.wasProductive(.idle, .idle, nil))
    }

    func testAWakeThatFetchedNothingIsReportedAsSuch() {
        for stop: SyncEngine.Stop in [.cancelled, .offline, .rateLimited, .noToken,
                                      .needsReconnect, .invalidToken, .malformed, .stalled] {
            XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(stop), .idle, nil),
                           "\(stop.rawValue) fetched nothing")
        }
    }

    /// A wake that fetched no new purchase but landed two receipts did work.
    /// Reporting it as unproductive teaches iOS to grant fewer wakes, which
    /// costs the app exactly the wakes the receipt queue depends on.
    func testAWakeThatOnlyLandedReceiptsIsStillProductive() {
        XCTAssertTrue(BackgroundRefresh.wasProductive(.idle, .drained(2), nil))
        XCTAssertTrue(BackgroundRefresh.wasProductive(.stopped(.budget), .idle, nil))
        XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(.offline), .idle, nil))
        // Standing down is not an achievement; it is the endpoint saying stop.
        XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(.offline), .stoodDown, nil))
        // The assertion above this one that actually isolates the receipt
        // half: `.idle` on the sync side is ALREADY productive on its own
        // (see `testAWakeThatSpentItsOneRequestCountsAsProductive`), so the
        // brief's own first assertion here (sync `.idle` + receipts
        // `.drained(2)`) stays true even if the second argument is ignored
        // entirely — proven by hand, mutating `wasProductive` to `return
        // syncDidWork` left this whole suite green. Pairing `.drained` with
        // a sync outcome that is NOT independently productive is what
        // actually proves the receipt half is weighed at all.
        XCTAssertTrue(BackgroundRefresh.wasProductive(.stopped(.offline), .drained(2), nil),
                      "a wake whose sync failed outright must still count as productive if receipts landed")
        // `.drained(0)` is reachable — `ReceiptFetcher.run` returns it when
        // its own re-entrancy guard trips — and must NOT read as productive:
        // review found `case .drained: receiptsDidWork = true` (dropping the
        // count) left every other assertion here green.
        XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(.offline), .drained(0), nil),
                       "a drain that fetched nothing is not an achievement, whatever the sync half did")
    }

    /// The email half, mirrored against the receipt test above: an
    /// email-only user has no monobank token, so `SyncEngine.run` reports
    /// `.stopped(.noToken)` — independently unproductive — and the receipt
    /// queue is `.idle` throughout since there is nothing there to drain.
    /// Isolating both other halves this way is what actually proves the
    /// email half is weighed, not merely accepted as an unused argument —
    /// the same shape review used to catch `wasProductive` discarding it.
    func testAWakeThatOnlyImportedEmailIsStillProductive() {
        XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(.noToken), .idle, nil),
                       "no email result and an unproductive sync must not read as productive")
        XCTAssertTrue(BackgroundRefresh.wasProductive(.stopped(.noToken), .idle, (imported: 3, merged: 0)),
                      "a wake whose sync had no token must still count as productive if email imported rows")
        // Merges alone — every emailed row already matched a statement row —
        // are not an achievement the way an empty receipt drain is not: the
        // work was the statement import's, already counted there.
        XCTAssertFalse(BackgroundRefresh.wasProductive(.stopped(.noToken), .idle, (imported: 0, merged: 4)),
                       "rows that merely merged into existing rows are not new work, whatever the sync half did")
    }
}
