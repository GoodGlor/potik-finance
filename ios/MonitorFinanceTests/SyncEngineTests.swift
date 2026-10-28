import XCTest
@testable import MonitorFinance

/// A scriptable bank. Records what was asked; answers from a queue.
actor FakeMonobankAPI: MonobankAPI {
    struct Call: Equatable { let accountId: String; let from: Date; let to: Date }
    private(set) var calls: [Call] = []
    private var answers: [Result<[MonobankStatementItem], MonobankError>] = []
    private var fallback: [MonobankStatementItem] = []

    func script(_ answers: [Result<[MonobankStatementItem], MonobankError>]) { self.answers = answers }
    func setFallback(_ rows: [MonobankStatementItem]) { fallback = rows }
    func recorded() -> [Call] { calls }

    func clientInfo(token: String) async throws -> MonobankClientInfo {
        MonobankClientInfo(clientId: "c", name: "n", accounts: [])
    }

    func statement(token: String, accountId: String,
                   from: Date, to: Date) async throws -> [MonobankStatementItem] {
        calls.append(Call(accountId: accountId, from: from, to: to))
        guard !answers.isEmpty else { return fallback }
        switch answers.removeFirst() {
        case .success(let rows): return rows
        case .failure(let error): throw error
        }
    }
}

/// A clock that MOVES. `sleep` advances it by exactly the interval it was
/// asked to wait, which is what the real pacer does, and `now` reads it.
///
/// The frozen `{ self.now }` this replaces is why a whole test file agreed
/// with a planner that could never terminate: with `now` never advancing, a
/// just-fetched cursor never became `minForwardGap` stale, so the forward
/// branch stopped qualifying and the backfill was reached — in the tests only.
/// A test that cannot observe time passing cannot test a pacer.
final class VirtualClock {
    private(set) var now: Date
    /// Kept so the pacing assertions still have something to look at.
    private(set) var slept: [TimeInterval] = []

    init(_ start: Date) { now = start }

    func sleep(_ interval: TimeInterval) {
        slept.append(interval)
        now += interval
    }
}

/// Collects what the engine committed, and plays the role of the store's
/// cursor bookkeeping so the run loop actually advances.
final class RecordingSink {
    var state = SyncState()
    var committed: [(rows: [Transaction], step: SyncPlan.Step, empty: Bool)] = []
    var reconnectCalls = 0

    func commit(_ rows: [Transaction], _ step: SyncPlan.Step, _ empty: Bool) {
        committed.append((rows, step, empty))
        switch step {
        case .forward(let a, let from, let to):
            var c = state.cursors[a] ?? SyncState.Cursor()
            c.newest = to
            c.oldest = min(c.oldest ?? from, from)
            state.cursors[a] = c
        case .backward(let a, let from, _):
            var c = state.cursors[a] ?? SyncState.Cursor()
            c.oldest = from
            c.exhausted = true          // one backward step is enough for these tests
            state.cursors[a] = c
        }
    }
}

final class SyncEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)
    private let uah = MonobankAccount(id: "a1", type: "black", currencyCode: 980,
                                      balance: 0, creditLimit: 0,
                                      maskedPan: ["000000******1111"])
    /// A second UAH card, so "one catch-up window per account" has more than
    /// one account to be true of.
    private let uah2 = MonobankAccount(id: "a2", type: "white", currencyCode: 980,
                                       balance: 0, creditLimit: 0,
                                       maskedPan: ["000000******3333"])
    private let usd = MonobankAccount(id: "a3", type: "white", currencyCode: 840,
                                      balance: 0, creditLimit: 0,
                                      maskedPan: ["000000******2222"])

    private func row(_ id: String, _ at: Date, _ amount: Int = -1000) -> MonobankStatementItem {
        MonobankStatementItem(id: id, time: Int(at.timeIntervalSince1970),
                              description: "Продавець", mcc: 5411, amount: amount,
                              operationAmount: nil, currencyCode: 980,
                              commissionRate: 0, cashbackAmount: 0, balance: nil,
                              hold: false, monoReceiptId: nil, counterName: nil)
    }

    private func engine(api: FakeMonobankAPI, sink: RecordingSink,
                        accounts: [MonobankAccount],
                        token: String? = "tok",
                        clock: VirtualClock? = nil) -> SyncEngine {
        let clock = clock ?? VirtualClock(now)
        return SyncEngine(.init(
            api: api,
            now: { clock.now },
            sleep: { clock.sleep($0) },
            token: { token },
            accounts: { accounts },
            state: { sink.state },
            commit: { rows, step, empty in await MainActor.run { sink.commit(rows, step, empty) } },
            markReconnect: { await MainActor.run { sink.reconnectCalls += 1 } }))
    }

    func testNoTokenStopsBeforeAnyRequest() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        let outcome = await engine(api: api, sink: sink, accounts: [uah], token: nil).run()
        XCTAssertEqual(outcome, .stopped(.noToken))
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }

    func testNeedsReconnectStopsBeforeAnyRequest() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        sink.state.needsReconnect = true
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .stopped(.needsReconnect))
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }

    /// D9. `Transaction` has no currency and every total sums blindly, so a
    /// foreign card must never be fetched at all.
    func testOnlyUAHAccountsAreEverAskedFor() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        _ = await engine(api: api, sink: sink, accounts: [uah, usd]).run(maxSteps: 4)
        let asked = Set((await api.recorded()).map(\.accountId))
        XCTAssertEqual(asked, ["a1"])
    }

    func testTheFirstRequestIsImmediateAndLaterOnesArePaced() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        let clock = VirtualClock(now)
        sink.state.depthMonths = 3
        _ = await engine(api: api, sink: sink, accounts: [uah], clock: clock).run(maxSteps: 2)
        XCTAssertEqual(clock.slept.count, 1, "one gap between two requests")
        XCTAssertEqual(clock.slept.first, SyncPlan.pace)
    }

    func testForwardIsFetchedBeforeAnyBackfill() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        sink.state.depthMonths = 12
        _ = await engine(api: api, sink: sink, accounts: [uah]).run(maxSteps: 2)
        let calls = await api.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].to, now, "first request must reach `now`")
        XCTAssertLessThan(calls[1].to, now, "second must be the backfill")
    }

    func testRowsAreMappedAndCommittedWithTheirStep() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.success([row("r1", now - 3600), row("r2", now - 7200)])])
        await api.setFallback([])
        _ = await engine(api: api, sink: sink, accounts: [uah]).run(maxSteps: 1)
        XCTAssertEqual(sink.committed.count, 1)
        XCTAssertEqual(sink.committed[0].rows.map(\.externalId), ["r1", "r2"])
        XCTAssertEqual(sink.committed[0].rows[0].cardSuffix, "*1111")
        XCTAssertFalse(sink.committed[0].empty)
        if case .forward = sink.committed[0].step {} else { XCTFail("expected a forward step") }
    }

    func testAnEmptyWindowIsCommittedAsEmptySoTheStreakCanCount() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        _ = await engine(api: api, sink: sink, accounts: [uah]).run(maxSteps: 1)
        XCTAssertTrue(sink.committed[0].empty)
        XCTAssertTrue(sink.committed[0].rows.isEmpty)
    }

    func test403MarksReconnectAndCommitsNothing() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.failure(.invalidToken)])
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .stopped(.invalidToken))
        XCTAssertEqual(sink.reconnectCalls, 1)
        XCTAssertTrue(sink.committed.isEmpty, "existing data must be untouched")
    }

    func test429IsRetriedAfterABackoffAndThenSucceeds() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.failure(.rateLimited), .success([row("r1", now - 60)])])
        await api.setFallback([])
        let clock = VirtualClock(now)
        _ = await engine(api: api, sink: sink, accounts: [uah], clock: clock).run(maxSteps: 1)
        XCTAssertEqual(sink.committed.count, 1)
        XCTAssertEqual(sink.committed[0].rows.map(\.externalId), ["r1"])
        XCTAssertTrue(clock.slept.contains(SyncPlan.pace), "it must wait before retrying")
    }

    func test429ThreeTimesGivesUpWithoutCommitting() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.failure(.rateLimited), .failure(.rateLimited), .failure(.rateLimited)])
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .stopped(.rateLimited))
        XCTAssertTrue(sink.committed.isEmpty)
    }

    /// A shape we cannot read must not become a silent hole: the cursor stays
    /// where it was, so the same window is asked for again next run.
    func testMalformedStopsWithoutAdvancingTheCursor() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.failure(.malformed("bad"))])
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .stopped(.malformed))
        XCTAssertTrue(sink.committed.isEmpty)
        XCTAssertTrue(sink.state.cursors.isEmpty)
    }

    func testOfflineStopsQuietly() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.script([.failure(.offline("no route"))])
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .stopped(.offline))
    }

    /// A background wake gets ~30 s of runtime and monobank makes us wait 61,
    /// so a wake spends its budget on exactly one request.
    func testMaxStepsIsHonoured() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        sink.state.depthMonths = 12
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run(maxSteps: 1)
        XCTAssertEqual(outcome, .stopped(.budget))
        let calls = await api.recorded()
        XCTAssertEqual(calls.count, 1)
    }

    func testNothingLeftToDoIsIdleRatherThanAnError() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        sink.state.depthMonths = 1
        sink.state.cursors["a1"] = .init(newest: now, oldest: now - 31 * 86_400,
                                         exhausted: true, emptyStreak: 0)
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run()
        XCTAssertEqual(outcome, .idle)
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }

    /// If the injected `commit` fails to advance the cursor, the window it just
    /// paid a minute for was thrown away. With the default (unbounded)
    /// `maxSteps` that means a request to monobank every 61 s, indefinitely.
    /// The engine must refuse to spin on that itself, rather than trusting
    /// every caller to remember a bound.
    ///
    /// The guard watches the CURSOR, not the step: a step carries `to`, which
    /// comes from `deps.now()`, so with a clock that moves two consecutive
    /// steps are never equal and a step-comparing guard is dead code. This test
    /// uses a moving clock precisely so it cannot pass for that reason.
    func testACommitThatNeverAdvancesTheCursorStopsInsteadOfLoopingForever() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        let clock = VirtualClock(now)
        let outcome = await SyncEngine(.init(
            api: api,
            now: { clock.now },
            sleep: { clock.sleep($0) },
            token: { "tok" },
            accounts: { [self.uah] },
            state: { sink.state },
            commit: { rows, step, empty in
                // Deliberately does not update `sink.state`: the rows are
                // recorded, but nothing about the cursor advances.
                await MainActor.run { sink.committed.append((rows, step, empty)) }
            },
            markReconnect: { await MainActor.run { sink.reconnectCalls += 1 } }
        )).run()
        XCTAssertEqual(outcome, .stopped(.stalled))
        let calls = await api.recorded()
        XCTAssertEqual(calls.count, 1, "the stall is visible the moment the first commit returns")
    }

    // MARK: time actually passing

    /// The regression test for the Critical. `minForwardGap` is one pacing
    /// interval and the engine waits exactly one pacing interval between
    /// requests, so an account whose forward window ended at `now` was stale
    /// again by the time the planner was next asked: `.forward` won on every
    /// iteration, the backward branch below it was unreachable, `next` never
    /// returned `nil`, and `run` never left its `while true`. On a device that
    /// meant the chosen depth never arrived, `isSyncing` stayed pinned true for
    /// the life of the process, and the app asked monobank for the same window
    /// once a minute forever.
    ///
    /// Every engine test froze the clock, so the whole file agreed with it.
    func testARunWithARealClockFinishesInsteadOfFetchingForwardForever() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        sink.state.depthMonths = 12
        let clock = VirtualClock(now)
        let outcome = await engine(api: api, sink: sink, accounts: [uah, uah2],
                                   clock: clock).run(maxSteps: 200)

        XCTAssertEqual(outcome, .completed, "the run must reach the end of its work")
        let steps = sink.committed.map(\.step)
        XCTAssertTrue(steps.contains { if case .backward = $0 { return true }; return false },
                      "the backfill must be reached at all")
        for id in ["a1", "a2"] {
            XCTAssertEqual(steps.filter { step in
                if case .forward(let a, _, _) = step { return a == id }
                return false
            }.count, 1, "one catch-up window per account per run (\(id))")
        }
        XCTAssertGreaterThan(clock.now, now, "the clock must have moved, or this proves nothing")
    }

    /// The other half of the same rule, and the reason the `forwarded` set is
    /// not simply "never plan forward twice": an account nobody opened for
    /// three months needs SEVERAL 31-day forward hops before it reaches today,
    /// and every one of them must happen in this run or the gap is permanent.
    /// A window that stops short of `now` keeps qualifying; only one that
    /// reaches `now` is spent.
    func testAnAccountLeftFarBehindKeepsGettingForwardWindowsUntilItCatchesUp() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        sink.state.depthMonths = 12
        // Exhausted, so nothing here can be mistaken for backfill progress.
        sink.state.cursors["a1"] = .init(newest: now - 100 * 86_400,
                                         oldest: now - 100 * 86_400,
                                         exhausted: true, emptyStreak: 0)
        let clock = VirtualClock(now)
        let outcome = await engine(api: api, sink: sink, accounts: [uah],
                                   clock: clock).run(maxSteps: 200)

        XCTAssertEqual(outcome, .completed)
        let forwards = sink.committed.compactMap { committed -> Date? in
            if case .forward(_, _, let to) = committed.step { return to }
            return nil
        }
        // 100 days behind, 31 days a window, each hop giving back 3 days to the
        // settlement overlap: four windows to get from -100d to the present.
        XCTAssertEqual(forwards.count, 4, "a long absence is walked forward in 31-day hops")
        XCTAssertGreaterThan(forwards.last!, now,
                             "the last window must reach the present, not stop one hop short")
        XCTAssertEqual(sink.state.cursors["a1"]?.newest, forwards.last)
    }

    /// A background wake gets one request. `forwarded` starts empty on every
    /// run, so that request still goes on today's purchases rather than on a
    /// three-month-old backfill window — the whole reason forward is planned
    /// first.
    func testABackgroundWakeStillSpendsItsOneRequestOnTheForwardWindow() async {
        let api = FakeMonobankAPI(), sink = RecordingSink()
        await api.setFallback([])
        sink.state.depthMonths = 12
        sink.state.cursors["a1"] = .init(newest: now - 2 * SyncPlan.pace,
                                         oldest: now - 31 * 86_400,
                                         exhausted: false, emptyStreak: 0)
        let outcome = await engine(api: api, sink: sink, accounts: [uah]).run(maxSteps: 1)
        XCTAssertEqual(outcome, .stopped(.budget))
        XCTAssertEqual(sink.committed.count, 1)
        guard case .forward(_, _, let to) = sink.committed[0].step else {
            return XCTFail("a wake must spend its single request going forward")
        }
        XCTAssertEqual(to, now, "and that window must reach the present")
    }

    // MARK: what a stop is allowed to tell the user

    /// The standing rule: nothing monobank said ever reaches a view.
    /// `MonobankError.server` carries up to 200 bytes of response body,
    /// `.offline` carries `localizedDescription` and `.malformed` a decoder
    /// dump — and every one of them is mapped onto a payload-free `Stop`
    /// before it can leave the engine. This is the assertion that keeps it
    /// that way: a `Stop` case with an associated value would not compile
    /// against `String`'s raw representation, and a message built from one
    /// would fail here.
    func testEveryStopWorthReportingHasAFixedMessageOfItsOwn() {
        let reported: [SyncEngine.Stop] = [.offline, .rateLimited, .malformed, .stalled, .noToken]
        let messages = reported.compactMap(\.userMessage)
        XCTAssertEqual(messages.count, reported.count, "each of these must say something")
        XCTAssertEqual(Set(messages).count, reported.count, "and something different")
        for message in messages {
            XCTAssertFalse(message.contains("boom"), "no bank text may appear in a message")
            XCTAssertTrue(message.contains("monobank") || message.contains("Завантаження")
                          || message.contains("Токен"),
                          "the message must name what failed: \(message)")
        }
    }

    /// The ordinary ends of a run. `.budget` is how pull-to-refresh and every
    /// background wake finish; `.cancelled` is the app backgrounding
    /// mid-window; the two token stops are the reconnect line's job, and a
    /// second message about the same token would contradict it.
    func testTheOrdinaryEndsOfARunSayNothing() {
        for stop: SyncEngine.Stop in [.budget, .cancelled, .needsReconnect, .invalidToken] {
            XCTAssertNil(stop.userMessage, "\(stop.rawValue) is not a failure to report")
        }
    }

    /// `sync.json` stores the raw value, so an older build reading a file a
    /// newer one wrote must fall back to silence rather than throwing — which
    /// would make the whole file undecodable and restart a half-hour backfill.
    func testAnUnrecognisedStoredStopIsSilentRatherThanFatal() {
        XCTAssertNil(SyncEngine.Stop(rawValue: "somethingNewer"))
        XCTAssertEqual(SyncEngine.Stop(rawValue: "offline"), .offline)
    }
}
