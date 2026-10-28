import Foundation

/// Decides what to fetch and when, paces it at one request per 61 s, and stops
/// cleanly on every failure monobank can produce.
///
/// It never touches `AppStore`. Rows and the cursor advance leave through
/// `commit`, which the store performs together on the main actor — rows
/// written without the cursor mean a re-fetch; a cursor moved without the rows
/// means a permanent, silent hole.
actor SyncEngine {

    struct Dependencies {
        var api: MonobankAPI
        var now: () -> Date
        var sleep: (TimeInterval) async throws -> Void
        var token: () async -> String?
        var accounts: () async -> [MonobankAccount]
        var state: () async -> SyncState
        var commit: ([Transaction], SyncPlan.Step, Bool) async -> Void
        var markReconnect: () async -> Void
    }

    /// `String`-backed so `AppStore` can persist the last one in `sync.json`
    /// and `SyncStatusView` can explain it after the fact — see `userMessage`.
    /// A raw value it does not recognise (written by a newer build, read by an
    /// older one) simply fails `init(rawValue:)` and produces no line, rather
    /// than making the whole file undecodable.
    enum Stop: String, Equatable, Error {
        case noToken, needsReconnect, invalidToken, rateLimited
        case offline, malformed, cancelled, budget, stalled
    }
    enum Outcome: Equatable { case idle, completed, stopped(Stop) }

    private let deps: Dependencies
    private var lastRequest: Date?

    init(_ deps: Dependencies) { self.deps = deps }

    /// `maxSteps` is a *time* budget in disguise: a background wake gets about
    /// 30 s of runtime and the pacing interval is 61, so a wake asks for one
    /// window and stops.
    func run(maxSteps: Int = .max) async -> Outcome {
        guard let token = await deps.token(), !token.isEmpty else { return .stopped(.noToken) }
        guard await !deps.state().needsReconnect else { return .stopped(.needsReconnect) }

        let accounts = (await deps.accounts()).filter { $0.currencyCode == 980 }
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var done = 0
        // Per-run only — not actor state. Accounts already walked up to the
        // present during THIS run. A forward window for an account that is up
        // to date ends at `now`, and the engine then waits one pacing interval
        // before asking again — which is exactly `minForwardGap`, so without
        // this the planner would hand back a forward step for the same account
        // on every iteration and the backfill would never be reached.
        //
        // Membership is decided HERE rather than in the planner because only
        // the caller knows which `now` the window was planned against: an
        // account three months behind needs several 31-day hops, and it must
        // keep qualifying until one of them lands on the present. A background
        // wake starts with this empty, so its single request still goes on the
        // forward window.
        var forwarded: Set<String> = []

        while true {
            if Task.isCancelled { return .stopped(.cancelled) }
            let state = await deps.state()
            let plannedAt = deps.now()
            guard let step = SyncPlan.next(state: state, accounts: accounts.map(\.id),
                                           now: plannedAt, forwarded: forwarded) else {
                return done == 0 ? .idle : .completed
            }
            guard done < maxSteps else { return .stopped(.budget) }

            let (id, from, to) = Self.unpack(step)
            guard let account = byId[id] else { return .stopped(.malformed) }
            let cursorBefore = state.cursors[id]

            switch await fetch(token: token, account: account, from: from, to: to) {
            case .success(let items):
                let rows = items.map { MonobankMapper.transaction($0, account: account) }
                await deps.commit(rows, step, items.isEmpty)
                done += 1
                // `to == plannedAt` exactly when the window reached the
                // present: the planner builds it as `min(from + window, now)`.
                // A window that stopped short leaves the account out, so it
                // gets another hop.
                if case .forward = step, to >= plannedAt { forwarded.insert(id) }
                // Watch the cursor, not the step. Every step carries `to`,
                // which is derived from `deps.now()`, so against a real clock
                // two consecutive steps are never equal and a step-comparing
                // guard can never fire. A correct commit always moves the
                // cursor — forward raises `newest`, backward lowers `oldest`
                // — so a cursor that came back unchanged means the commit
                // callback advanced nothing, which is a stall, not progress.
                if await deps.state().cursors[id] == cursorBefore {
                    return .stopped(.stalled)
                }
            case .failure(.invalidToken):
                await deps.markReconnect()
                return .stopped(.invalidToken)
            case .failure(.rateLimited):   return .stopped(.rateLimited)
            case .failure(.malformed):     return .stopped(.malformed)
            case .failure(.cancelled):     return .stopped(.cancelled)
            default:                       return .stopped(.offline)
            }
        }
    }

    /// One window, paced, with up to three attempts against a 429.
    private func fetch(token: String, account: MonobankAccount,
                       from: Date, to: Date) async -> Result<[MonobankStatementItem], Stop> {
        for attempt in 0..<3 {
            do { try await pace() } catch { return .failure(.cancelled) }
            do {
                let rows = try await deps.api.statement(token: token, accountId: account.id,
                                                        from: from, to: to)
                lastRequest = deps.now()
                return .success(rows)
            } catch MonobankError.rateLimited {
                lastRequest = deps.now()
                if attempt == 2 { return .failure(.rateLimited) }
            } catch MonobankError.invalidToken {
                return .failure(.invalidToken)
            } catch MonobankError.malformed {
                return .failure(.malformed)
            } catch {
                return .failure(.offline)
            }
        }
        return .failure(.rateLimited)
    }

    /// Keeps statement requests 61 s apart. The first of a run goes at once.
    private func pace() async throws {
        guard let last = lastRequest else { return }
        let wait = SyncPlan.pace - deps.now().timeIntervalSince(last)
        guard wait > 0 else { return }
        try await deps.sleep(wait)
    }

    private static func unpack(_ step: SyncPlan.Step) -> (String, Date, Date) {
        switch step {
        case .forward(let a, let f, let t), .backward(let a, let f, let t): return (a, f, t)
        }
    }
}

extension SyncEngine.Stop {
    /// What the user is told when a run ended this way — or `nil` when there
    /// is nothing worth saying, which is most of them.
    ///
    /// FIXED STRINGS, never anything the bank sent. `MonobankError.server`
    /// carries up to 200 bytes of whatever came back in the response body, and
    /// `MonobankError.offline`/`.malformed` carry `localizedDescription` and a
    /// decoder dump; none of that reaches here, because `SyncEngine.fetch`
    /// already maps every one of them onto a payload-free `Stop`. Keeping this
    /// mapping payload-free is what keeps a bank response out of a view, a log
    /// and a notification.
    ///
    /// The silent ones, and why:
    /// - `.budget` is the NORMAL end of a bounded run — pull-to-refresh and
    ///   every background wake ask for one window and stop, and so does a
    ///   `startSync` that found another already in flight. It is not a failure.
    /// - `.cancelled` is the app going to the background mid-window.
    /// - `.needsReconnect` and `.invalidToken` are the reconnect line's job;
    ///   two messages about the same token would contradict each other.
    var userMessage: String? {
        switch self {
        case .offline:      return "Немає зв'язку з monobank — потягніть, щоб оновити"
        case .rateLimited:  return "monobank просить зачекати — спробуємо ще раз згодом"
        case .malformed:    return "monobank відповів незрозуміло — спробуємо ще раз згодом"
        case .stalled:      return "Завантаження зупинилося — потягніть, щоб оновити"
        case .noToken:      return "Токен monobank не знайдено — підключіть банк заново"
        case .budget, .cancelled, .needsReconnect, .invalidToken: return nil
        }
    }
}
