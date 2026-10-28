import XCTest
@testable import MonitorFinance

/// A clock the injected `sleep` advances. Stage 1's Critical survived 410
/// green tests because its clock did not: with time stopped, a component
/// that never makes progress looks identical to one that does. Every test
/// below reads `now` through `syncNow` and advances it only through
/// `advance`, so a pacing assertion here is testing time actually passing,
/// not a frozen constant.
private actor TestClock {
    private(set) var now: Date
    /// `ReceiptFetcher.Dependencies.now` is `() -> Date` — synchronous,
    /// because the actor cannot `await` its own state from inside a plain
    /// closure. Mirrored here so that closure has something to read without
    /// awaiting: written only from `init`/`advance`, both of which already
    /// run one at a time on this actor, and read only from `ReceiptFetcher`,
    /// which — being a single actor itself — never has two requests in
    /// flight to race the read against. Strict concurrency is OFF for this
    /// target; this is the `nonisolated(unsafe)` box the task brief allows
    /// in place of turning it on.
    private nonisolated(unsafe) var unsafeNow: Date

    init(_ start: Date) {
        now = start
        unsafeNow = start
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        unsafeNow = now
    }

    nonisolated var syncNow: Date { unsafeNow }
}

/// A scriptable tax cabinet. Answers a script of outcomes in order, then a
/// fixed fallback once the script runs out; records every request it saw.
/// `onRequest`, when supplied, fires before the outcome is chosen — the
/// pacing test uses it to record when each request actually landed.
private actor RecordingAPI: TaxCabinetAPI {
    private(set) var calls: [FiscalCheck] = []
    private var script: [Result<ParsedCheck, TaxCabinetError>]
    private var fallback: Result<ParsedCheck, TaxCabinetError>
    private let onRequest: (() async -> Void)?

    init(script: [Result<ParsedCheck, TaxCabinetError>] = [],
         fallback: Result<ParsedCheck, TaxCabinetError> = .success(RecordingAPI.placeholder),
         onRequest: (() async -> Void)? = nil) {
        self.script = script
        self.fallback = fallback
        self.onRequest = onRequest
    }

    static let placeholder = ParsedCheck(registerModel: "ND-1", fiscalTotal: 100_00,
                                         fiscalTime: nil, mac: nil, lines: [])

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        calls.append(check)
        await onRequest?()
        let outcome = script.isEmpty ? fallback : script.removeFirst()
        switch outcome {
        case .success(let parsed): return parsed
        case .failure(let error): throw error
        }
    }
}

/// Collects what `commit` and `fail` were called with.
private actor ResultSink {
    private(set) var committed: [(id: UUID, parsed: ParsedCheck)] = []
    private(set) var failed: [(id: UUID, error: TaxCabinetError)] = []

    func recordCommit(_ id: UUID, _ parsed: ParsedCheck) { committed.append((id, parsed)) }
    func recordFail(_ id: UUID, _ error: TaxCabinetError) { failed.append((id, error)) }
}

/// Like `ResultSink`, but parks the run INSIDE its first `commit` until the
/// test releases it — so a cancellation issued after `waitForFirst()`
/// returns is guaranteed to be visible before `run` reaches its next
/// `Task.isCancelled` check, rather than racing it. Modelled on
/// `SyncStoreTests.GatedAPI`.
private actor CommitGate {
    private(set) var committed: [(id: UUID, parsed: ParsedCheck)] = []
    private var firstArrived: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func recordCommit(_ id: UUID, _ parsed: ParsedCheck) async {
        committed.append((id, parsed))
        if committed.count == 1 {
            firstArrived?.resume()
            firstArrived = nil
            await withCheckedContinuation { release = $0 }
        }
    }

    /// Returns once the first commit has landed.
    func waitForFirst() async {
        guard committed.isEmpty else { return }
        await withCheckedContinuation { firstArrived = $0 }
    }

    /// Lets a `recordCommit` parked above continue.
    func letGo() { release?.resume(); release = nil }
}

final class ReceiptFetcherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_756_800_000)

    private func check(document: String, sum: Int = 100_00, at: Date? = nil) -> FiscalCheck {
        FiscalCheck(registerNumber: "3000000001", documentNumber: document,
                   fiscalTime: at ?? start, fiscalSum: sum, mac: nil)
    }

    private func pending(_ document: String, sum: Int = 100_00,
                         scannedAt: Date? = nil, nextAttempt: Date? = nil) -> PendingReceipt {
        PendingReceipt(receiptId: UUID(), check: check(document: document, sum: sum),
                       scannedAt: scannedAt ?? start, attempts: 0,
                       nextAttempt: nextAttempt ?? start, lastError: nil)
    }

    private func parsed(sum: Int = 100_00) -> ParsedCheck {
        ParsedCheck(registerModel: "ND-1", fiscalTotal: sum, fiscalTime: nil, mac: nil, lines: [])
    }

    // MARK: draining

    func testEachDueReceiptIsFetchedOnceAndCommitted() async {
        // Distinct sums so a pairing bug (the wrong `ParsedCheck` landing on
        // the wrong receipt id) is something this test can actually catch.
        let a = pending("A", sum: 111_00), b = pending("B", sum: 222_00)
        let api = RecordingAPI(script: [.success(parsed(sum: 111_00)), .success(parsed(sum: 222_00))])
        let sink = ResultSink()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a, b] },
            commit: { id, parsed in await sink.recordCommit(id, parsed) },
            fail: { id, error in await sink.recordFail(id, error) })

        let outcome = await ReceiptFetcher(deps).run()

        XCTAssertEqual(outcome, .drained(2))
        let committed = await sink.committed
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed.first { $0.id == a.receiptId }?.parsed.fiscalTotal, 111_00)
        XCTAssertEqual(committed.first { $0.id == b.receiptId }?.parsed.fiscalTotal, 222_00)
        let calls = await api.calls
        XCTAssertEqual(calls.count, 2, "each due receipt asked for exactly once")
        let failed = await sink.failed
        XCTAssertTrue(failed.isEmpty)
    }

    func testAnEmptyQueueIsIdleAndMakesNoRequest() async {
        let api = RecordingAPI()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [] }, commit: { _, _ in }, fail: { _, _ in })

        let outcome = await ReceiptFetcher(deps).run()

        XCTAssertEqual(outcome, .idle)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty, "an idle queue must not touch the network at all")
    }

    // MARK: pacing — the point of this task

    /// Written against a clock that MOVES, per the brief: with the pacer
    /// stubbed out or the clock frozen, three requests land at the same
    /// instant and this must fail. Proven by hand per the task brief's step
    /// 5 — removing `ReceiptFetcher.pace`'s wait entirely and rerunning this
    /// test — rather than pinned as a second, redundant permanent test.
    func testRequestsAreSpacedByAtLeastThreeSeconds() async {
        let a = pending("A"), b = pending("B"), c = pending("C")
        let clock = TestClock(start)
        var requestTimes: [Date] = []
        let api = RecordingAPI(onRequest: { requestTimes.append(clock.syncNow) })
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a, b, c] }, commit: { _, _ in }, fail: { _, _ in })

        let outcome = await ReceiptFetcher(deps).run()

        XCTAssertEqual(outcome, .drained(3))
        XCTAssertEqual(requestTimes.count, 3)
        for (earlier, later) in zip(requestTimes, requestTimes.dropFirst()) {
            let gap = later.timeIntervalSince(earlier)
            XCTAssertGreaterThanOrEqual(gap, ReceiptFetcher.pace,
                                        "an endpoint with no published rate limit gets the benefit of the doubt")
            // Without an upper bound, a pacer that waited an hour between
            // every receipt would also satisfy this test.
            XCTAssertLessThan(gap, ReceiptFetcher.pace * 2, "must not over-wait either")
        }
    }

    // MARK: failures that must not be dropped

    func testNotPublishedIsReportedAsAFailureRatherThanADrop() async {
        let a = pending("A")
        let api = RecordingAPI(fallback: .failure(.notPublished))
        let sink = ResultSink()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a] },
            commit: { id, parsed in await sink.recordCommit(id, parsed) },
            fail: { id, error in await sink.recordFail(id, error) })

        let outcome = await ReceiptFetcher(deps).run()

        XCTAssertEqual(outcome, .drained(1), "a failure is still a receipt the run got an answer about")
        let committed = await sink.committed
        XCTAssertTrue(committed.isEmpty, "must never be reported as a commit")
        let failed = await sink.failed
        XCTAssertEqual(failed.map(\.id), [a.receiptId])
        XCTAssertEqual(failed.map(\.error), [.notPublished])
    }

    // MARK: throttled — the whole queue stands down

    func testAThrottledBodyStandsTheWholeQueueDownForAnHour() async {
        let a = pending("A"), b = pending("B")
        let api = RecordingAPI(fallback: .failure(.throttled))
        let sink = ResultSink()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a, b] },
            commit: { id, parsed in await sink.recordCommit(id, parsed) },
            fail: { id, error in await sink.recordFail(id, error) })

        let outcome = await ReceiptFetcher(deps).run()

        XCTAssertEqual(outcome, .stoodDown)
        let calls = await api.calls
        XCTAssertEqual(calls.count, 1, "the second receipt must never be asked for once the first throttles")
        let committed = await sink.committed
        let failed = await sink.failed
        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(failed.isEmpty, "throttling is the app's own pacing, not a fact about this document")
    }

    /// Pins the stand-down's duration in BOTH directions: still standing
    /// down the instant before the hour is up, and actually asking again the
    /// instant after — the last assertion is the load-bearing one. Without
    /// it a permanent stand-down (`standDownUntil` checked but never cleared
    /// against `now`, e.g. `if standDownUntil != nil { return .stoodDown }`)
    /// would pass a test that only ever advanced the clock a little way into
    /// the hour, because everything from 61 s to forever would satisfy it —
    /// found by review, which named the exact mutation.
    func testTheStandDownSurvivesASecondCallInsideTheHourButLiftsAfterIt() async {
        let a = pending("A")
        // First call throttles; once the stand-down lifts, the second call
        // must be free to actually fetch — scripted to succeed so a
        // `.stoodDown` outcome here cannot be confused with the queue simply
        // throttling again.
        let api = RecordingAPI(script: [.failure(.throttled)], fallback: .success(parsed()))
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a] }, commit: { _, _ in }, fail: { _, _ in })
        let fetcher = ReceiptFetcher(deps)

        let first = await fetcher.run()
        XCTAssertEqual(first, .stoodDown)
        let callsAfterFirst = await api.calls
        XCTAssertEqual(callsAfterFirst.count, 1)

        // A foreground call a while later, still well inside the hour.
        await clock.advance(60)
        let stillInside = await fetcher.run()
        XCTAssertEqual(stillInside, .stoodDown, "the stand-down is actor state — a later call must not walk past it")
        let callsStillInside = await api.calls
        XCTAssertEqual(callsStillInside.count, 1, "no new request may have been sent yet")

        // Walk right up to the boundary: still inside a second before it
        // lapses, then just past it.
        await clock.advance(ReceiptFetcher.standDownFor - 60 - 1)
        let justBefore = await fetcher.run()
        XCTAssertEqual(justBefore, .stoodDown, "the hour has not fully elapsed yet")

        await clock.advance(2)
        let afterTheHour = await fetcher.run()
        XCTAssertNotEqual(afterTheHour, .stoodDown, "the hour lapsed — the queue must be askable again")
        let callsAfterTheHour = await api.calls
        XCTAssertEqual(callsAfterTheHour.count, 2, "and a request must actually have gone out this time")
    }

    // MARK: re-entrancy on a shared instance

    /// An actor serializes its own state mutations but NOT its calls — two
    /// `run()` invocations on the same fetcher interleave freely at every
    /// `await` inside it, so without an explicit guard both would read
    /// `due()` before either advanced `lastRequest` and each would fetch
    /// every receipt: found by review, which sent two concurrent `run()`s at
    /// one fetcher and got every receipt fetched twice, at identical
    /// instants, zero spacing apart.
    ///
    /// Gated rather than fired as two bare `async let`s: an earlier version
    /// of this test did that and flaked under load. The diagnosis was "bad
    /// test, not a real race" — `guard !inFlight else { … }` followed by
    /// `inFlight = true` has no suspension point between them, so whichever
    /// `run()` the actor picks up first is guaranteed to set the flag before
    /// the other can observe it, which is a language guarantee, not
    /// scheduler luck. The flake was that nothing FORCED the second call to
    /// reach the actor while the first was still in flight: with
    /// `TestClock.advance` a mock that never really sleeps, a fully-scheduled
    /// `run()` can finish in microseconds, so under contention the second
    /// call's first actor hop could land AFTER the first had already
    /// returned and its `defer { inFlight = false }` had fired — at which
    /// point the second call legitimately performed its own full drain,
    /// giving exactly the flaky signature (`calls.count == 4`, two
    /// `.drained(2)`s). Parking the first call provably mid-request, the
    /// same pattern `CommitGate`/`ErrorGateAPI` already use in this file,
    /// removes the dependency on ambient scheduling entirely.
    func testConcurrentRunsOnOneFetcherDoNotDoubleFetch() async {
        let a = pending("A")
        let api = ConcurrencyGateAPI()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a] }, commit: { _, _ in }, fail: { _, _ in })
        let fetcher = ReceiptFetcher(deps)

        let firstTask = Task { await fetcher.run() }
        // Returns only once the first call is parked inside `check` —
        // provably mid-request, not hoped-for interleaving.
        await api.waitForRequest()

        let second = await fetcher.run()
        XCTAssertEqual(second, .drained(0), "must find the pacer already owned and make no request of its own")
        let callsWhileFirstIsParked = await api.calls
        XCTAssertEqual(callsWhileFirstIsParked.count, 1, "the second call must never have reached the network at all")

        await api.letGo()
        let first = await firstTask.value

        XCTAssertEqual(first, .drained(1))
        let callsTotal = await api.calls
        XCTAssertEqual(callsTotal.count, 1, "exactly one drain's worth of requests, start to finish")
    }

    // MARK: budget

    func testMaxRequestsBoundsAWakeToWhatItCanAfford() async {
        let pendings = ["A", "B", "C", "D", "E"].map { pending($0) }
        let api = RecordingAPI()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { pendings }, commit: { _, _ in }, fail: { _, _ in })

        let outcome = await ReceiptFetcher(deps).run(maxRequests: 2)

        XCTAssertEqual(outcome, .drained(2))
        let calls = await api.calls
        XCTAssertEqual(calls.count, 2, "a background wake must stop at its budget, not exhaust the queue")
    }

    // MARK: cancellation

    func testCancellationStopsBetweenRequestsWithoutLosingCommittedWork() async {
        let a = pending("A"), b = pending("B")
        let api = RecordingAPI()
        let gate = CommitGate()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a, b] },
            commit: { id, parsed in await gate.recordCommit(id, parsed) },
            fail: { _, _ in })

        let task = Task { await ReceiptFetcher(deps).run() }
        // Parked inside the first `commit` — cancelling now is guaranteed to
        // be visible before `run` reaches its next `Task.isCancelled` check,
        // rather than racing it.
        await gate.waitForFirst()
        task.cancel()
        await gate.letGo()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        let committed = await gate.committed
        XCTAssertEqual(committed.map(\.id), [a.receiptId], "the first commit must not be lost to the cancellation")
        let calls = await api.calls
        XCTAssertEqual(calls.count, 1, "the second receipt must never have been asked for")
    }

    /// The shape a wake's expiration actually produces: `TaxCabinetClient`
    /// wraps EVERY error `URLSession` can throw — including the one a
    /// cancelled `Task` produces — as `TaxCabinetError.offline`, so a
    /// cancellation arriving mid-request looks, to `run`'s error handling,
    /// identical to a real network failure unless it checks `Task.isCancelled`
    /// itself. Parks INSIDE the request (unlike the test above, which parks
    /// inside a successful `commit`) so the cancellation is guaranteed to
    /// land before the `.offline` error is thrown, not race it.
    func testACancellationDuringTheRequestItselfDoesNotChargeABackoff() async {
        let a = pending("A")
        let api = ErrorGateAPI()
        let sink = ResultSink()
        let clock = TestClock(start)
        let deps = ReceiptFetcher.Dependencies(
            api: api, now: { clock.syncNow }, sleep: { await clock.advance($0) },
            due: { [a] },
            commit: { id, parsed in await sink.recordCommit(id, parsed) },
            fail: { id, error in await sink.recordFail(id, error) })

        let task = Task { await ReceiptFetcher(deps).run() }
        await api.waitForRequest()
        task.cancel()
        await api.letGo()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        let failed = await sink.failed
        XCTAssertTrue(failed.isEmpty,
                      "a request cancelled mid-flight must not charge the receipt a backoff advance for a question it never got an answer to")
        let committed = await sink.committed
        XCTAssertTrue(committed.isEmpty)
    }
}

/// A tax cabinet that parks before answering with an ERROR — mirrors
/// `CommitGate`, but for the failure path: `TaxCabinetClient.check` wraps
/// every `URLSession` error, cancellation included, as
/// `TaxCabinetError.offline`, so this is what a request cancelled mid-flight
/// actually produces once it resumes.
private actor ErrorGateAPI: TaxCabinetAPI {
    private var arrived: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didCall = false

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        didCall = true
        arrived?.resume()
        arrived = nil
        await withCheckedContinuation { release = $0 }
        throw TaxCabinetError.offline("cancelled")
    }

    func waitForRequest() async {
        guard !didCall else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func letGo() { release?.resume(); release = nil }
}

/// A tax cabinet that parks INSIDE `check` until the test releases it, then
/// answers successfully — the re-entrancy test's own gate, kept separate
/// from `ErrorGateAPI` (which always fails once released) so a passing
/// `.drained(1)` after release cannot be confused with the cancellation
/// path's `.cancelled`.
///
/// Only the FIRST call parks. A second call reaching the network while the
/// first is still parked is exactly the defect `testConcurrentRunsOnOneFetcherDoNotDoubleFetch`
/// exists to catch, and it is answered immediately rather than parked too:
/// this type only has room for one waiting `release` continuation, so
/// parking a second call would silently overwrite the first's and strand it
/// forever. Answering immediately instead means a missing `inFlight` guard
/// makes the test's own assertions fail fast and cleanly — extra entries in
/// `calls`, a `second` outcome other than `.drained(0)` — rather than
/// hanging the whole run indefinitely. Found the hard way: an earlier
/// version of this gate parked every call, and removing the guard to check
/// this test still catches the defect just hung the test suite instead of
/// reddening it.
private actor ConcurrencyGateAPI: TaxCabinetAPI {
    private(set) var calls: [FiscalCheck] = []
    private var arrived: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var parked = false

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        calls.append(check)
        guard !parked else { return RecordingAPI.placeholder }
        parked = true
        arrived?.resume()
        arrived = nil
        await withCheckedContinuation { release = $0 }
        return RecordingAPI.placeholder
    }

    /// Returns once a request is parked inside `check`.
    func waitForRequest() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func letGo() { release?.resume(); release = nil }
}
