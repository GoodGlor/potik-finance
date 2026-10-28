import Foundation

/// Drains the queue of receipts waiting for their goods from the tax
/// cabinet's public lookup, paced against an endpoint with no documented
/// rate limit and no rate-limit headers. Model and discipline follow
/// `SyncEngine.swift`, one host over.
///
/// It never touches `AppStore`. A receipt's items and its removal from the
/// queue leave together through `commit`, which the store performs on the
/// main actor — items written without the removal mean re-fetching an
/// immutable document; a removal without the items means goods nobody will
/// ever see. `fail` never removes a queue entry; it only advances the
/// backoff, so a receipt that fails today is still reachable to retry
/// tomorrow — never orphaned, attached to nothing and unreachable.
actor ReceiptFetcher {

    struct Dependencies {
        var api: TaxCabinetAPI
        var now: () -> Date
        var sleep: (TimeInterval) async throws -> Void
        var due: () async -> [PendingReceipt]
        var commit: (UUID, ParsedCheck) async -> Void
        var fail: (UUID, TaxCabinetError) async -> Void
    }

    enum Outcome: Equatable { case idle, drained(Int), stoodDown, cancelled }

    /// At least this long between two requests to the tax cabinet. The first
    /// of a run goes at once. Same shape as `SyncPlan.pace`, a different
    /// number for a different host that has never told us its own.
    static let pace: TimeInterval = 3

    /// How long a `.throttled` body stands the WHOLE queue down for, not
    /// just the one receipt that triggered it. The endpoint sends no
    /// `Retry-After`, so an hour is a guess, made generous on purpose for an
    /// endpoint that has just shown it does not want to be asked again soon.
    static let standDownFor: TimeInterval = 3600

    private let deps: Dependencies
    /// One engine for the process, not one per call — as `AppStore.startSync`
    /// documents for its own: a fresh actor per call starts with no
    /// `lastRequest` and fires immediately, so two callers a second apart
    /// would send two requests back to back.
    private var lastRequest: Date?
    /// `nil` until a `.throttled` body is seen. ACTOR STATE, not a local of
    /// `run`, and read at the very top of it — so a foreground call a minute
    /// after the last stand-down does not walk straight past it and fire
    /// another request into the same hour the endpoint asked us to sit out.
    ///
    /// Cleared BACK to `nil` only after `deps.now()` has actually moved past
    /// it (see the top of `run`) — never unconditionally on every call — so
    /// the duration is enforced in both directions: still stood down the
    /// instant before it lapses, askable again the instant after. Found by
    /// review: a version that merely checked `standDownUntil != nil` (never
    /// clearing it, never comparing it to `now`) passed every test that
    /// existed at the time, and would have killed receipt fetching for the
    /// rest of the process on the first HTML error page.
    private var standDownUntil: Date?
    /// Guards against re-entrancy on a SHARED instance. An actor serializes
    /// its own state mutations, but it does not serialize CALLS — two
    /// `await fetcher.run()` invocations from two different tasks interleave
    /// freely at every `await` inside this method, so without this flag both
    /// would read `due()` before either advanced `lastRequest`, and each
    /// would fetch every receipt: found by review sending two concurrent
    /// `run()`s at one fetcher and getting every receipt fetched twice, at
    /// identical instants, zero spacing, with each failure double-advancing
    /// its own backoff. `AppStore.startSync` has the same shape but is
    /// guarded caller-side by `guard !isSyncing`; this flag makes the
    /// guarantee the actor's OWN, so a caller that reaches `run` by some path
    /// other than a future store entry point (a background wake, say) still
    /// cannot double-drain the queue. A caller-side guard, if one is added
    /// later, is belt-and-braces on top of this — not the only defence.
    private var inFlight = false

    init(_ deps: Dependencies) { self.deps = deps }

    /// `maxRequests` is a *time* budget in disguise, the same way
    /// `SyncEngine`'s `maxSteps` is: a background wake gets about 30 s of
    /// runtime and the pacing interval here is 3 s, so a wake affords on the
    /// order of ten receipts before it must stop.
    func run(maxRequests: Int = .max) async -> Outcome {
        guard !inFlight else { return .drained(0) }   // another run already owns the pacer
        inFlight = true
        defer { inFlight = false }

        if let until = standDownUntil, deps.now() < until { return .stoodDown }
        // The stand-down has lapsed (or there never was one); a fresh
        // `.throttled` sighting below can still re-arm it.
        standDownUntil = nil

        let pending = await deps.due()
        guard !pending.isEmpty else { return .idle }

        var drained = 0
        for receipt in pending {
            if Task.isCancelled { return .cancelled }
            guard drained < maxRequests else { break }

            do { try await pace() } catch { return .cancelled }

            do {
                let parsed = try await deps.api.check(receipt.check)
                lastRequest = deps.now()
                await deps.commit(receipt.receiptId, parsed)
                drained += 1
            } catch TaxCabinetError.throttled {
                lastRequest = deps.now()
                // Stands the whole queue down — everything else `due`
                // handed back this run, fetched or not, waits out the hour
                // too. Nothing here calls `fail`: this is the app asking too
                // often, not a fact about this particular document, and
                // charging it against the receipt's own backoff would be
                // unfair to a document that may well have published.
                standDownUntil = deps.now().addingTimeInterval(Self.standDownFor)
                return .stoodDown
            } catch let error as TaxCabinetError {
                // A wake's expiration handler cancels this run's `Task` from
                // outside; `TaxCabinetClient` wraps that same cancellation as
                // `.offline` (it catches everything `URLSession` throws), so
                // it arrives here indistinguishable from a real network
                // failure UNLESS this checks `Task.isCancelled` itself. Found
                // by review: without this, an expired wake's in-flight
                // request charged the receipt a real backoff advance (up to
                // three hours) for a question it never got an actual answer
                // to.
                guard !Task.isCancelled else { return .cancelled }
                lastRequest = deps.now()
                await deps.fail(receipt.receiptId, error)
                drained += 1
            } catch {
                // Not one of ours — surface it the same way `SyncEngine.fetch`
                // folds an unrecognised error into `.offline` rather than
                // letting it escape unhandled. Same cancellation guard as the
                // branch above, for the same reason.
                guard !Task.isCancelled else { return .cancelled }
                lastRequest = deps.now()
                await deps.fail(receipt.receiptId, .offline(error.localizedDescription))
                drained += 1
            }
        }
        return .drained(drained)
    }

    /// Keeps requests `pace` apart. Throws only when `deps.sleep` does —
    /// i.e. when the wait was cancelled — so `run` can fold that into
    /// `.cancelled` exactly where `SyncEngine.fetch` folds its own pacer's
    /// cancellation.
    private func pace() async throws {
        guard let last = lastRequest else { return }
        let wait = Self.pace - deps.now().timeIntervalSince(last)
        guard wait > 0 else { return }
        try await deps.sleep(wait)
    }
}
