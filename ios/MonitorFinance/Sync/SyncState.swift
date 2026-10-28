import Foundation

/// What sync remembers between launches. Persisted as `sync.json` through the
/// same `Repository` everything else uses.
struct SyncState: Codable, Hashable {

    struct Cursor: Codable, Hashable {
        /// Fetched forward up to here.
        var newest: Date?
        /// Walked backward down to here.
        var oldest: Date?
        /// Reached the chosen depth, or monobank has nothing older.
        var exhausted: Bool = false
        /// Consecutive empty backward windows. «Усе, що є» stops at two —
        /// one empty month is a quiet month, two in a row is the end.
        var emptyStreak: Int = 0

        init(newest: Date? = nil, oldest: Date? = nil,
             exhausted: Bool = false, emptyStreak: Int = 0) {
            self.newest = newest; self.oldest = oldest
            self.exhausted = exhausted; self.emptyStreak = emptyStreak
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            newest = try c.decodeIfPresent(Date.self, forKey: .newest)
            oldest = try c.decodeIfPresent(Date.self, forKey: .oldest)
            exhausted = try c.decodeIfPresent(Bool.self, forKey: .exhausted) ?? false
            emptyStreak = try c.decodeIfPresent(Int.self, forKey: .emptyStreak) ?? 0
        }
    }

    var cursors: [String: Cursor] = [:]
    /// 1, 3, 6, 12 — or 0 for «Усе, що є».
    var depthMonths: Int = 3
    /// A 403 was seen. Everything stops until the user pastes a new token.
    var needsReconnect: Bool = false
    /// SHA-256 of monobank's `clientId` — never the id itself. A mismatch
    /// means the pasted token belongs to a different person.
    var clientHash: String?
    var lastSuccess: Date?
    /// The one-time demo-data sweep has run. See `AppStore+Sync`.
    var seedCleared: Bool = false
    /// Why the last run stopped, as `SyncEngine.Stop`'s raw value — or `nil`
    /// when the last run had nothing to explain. Persisted, because the state
    /// it describes outlives the process: a first launch with no connectivity
    /// used to leave the app showing «Тут з'являться ваші покупки…» with no
    /// spinner, no error and no explanation, forever.
    ///
    /// A `String?` rather than the enum itself so a raw value written by a
    /// newer build cannot make `sync.json` undecodable — see `Stop`. Only stops
    /// with a `userMessage` are ever written; `.budget` and `.cancelled` are
    /// the ordinary end of a bounded or backgrounded run, not a failure.
    var lastStop: String?
    /// Insertion-order cursor into the email backend's /transactions — the
    /// backend's own row id, not a time. 0 = nothing consumed yet.
    var emailCursor: Int = 0
    /// A 401 was seen: the secret is wrong or the server account is gone.
    /// Email sync stops until the user re-registers (issue #91's screen).
    var emailNeedsReconnect: Bool = false
    /// Board #111. **This phone has been issued an address at some point**, and
    /// it lives HERE rather than in the Keychain precisely so it can outlive
    /// the credentials.
    ///
    /// The case it exists for is a restore onto a new phone. The secret is
    /// stored `…ThisDeviceOnly`, which is deliberately excluded from backups
    /// and iCloud Keychain, so a restore brings `sync.json` back without it —
    /// and the app then looked exactly like a fresh install and offered to
    /// create an address, minting a new one in silence while the forwarding
    /// rule in the person's own mailbox kept sending to the dead one.
    ///
    /// Nothing already on the phone could say this. `hasEmailSource` only
    /// means "this is PrivatBank", `banks[…].connected` is set by a statement
    /// import too, and `emailCursor > 0` is true only if a letter actually
    /// arrived.
    var emailAddressIssued: Bool = false

    /// Board #158. Syncing is off, and the address is **still alive**.
    ///
    /// This is what «Відключити пошту» now means. It used to delete the server
    /// account, which made the address the one thing in the app a person could
    /// destroy by accident — and there is no route to get it back: `/register`
    /// only ever mints a new random one. The owner asked for the opposite, so
    /// the credentials stay in the Keychain and only «Змінити адресу» throws
    /// them away.
    ///
    /// Separate from `emailNeedsReconnect`, which means the secret is DEAD.
    /// This one is a choice and is reversible; that one is a fact and is not.
    var emailPaused: Bool = false

    init() {}

    /// Written by hand rather than synthesised. The synthesised `Codable`
    /// throws `keyNotFound` for a missing key instead of using the memberwise
    /// default — so the first field added after this ships would make every
    /// existing `sync.json` undecodable, silently restarting a backfill that
    /// takes half an hour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursors = try c.decodeIfPresent([String: Cursor].self, forKey: .cursors) ?? [:]
        depthMonths = try c.decodeIfPresent(Int.self, forKey: .depthMonths) ?? 3
        needsReconnect = try c.decodeIfPresent(Bool.self, forKey: .needsReconnect) ?? false
        clientHash = try c.decodeIfPresent(String.self, forKey: .clientHash)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        seedCleared = try c.decodeIfPresent(Bool.self, forKey: .seedCleared) ?? false
        lastStop = try c.decodeIfPresent(String.self, forKey: .lastStop)
        emailCursor = try c.decodeIfPresent(Int.self, forKey: .emailCursor) ?? 0
        emailNeedsReconnect = try c.decodeIfPresent(Bool.self, forKey: .emailNeedsReconnect) ?? false
        // Defaults to `emailCursor > 0`, not to `false`. Every install that
        // already has an address predates this field, and the one person this
        // guard is for is exactly somebody restoring such an install onto a
        // new phone — so the field has to be right before it is ever written.
        // A consumed cursor means letters arrived, which means an address was
        // issued.
        emailAddressIssued = try c.decodeIfPresent(Bool.self, forKey: .emailAddressIssued)
            ?? (emailCursor > 0)
        // Defaults to false, and that is the safe direction: every install
        // predating this field has an address that is either connected or
        // already deleted, and neither is "paused". Guessing true would stop
        // a working sync for a reason nobody chose.
        emailPaused = try c.decodeIfPresent(Bool.self, forKey: .emailPaused) ?? false
    }
}

/// Which window to ask for next. A pure function of (state, accounts, now), so
/// every ordering rule below is testable without a clock or a network.
enum SyncPlan {
    static let window: TimeInterval = 31 * 86_400
    /// A held row's amount changes on settlement, so a forward window reaches
    /// back behind the cursor rather than starting where the last one ended.
    /// Costs nothing — it is the same single request.
    static let settleOverlap: TimeInterval = 3 * 86_400
    /// 61, not 60: monobank measures against its own clock and landing exactly
    /// on the boundary earns a 429.
    static let pace: TimeInterval = 61

    /// The "don't re-ask inside one pacing interval" floor: monobank refuses a
    /// second request for the same endpoint inside 61 s anyway, so a cursor
    /// younger than that can never be worth a window.
    ///
    /// It is NOT what stops forward from winning forever — it cannot be. It is
    /// exactly one pacing interval, which is exactly how long the engine waits
    /// between requests, so a caught-up account is `minForwardGap` stale again
    /// by the time the planner is next asked. What bounds forward is the
    /// `forwarded` set in `next`; see the comment there.
    static let minForwardGap: TimeInterval = pace

    enum Step: Equatable {
        case forward(account: String, from: Date, to: Date)
        case backward(account: String, from: Date, to: Date)
    }

    /// `nil` for «Усе, що є» — that stops on empty windows, never on a date.
    static func depthFloor(depthMonths: Int, now: Date) -> Date? {
        guard depthMonths > 0 else { return nil }
        return Calendar.kyiv.date(byAdding: .month, value: -depthMonths, to: now)
    }

    static func totalWindows(depthMonths: Int, accounts: Int) -> Int {
        max(1, depthMonths) * max(0, accounts)
    }

    /// What the depth screen promises. The first request goes immediately, so
    /// only the remaining ones cost a pacing interval.
    static func estimate(depthMonths: Int, accounts: Int) -> TimeInterval {
        TimeInterval(max(0, totalWindows(depthMonths: depthMonths, accounts: accounts) - 1)) * pace
    }

    /// `forwarded` is the set of accounts that have already been walked all the
    /// way up to the present during the current run — see the note in the
    /// forward loop and the `forwarded` variable in `SyncEngine.run`. An
    /// account that is merely PART of the way back is deliberately not in it.
    static func next(state: SyncState, accounts: [String], now: Date,
                     forwarded: Set<String> = []) -> Step? {
        // Forward first, in the caller's account order. A five-month-old row
        // can wait; this morning's coffee cannot.
        for account in accounts {
            // One catch-up per account per run. A forward commit sets
            // `newest = to`, and `to == now` for an account that is up to
            // date — so one pacing interval later it is `minForwardGap` stale
            // again, forward would win on every iteration forever, and the
            // backfill below would never be reached. The engine only puts an
            // account in here once a window actually reached the present, so
            // an account still behind after its window (a long absence needs
            // several 31-day hops) keeps qualifying, which is the catch-up
            // this must not break.
            if forwarded.contains(account) { continue }
            guard let cursor = state.cursors[account], let newest = cursor.newest else {
                return .forward(account: account, from: now - window, to: now)
            }
            // A cursor AHEAD of now can only come from a device clock that ran
            // ahead and was then corrected. It is not information, so it is
            // treated like no cursor at all: `timeIntervalSince` would stay
            // negative — and clamping it to `now` would leave the gap at zero —
            // for the entire length of the skew, and this account would
            // silently stop syncing forward for that whole week. The commit
            // clamps `newest` back to the present, so this costs one window,
            // once. `AppStore.advance` stops the poison being written; this is
            // the only thing that can rescue one already on disk.
            if newest > now { return .forward(account: account, from: now - window, to: now) }
            guard now.timeIntervalSince(newest) >= minForwardGap else { continue }
            let from = newest - settleOverlap
            return .forward(account: account, from: from, to: min(from + window, now))
        }

        // Then one backward window, for whichever account has the LEAST
        // history — so depth grows evenly instead of finishing one card first.
        let floor = depthFloor(depthMonths: state.depthMonths, now: now)
        let candidates = accounts.compactMap { account -> (String, Date)? in
            guard let cursor = state.cursors[account], !cursor.exhausted,
                  let oldest = cursor.oldest else { return nil }
            if let floor, oldest <= floor { return nil }
            return (account, oldest)
        }
        guard let (account, oldest) = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        var from = oldest - window
        if let floor { from = max(from, floor) }
        return .backward(account: account, from: from, to: oldest)
    }
}
