import Foundation

/// A receipt scanned from its QR but not yet published: the tax service's fiscal
/// lookup was not attempted (or has not yet succeeded) for its goods and seller.
/// Scanning creates this immediately from the QR alone — the owner measures
/// about an hour before a real receipt publishes, and hardware registers are
/// only promised "by the next business day" — so the app must hold the receipt
/// and retry rather than block on the network at scan time.
struct PendingReceipt: Codable, Hashable, Identifiable {
    var receiptId: UUID
    var check: FiscalCheck
    var scannedAt: Date
    var attempts: Int
    var nextAttempt: Date
    /// The last fetch failure, as free text — not an enum. A case written by a
    /// newer build must not make the whole file undecodable and wipe the queue;
    /// see `SyncState.lastStop` for the same reasoning.
    var lastError: String?
    var id: UUID { receiptId }
}

/// When to retry a pending receipt. A pure function of its arguments — no
/// stored state, no wall-clock reads — so a test can walk it against a clock
/// that moves without waiting in real time, and the same schedule that is
/// tested is the one that runs. Stage 1 of this project shipped a Critical
/// pacing defect that 410 green tests agreed with, because every injected
/// `now` was a frozen constant and the injected `sleep` never advanced it: a
/// component that never makes progress looked identical to one that did. This
/// enum exists so that mistake cannot recur here.
enum ReceiptSchedule {

    /// A receipt this old will never publish; stop asking.
    static let giveUpAfter: TimeInterval = 48 * 3600

    /// spec D6: 1 min, then +5 min, +15 min, +1 h, then every 3 h.
    private static let backoffMinutes: [Double] = [1, 5, 15, 60, 180]

    private static func delay(afterAttempts attempts: Int) -> TimeInterval {
        let index = min(max(attempts, 0), backoffMinutes.count - 1)
        return backoffMinutes[index] * 60
    }

    static func firstAttempt(after scannedAt: Date) -> Date {
        scannedAt.addingTimeInterval(delay(afterAttempts: 0))
    }

    static func nextAttempt(afterAttempts attempts: Int, now: Date) -> Date {
        now.addingTimeInterval(delay(afterAttempts: attempts))
    }

    /// `attempts > 0` on top of the wall-clock check: the only two things
    /// that ever drain the queue are a `scenePhase -> .active` transition
    /// and a `BGAppRefreshTask` wake, both at iOS's own discretion. Without
    /// this, a receipt scanned and then left alone for two days on a phone
    /// iOS never woke could reach the «не опублікували» card having asked
    /// the tax service exactly zero times — blaming it for a question the
    /// app never asked.
    ///
    /// **Board #186 revisited this clause and it stays.** That card moved the
    /// chasing to a server precisely because this phone cannot be relied on to
    /// wake — so it is fair to ask whether the workaround can go with it.
    ///
    /// It cannot, and the reason is the same card's other decision: the
    /// phone's own `TaxCabinetClient` is deliberately KEPT, for a person whose
    /// backend is unreachable or old, or who has no mail account at all.
    /// Receipts work with no server and that stays true — and on that path
    /// this clause guards exactly what it always did.
    ///
    /// A server-fetched receipt never reaches this test with `attempts == 0`
    /// anyway. The server is always awake, so it gives up on wall clock alone
    /// having genuinely asked; by the time the phone sees the receipt at all,
    /// the question has been put. The workaround is now narrower in effect
    /// than it was, without being narrower in code — which is the honest
    /// outcome, and better than deleting a guard because a different path
    /// stopped needing it.
    static func hasGivenUp(_ pending: PendingReceipt, now: Date) -> Bool {
        pending.attempts > 0 && now.timeIntervalSince(pending.scannedAt) > giveUpAfter
    }

    /// Due receipts, oldest-waiting first. A receipt past its 48-hour window is
    /// never due, whatever its `nextAttempt` says — otherwise a queue that
    /// holds a document that will never publish drains forever.
    static func due(_ queue: [PendingReceipt], now: Date) -> [PendingReceipt] {
        queue
            .filter { $0.nextAttempt <= now && !hasGivenUp($0, now: now) }
            .sorted { $0.nextAttempt < $1.nextAttempt }
    }
}
