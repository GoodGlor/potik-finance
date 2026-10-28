import XCTest
@testable import MonitorFinance

final class SyncPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)   // 2025-09-02 UTC
    private let day: TimeInterval = 86_400

    private func state(_ cursors: [String: SyncState.Cursor], depth: Int = 3) -> SyncState {
        var s = SyncState(); s.cursors = cursors; s.depthMonths = depth; return s
    }

    // MARK: Codable robustness

    /// A `sync.json` written by an older build is missing whatever field was
    /// added since. Swift's synthesised Codable would throw `keyNotFound` and
    /// the app would silently restart a 31-minute backfill.
    func testAnEmptyObjectDecodesToDefaults() throws {
        let s = try SeedLoader.decoder.decode(SyncState.self, from: Data("{}".utf8))
        XCTAssertEqual(s.depthMonths, 3)
        XCTAssertTrue(s.cursors.isEmpty)
        XCTAssertFalse(s.needsReconnect)
        XCTAssertNil(s.clientHash)
        XCTAssertFalse(s.seedCleared)
    }

    func testAPartialCursorDecodes() throws {
        let json = #"{"cursors":{"a":{"newest":"2026-08-01T00:00:00Z"}},"depthMonths":6}"#
        let s = try SeedLoader.decoder.decode(SyncState.self, from: Data(json.utf8))
        XCTAssertEqual(s.depthMonths, 6)
        XCTAssertNotNil(s.cursors["a"]?.newest)
        XCTAssertNil(s.cursors["a"]?.oldest)
        XCTAssertEqual(s.cursors["a"]?.emptyStreak, 0)
        XCTAssertEqual(s.cursors["a"]?.exhausted, false)
    }

    func testItRoundTrips() throws {
        var s = SyncState()
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day, exhausted: false, emptyStreak: 1)
        s.depthMonths = 12; s.clientHash = "abc"; s.seedCleared = true
        let back = try SeedLoader.decoder.decode(
            SyncState.self, from: SeedLoader.encoder.encode(s))
        XCTAssertEqual(back, s)
    }

    func testTheLastStopDefaultsToNothingAndSurvivesARoundTrip() throws {
        let fresh = try SeedLoader.decoder.decode(SyncState.self, from: Data("{}".utf8))
        XCTAssertNil(fresh.lastStop, "a sync.json written before this field must still decode")
        var s = SyncState()
        s.lastStop = SyncEngine.Stop.offline.rawValue
        let back = try SeedLoader.decoder.decode(
            SyncState.self, from: SeedLoader.encoder.encode(s))
        XCTAssertEqual(back.lastStop, "offline")
    }

    // MARK: what the depth screen promises

    /// `SyncPlan.estimate` is the only thing between the user and a wrong
    /// promise on the depth screen: one request per account per month, the
    /// first of them free because the pacer lets it go immediately.
    func testTheEstimateChargesForEveryWindowButTheFirst() {
        // One month, one card — a single request, which goes at once.
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 1, accounts: 1), 0)
        // Three months on two cards: six windows, five of them paced.
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 3, accounts: 2), 5 * SyncPlan.pace)
        // A year on two cards — the longest offer on the screen.
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 12, accounts: 2), 23 * SyncPlan.pace)
    }

    /// Two degenerate inputs that must not produce a negative promise.
    /// `max(0, windows - 1)` is what stops «Усе, що є» and a bank with no UAH
    /// card from underflowing into a negative `TimeInterval`.
    func testTheEstimateNeverGoesNegative() {
        // No accounts at all: nothing to ask, nothing to wait for.
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 12, accounts: 0), 0)
        // Depth 0 is «Усе, що є», which has no planned total — `totalWindows`
        // falls back to one window per account. The screen never shows this
        // number (see the test below), but it must not be negative.
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 0, accounts: 2), SyncPlan.pace)
    }

    /// The words on the screen, not just the seconds behind them.
    /// `@MainActor` because `SyncDepthView` is a `View`.
    @MainActor
    func testTheDepthScreenRefusesToPromiseAnEndForEverythingThereIs() {
        XCTAssertEqual(SyncDepthView.estimate(0, 2, .uk), "поки не закінчиться")
        XCTAssertEqual(SyncDepthView.estimate(1, 1, .uk), "майже одразу")
        XCTAssertTrue(SyncDepthView.estimate(12, 2, .uk).hasPrefix("≈ "),
                      "a long backfill must be offered as an estimate, not as a fact")
    }

    // MARK: first run

    func testAFreshAccountAsksForTheLast31DaysForward() {
        let step = SyncPlan.next(state: state([:]), accounts: ["a"], now: now)
        XCTAssertEqual(step, .forward(account: "a", from: now - 31 * day, to: now))
    }

    func testEveryAccountGetsItsForwardWindowBeforeAnyBackfill() {
        var s = state([:])
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day, exhausted: false, emptyStreak: 0)
        // "b" has never been fetched, so it must come before backfilling "a".
        let step = SyncPlan.next(state: s, accounts: ["a", "b"], now: now)
        XCTAssertEqual(step, .forward(account: "b", from: now - 31 * day, to: now))
    }

    /// The Critical, at the planner's own level. `minForwardGap` is exactly one
    /// pacing interval and the engine waits exactly one pacing interval between
    /// requests, so a cursor written at the top of a run is `minForwardGap`
    /// stale by the time the planner is next asked: without `forwarded`, this
    /// is `.forward` again, forever, and the backfill below is unreachable.
    func testAnAccountAlreadyCaughtUpThisRunIsNotAskedForwardAgain() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now - SyncPlan.pace, oldest: now - 31 * day,
                               exhausted: false, emptyStreak: 0)
        guard case .backward = SyncPlan.next(state: s, accounts: ["a"], now: now,
                                             forwarded: ["a"]) else {
            return XCTFail("an account caught up this run must yield to the backfill")
        }
    }

    /// The other side of it: `forwarded` names accounts the ENGINE saw reach the
    /// present, so an account that has never been fetched at all is unaffected
    /// even if some other account is done.
    func testForwardedOnlySilencesTheAccountsItNames() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day,
                               exhausted: false, emptyStreak: 0)
        XCTAssertEqual(SyncPlan.next(state: s, accounts: ["a", "b"], now: now, forwarded: ["a"]),
                       .forward(account: "b", from: now - 31 * day, to: now))
    }

    /// Ruling 2 from the pre-flight scan. Without the staleness floor the
    /// planner returns `.forward` for the first account forever and the
    /// backfill is unreachable — with every other test in this file still green.
    func testAJustFetchedAccountIsNotAskedForwardAgain() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day, exhausted: false, emptyStreak: 0)
        guard case .backward = SyncPlan.next(state: s, accounts: ["a"], now: now) else {
            return XCTFail("a cursor fetched a moment ago must not be fetched forward again")
        }
    }

    func testOnceItIsAPacingIntervalStaleItIsAskedForwardAgain() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now - SyncPlan.minForwardGap, oldest: now - 31 * day,
                               exhausted: false, emptyStreak: 0)
        guard case .forward = SyncPlan.next(state: s, accounts: ["a"], now: now) else {
            return XCTFail("expected a forward step")
        }
    }

    // MARK: the settlement overlap

    /// A held row's amount changes when it settles. A forward window that
    /// starts exactly where the last one ended would never look at it again.
    func testAForwardWindowReachesThreeDaysBackBehindTheCursor() {
        var s = state([:])
        s.cursors["a"] = .init(newest: now - day, oldest: now - 31 * day,
                               exhausted: true, emptyStreak: 0)
        XCTAssertEqual(SyncPlan.next(state: s, accounts: ["a"], now: now),
                       .forward(account: "a", from: now - 4 * day, to: now))
    }

    func testALongAbsenceIsWalkedForwardInWindowsRatherThanLeavingAHole() {
        var s = state([:])
        s.cursors["a"] = .init(newest: now - 100 * day, oldest: now - 200 * day,
                               exhausted: true, emptyStreak: 0)
        let step = SyncPlan.next(state: s, accounts: ["a"], now: now)
        // from = newest − 3d overlap; to = from + 31d, NOT `now`.
        XCTAssertEqual(step, .forward(account: "a",
                                      from: now - 103 * day, to: now - 72 * day))
    }

    /// A device whose clock ran ahead parks `newest` in the future. Read at
    /// face value, `now.timeIntervalSince(newest)` is negative for the whole
    /// length of the skew — and clamping `newest` to `now` only makes it zero —
    /// so this account silently stops syncing forward for the rest of that
    /// week. A cursor in the future is not information; the only safe reading
    /// is to fetch the last window and let the commit clamp it back.
    func testACursorFromAClockThatRanAheadDoesNotFreezeForwardSync() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now + 7 * day, oldest: now - 31 * day,
                               exhausted: true, emptyStreak: 0)
        XCTAssertEqual(SyncPlan.next(state: s, accounts: ["a"], now: now),
                       .forward(account: "a", from: now - 31 * day, to: now))
        // And it is still only one window per run, not one per iteration.
        XCTAssertNil(SyncPlan.next(state: s, accounts: ["a"], now: now, forwarded: ["a"]))
    }

    // MARK: backfill

    func testWithForwardDoneItWalksBackwardsOneWindow() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day,
                               exhausted: false, emptyStreak: 0)
        XCTAssertEqual(SyncPlan.next(state: s, accounts: ["a"], now: now),
                       .backward(account: "a", from: now - 62 * day, to: now - 31 * day))
    }

    func testTheShallowestAccountIsDeepenedFirst() {
        var s = state([:], depth: 12)
        s.cursors["a"] = .init(newest: now, oldest: now - 90 * day, exhausted: false, emptyStreak: 0)
        s.cursors["b"] = .init(newest: now, oldest: now - 31 * day, exhausted: false, emptyStreak: 0)
        guard case .backward(let account, _, _) =
                SyncPlan.next(state: s, accounts: ["a", "b"], now: now) else {
            return XCTFail("expected a backward step")
        }
        XCTAssertEqual(account, "b", "b has the least history, so b is deepened")
    }

    func testABackwardWindowIsClampedToTheChosenDepth() {
        var s = state([:], depth: 3)
        let floor = SyncPlan.depthFloor(depthMonths: 3, now: now)!
        s.cursors["a"] = .init(newest: now, oldest: floor + 5 * day,
                               exhausted: false, emptyStreak: 0)
        XCTAssertEqual(SyncPlan.next(state: s, accounts: ["a"], now: now),
                       .backward(account: "a", from: floor, to: floor + 5 * day))
    }

    func testNothingIsPlannedOnceEveryCursorIsExhausted() {
        var s = state([:])
        s.cursors["a"] = .init(newest: now, oldest: now - 31 * day,
                               exhausted: true, emptyStreak: 0)
        XCTAssertNil(SyncPlan.next(state: s, accounts: ["a"], now: now))
    }

    func testDepthZeroHasNoFloor() {
        XCTAssertNil(SyncPlan.depthFloor(depthMonths: 0, now: now))
        var s = state([:], depth: 0)
        s.cursors["a"] = .init(newest: now, oldest: now - 3650 * day,
                               exhausted: false, emptyStreak: 0)
        XCTAssertNotNil(SyncPlan.next(state: s, accounts: ["a"], now: now),
                        "«Усе, що є» stops on empty windows, never on a date")
    }

    func testAnAccountWithNoCursorIsNotPlannedIfItIsNotInTheAccountList() {
        var s = state([:])
        s.cursors["gone"] = .init(newest: nil, oldest: nil, exhausted: false, emptyStreak: 0)
        XCTAssertNil(SyncPlan.next(state: s, accounts: [], now: now))
    }

    // MARK: the estimate the depth screen shows

    func testTheEstimateIsWindowsTimesAccountsLessTheFirstImmediateRequest() {
        XCTAssertEqual(SyncPlan.totalWindows(depthMonths: 3, accounts: 4), 12)
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 3, accounts: 4), 11 * 61)
        XCTAssertEqual(SyncPlan.estimate(depthMonths: 1, accounts: 1), 0)
    }
}
