import BackgroundTasks
import Foundation

/// One wake, one card.
///
/// iOS grants a `BGAppRefreshTask` about 30 seconds, and monobank makes us wait
/// 61 between statement requests — so a wake can afford exactly one request.
/// It spends it on the card the user actually uses, and never on a backfill: a
/// backward window that commits nothing would waste the day's one opportunity
/// on old data.
enum BackgroundRefresh {
    static let taskId = "ua.monitorfinance.app.refresh"

    /// The window is 90 days so a card used heavily last year cannot outvote
    /// the one being used now. Ties fall to `accounts` order, which is
    /// monobank's own, so the choice is stable between launches.
    static func busiestAccount(_ txs: [Transaction], accounts: [MonobankAccount],
                               now: Date) -> String? {
        guard let first = accounts.first else { return nil }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        var counts: [String: Int] = [:]
        for tx in txs where tx.date >= cutoff {
            for account in accounts where MonobankMapper.cardSuffix(account) == tx.cardSuffix {
                counts[account.id, default: 0] += 1
            }
        }
        let ranked = accounts.map { ($0.id, counts[$0.id] ?? 0) }
        return ranked.max { a, b in a.1 == b.1 ? false : a.1 < b.1 }?.0 ?? first.id
    }

    /// Must be called before the app finishes launching, or iOS refuses the
    /// registration for the whole process lifetime.
    static func register(_ store: AppStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()                        // always queue the next one first
            let work = Task { @MainActor in
                let before = Set(store.transactions.map(\.id))
                // The one request this wake can afford goes to the card the
                // user actually uses, not whichever `SyncPlan.next` would
                // otherwise pick first. Cleared in `defer` so a foreground
                // sync started right after is never left restricted to it.
                store.syncOnlyAccount = busiestAccount(store.transactions,
                                                       accounts: store.syncAccounts, now: Date())
                defer { store.syncOnlyAccount = nil }
                let outcome = await store.startSync(maxSteps: 1)
                // Ahead of `fresh` below, not after the receipt fetch: `fresh`
                // is a diff against `before`, so an email-sourced purchase that
                // lands after that diff is computed would never reach
                // `postNewPurchases` and this second source would silently
                // never notify while monobank's does. Bounded to one page for
                // the same ~30 s `BGAppRefreshTask` budget the receipt fetch
                // below rations for: unlike `startSync`'s `maxSteps: 1`, this
                // backend has no per-request rate limit, so nothing but this
                // argument stops a wake with a large first backfill from
                // spending the whole budget on old letters and starving the
                // receipt fetch that follows.
                let email = await store.syncPrivatEmailIfConnected(maxPages: 1)
                let fresh = store.transactions.filter { !before.contains($0.id) }
                await Notifications.postNewPurchases(fresh, store.settings.languageChoice)
                // The monobank step above spends its one request and then
                // must wait 61 s before it could ask again, so it returns
                // quickly either way — the seconds left in the wake's ~30 s
                // budget are what the receipt queue gets. Bounded to
                // `maxRequests: 1`, not 3: `TaxCabinetClient` sets a 20 s
                // timeout per request, so even one slow-or-unreachable
                // request already spends most of the remaining budget, and
                // three at 20 s plus two 3 s pacing gaps (66 s worst case)
                // would run well past the ~30 s iOS actually grants — landing
                // `setTaskCompleted` after expiration, which is exactly the
                // failure this wiring exists to avoid. Ungated —
                // `fetchDueReceipts`, not `fetchDueReceiptsIfAllowed` — for
                // the same reason `startSync` is called here rather than
                // `startSyncIfConnected`: the suppression gate exists for the
                // app-opening UI path, not a background wake `-skipOnboarding`
                // can never simulate.
                let receiptOutcome = await store.fetchDueReceipts(maxRequests: 1)
                task.setTaskCompleted(success: Self.wasProductive(outcome, receiptOutcome, email))
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// What this wake reports back to iOS — now weighing three halves of the
    /// work it did: the one sync window, whatever the receipt queue's
    /// remaining seconds afforded, and the one page `syncPrivatEmailIfConnected`
    /// got to pull.
    ///
    /// `true` unconditionally (for the sync outcome alone) is what shipped,
    /// including when the expiration handler cancelled the work and nothing
    /// was fetched. iOS budgets future wakes on this answer, so training it
    /// that a failed wake was productive costs the app the wakes it actually
    /// needs — and leaving the receipt half invisible to that accounting
    /// makes the same mistake in the other direction: a wake that fetched no
    /// new purchase but landed two receipts DID do work. The email half is
    /// the same mistake a third way: an email-only user (no monobank token,
    /// so `SyncEngine.run` reports `.stopped(.noToken)` and `syncDidWork` is
    /// false) whose one page imported ten purchases would otherwise report
    /// `setTaskCompleted(success: false)` on the very wake that source
    /// exists to deliver — starving future wakes for the one source that was
    /// actually doing the work.
    ///
    /// - `.stopped(.budget)` is SUCCESS for the sync: `maxSteps: 1` is how
    ///   this wake spends its one request, so hitting the budget is exactly
    ///   the intended end.
    /// - `.idle` is success too — nothing was due, and asking was correct.
    /// - Everything else on the sync side is a wake that achieved nothing on
    ///   that half: cancelled by expiration, offline, rate limited, no token,
    ///   a reconnect needed.
    /// - `.drained` with at least one receipt actually asked about is the
    ///   receipt half's own success. `.idle` there is deliberately NOT
    ///   counted on its own — unlike the sync side, an empty queue is the
    ///   ordinary case on almost every wake and would otherwise make this
    ///   report `true` regardless of whether the sync half achieved anything.
    ///   `.stoodDown` is not an achievement either; it is the endpoint saying
    ///   stop.
    /// - The email half's success is `imported > 0`, the same "at least one
    ///   asked about" bar as the receipt half — `nil` (not registered, needs
    ///   reconnect, or the fixture guard) and a page with nothing new both
    ///   report no work, for the same reason an empty receipt queue does not.
    static func wasProductive(_ sync: SyncEngine.Outcome, _ receipts: ReceiptFetcher.Outcome,
                              _ email: (imported: Int, merged: Int)?) -> Bool {
        let syncDidWork: Bool
        switch sync {
        case .completed, .idle, .stopped(.budget): syncDidWork = true
        default: syncDidWork = false
        }
        let receiptsDidWork: Bool
        switch receipts {
        case .drained(let count): receiptsDidWork = count > 0
        default: receiptsDidWork = false
        }
        let emailDidWork = (email?.imported ?? 0) > 0
        return syncDidWork || receiptsDidWork || emailDidWork
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
