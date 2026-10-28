import CryptoKit
import Foundation

extension AppStore {

    enum ClientMatch: Equatable { case firstTime, sameClient, differentClient }

    /// The UAH accounts sync may ask about, rebuilt from what `connect` stored.
    var syncAccounts: [MonobankAccount] {
        (banks.first { $0.id == "monobank" }?.accounts ?? []).compactMap { account in
            guard account.currency == "UAH", account.syncEnabled != false else { return nil }
            return MonobankAccount(
                id: account.id, type: account.type, currencyCode: 980,
                balance: account.balance, creditLimit: account.creditLimit ?? 0,
                maskedPan: account.suffix.isEmpty ? nil : ["******" + account.suffix.dropFirst()])
        }
    }

    /// What the engine may actually ask about this run — `syncAccounts`,
    /// narrowed to one when `syncOnlyAccount` is set. This is what
    /// `makeSyncEngine`'s `accounts` closure returns, so testing this
    /// property is testing that closure's behavior.
    var syncEligibleAccounts: [MonobankAccount] {
        guard let only = syncOnlyAccount else { return syncAccounts }
        return syncAccounts.filter { $0.id == only }
    }

    /// SHA-256, hex. The id itself is never stored — only the answer to "is
    /// this the same person as last time".
    static func clientHash(_ clientId: String) -> String {
        SHA256.hash(data: Data(clientId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func adoptClient(_ info: MonobankClientInfo) -> ClientMatch {
        let hash = Self.clientHash(info.clientId)
        guard let known = syncState.clientHash else {
            syncState.clientHash = hash
            persist()
            return .firstTime
        }
        return known == hash ? .sameClient : .differentClient
    }

    /// Only ever called after the user agrees. History belongs to a person, and
    /// two people's money must never end up in one dataset.
    @MainActor
    func wipeForNewClient(_ info: MonobankClientInfo) {
        // The run started against the PREVIOUS person's dataset may still be
        // in flight — a backfill takes minutes, and this is reachable the
        // whole time. Its next window would land here.
        abandonSync()
        // A `ReceiptFetcher` (task 11) parked in a tax-service request is the
        // same hazard one host over: it cannot be stopped either, and its
        // next commit must find this generation stale rather than land in
        // the new person's dataset.
        abandonReceiptFetch()
        transactions = []
        receipts = []
        receiptQueue = []
        syncState.cursors = [:]
        syncState.needsReconnect = false
        syncState.lastSuccess = nil
        // The previous person's failure is not this one's.
        syncState.lastStop = nil
        syncState.seedCleared = true
        syncState.clientHash = Self.clientHash(info.clientId)
        // `transactions` above is now empty, but a left-alone `emailCursor`
        // would still claim everything up to N was already imported — those
        // letters could never be re-fetched, the exact "hole nothing will
        // ever fill" `ingestRows` exists to avoid. Reset both to the state a
        // fresh install is in. Deliberately NOT touching the Keychain
        // credentials here: the mailbox registration belongs to this PERSON,
        // not to the monobank client just wiped, and deciding whether a
        // client switch should also disconnect the mailbox is issue #91's
        // screen, not this function's call to make.
        syncState.emailCursor = 0
        syncState.emailNeedsReconnect = false
        persistNow()
    }

    @MainActor
    func setSyncDepth(_ months: Int) {
        guard months != syncState.depthMonths else { return }
        syncState.depthMonths = months
        // Every cursor's `exhausted` was decided against the OLD floor, and the
        // planner treats it as a sticky gate it never re-evaluates. Leaving it
        // set after the depth changes means an account that finished backfilling
        // three months never resumes when the user asks for twelve — a
        // permanent, silent gap in their history. Cleared on any change rather
        // than only on an increase: re-marking it costs at most one request,
        // and "only on increase" is a condition that will be got wrong.
        for id in syncState.cursors.keys {
            syncState.cursors[id]?.exhausted = false
            syncState.cursors[id]?.emptyStreak = 0
        }
        persist()
    }

    @MainActor
    func markNeedsReconnect() {
        syncState.needsReconnect = true
        persist()
    }

    /// Builds an engine over the current store and runs it. One at a time —
    /// two concurrent runs would each believe they own the 61-second budget.
    @MainActor
    @discardableResult
    func startSync(maxSteps: Int = .max) async -> SyncEngine.Outcome {
        guard !isSyncing else { return .stopped(.budget) }
        isSyncing = true
        // Lowers only the flag it raised. `abandonSync` already lowered this
        // one and a later run may have raised its own; clearing that would
        // hide a live sync from the UI for the rest of its length.
        let generation = syncGeneration
        defer { if isCurrentSync(generation) { isSyncing = false } }
        // A run in flight has nothing to explain — the spinner is the status.
        // Cleared HERE rather than only on success: every path out of `run`
        // below either writes a new reason or leaves none, so a stale failure
        // can never outlive a run that worked. In particular a
        // pull-to-refresh, which ends `.stopped(.budget)` after committing its
        // one window, clears the line without needing a "was it productive"
        // test nobody can get right from an `Outcome` alone.
        if syncState.lastStop != nil {
            syncState.lastStop = nil
            persist()
        }
        // ONE engine for the process, not one per call. The 61-second pacer is
        // instance state: a fresh engine starts with no `lastRequest` and fires
        // its first request immediately, so a background wake followed by the
        // user opening the app would send two statement requests inside a
        // minute and earn a 429 that nothing here can prevent. Found by
        // Task 6's review.
        if syncEngine == nil { syncEngine = makeSyncEngine() }
        let engine = syncEngine!
        let outcome = await engine.run(maxSteps: maxSteps)
        // Same generation gate as every other write a sync performs: a run
        // that was abandoned mid-flight (a wipe, a reset, a new client) is
        // describing a dataset that no longer exists, and its complaint must
        // not land on the one that replaced it.
        //
        // **Board #165 added `monobankIsConnected`.** Six call sites reach
        // here without `startSyncIfConnected`'s guard — pull-to-refresh on
        // Home and on the feed, the depth change, and every background wake —
        // and `SyncEngine.run` opens by reporting `.stopped(.noToken)` when
        // there is no token to use. So a person who had just disconnected the
        // bank got «Токен monobank не знайдено — підключіть банк заново», and
        // it stayed: the only thing that clears `lastStop` is a run that
        // commits a window, which a disconnected bank can never do.
        //
        // The same line was reaching an **email-only** person, who has no
        // monobank token because they never connected monobank, and was
        // telling them to reconnect a bank they had never had. That one had
        // not been noticed at all.
        //
        // Gating the WRITE rather than the run: `run` returns immediately and
        // without a request when there is no token, so there is nothing to
        // save by returning early — and the entry above still clears a stale
        // line, which is the behaviour a disconnected bank wants.
        if isCurrentSync(generation), case .stopped(let stop) = outcome,
           stop.userMessage != nil, monobankIsConnected {
            syncState.lastStop = stop.rawValue
            persist()
        }
        return outcome
    }

    /// Whether monobank's status lines have anything to be about.
    ///
    /// Board #165. A property rather than a condition spelled out inside
    /// `SyncStatusView`, for the reason `startSyncIfConnected` gives right
    /// below: the interesting part is the condition, and a condition inside a
    /// view body cannot be unit-tested without simulating SwiftUI.
    ///
    /// It is also the only thing that covers the case `disconnect` cannot
    /// reach — a `sync.json` restored onto a phone that has never connected
    /// monobank carries the old phone's stop, and no disconnect ever runs
    /// there to clear it.
    var monobankIsConnected: Bool {
        connectedBanks.contains { $0.id == Bank.monobankId }
    }

    /// The foreground-activation entry point: starts a sync only when a
    /// monobank connection exists and hasn't been flagged for reconnect.
    /// Pulled out of `MonitorFinanceApp`'s `scenePhase` handler so the
    /// condition is unit-testable without simulating SwiftUI's scene
    /// lifecycle. Deliberately does NOT also require `syncState.lastSuccess`
    /// to be set — a session whose first sync never committed a window
    /// (offline, bank down, cancelled) must still be able to retry here, or
    /// it is stranded until iOS next grants a background wake, which can be
    /// hours or days away. Found by review.
    @MainActor
    @discardableResult
    func startSyncIfConnected(maxSteps: Int = .max) async -> SyncEngine.Outcome? {
        guard monobankIsConnected, !syncState.needsReconnect else { return nil }
        // `-skipOnboarding` fabricates a connected bank without a real
        // `client-info` call — a test shortcut, never something production
        // onboarding does (that always goes through `verifyAndConnect`). When
        // it is paired with the bundled demo dataset, that dataset is a
        // FIXTURE many UI suites assert exact totals against (`BudgetTests`,
        // `SplitTests`, `StatsAndSettingsTests`…) — a real foreground sync
        // would fetch six more stub rows per account under `-stubMonobank`
        // and mutate it out from under them on every launch. `-noDemoData` is
        // the one `-skipOnboarding` scenario that WANTS this sync to run —
        // `EmptyStateTests` exercises the loading state on purpose, and there
        // is no bundled fixture there to disturb. Both flags compile to
        // `false` in Release, so a real user is never affected either way.
        guard !Launch.skipOnboarding || Launch.noDemoData else { return nil }
        return await startSync(maxSteps: maxSteps)
    }

    /// Stored on `AppStore` as `@ObservationIgnored var syncEngine: SyncEngine?`.
    @MainActor
    private func makeSyncEngine() -> SyncEngine {
        // Captured ONCE, here, and carried by every closure below that writes.
        // `resetEverything` and `wipeForNewClient` move the store past this
        // value, and from that moment this engine — which cannot be stopped,
        // being an actor parked inside a bank request — can no longer put
        // anything back. See `AppStore.abandonSync`.
        let generation = syncGeneration
        return SyncEngine(.init(
            api: api,
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            // `?? nil` flattens the String?? that `self?.token(...)` produces —
            // without it this does not compile against `() async -> String?`.
            token: { [weak self] in await MainActor.run { self?.token(for: "monobank") ?? nil } },
            // `syncEligibleAccounts`, not `syncAccounts` directly: a
            // background wake narrows this to one card via `syncOnlyAccount`
            // (see `BackgroundRefresh.register`); a foreground sync leaves it
            // unfiltered.
            accounts: { [weak self] in await MainActor.run { self?.syncEligibleAccounts ?? [] } },
            state: { [weak self] in await MainActor.run { self?.syncState ?? SyncState() } },
            commit: { [weak self] rows, step, empty in
                await MainActor.run {
                    guard let self, self.isCurrentSync(generation) else { return }
                    self.ingest(rows, step: step, wasEmpty: empty)
                }
            },
            // Gated for the same reason as `commit`, and it is a write too:
            // it sets `needsReconnect` and persists, which after a wipe would
            // recreate the directory that was just deleted and strand a
            // fresh-install app behind a reconnect banner it cannot clear.
            markReconnect: { [weak self] in
                await MainActor.run {
                    guard let self, self.isCurrentSync(generation) else { return }
                    self.markNeedsReconnect()
                }
            }))
    }

    /// Windows finished against windows planned, for the line on Home.
    /// `nil` when there is nothing in flight.
    ///
    /// `nil` for «Усе, що є» as well. That depth has no planned total — it
    /// stops on two empty windows, not on a date — and `totalWindows` falls
    /// back to `max(1, 0) * accounts`, which is just the account count. So the
    /// line pinned at «2 з 2» after the first window of each card while the
    /// backfill carried on for another twenty minutes. `SyncStatusView` shows
    /// the countless «Завантажуємо покупки…» instead, which is the branch that
    /// used to be unreachable.
    var syncProgress: (done: Int, total: Int)? {
        // Every card disabled makes `accounts` (below) zero, and
        // `max(1, depth) * 0` is zero either way — the countless
        // «Завантажуємо покупки… 0 з 0» this guard exists to prevent. The
        // engine itself handles an empty account list cleanly (no plan step,
        // a clean completion); this guard only stops the status view from
        // describing a fetch that isn't happening. Found by Task 8's review,
        // made reachable by Task 11's per-card toggles.
        guard isSyncing, syncState.depthMonths > 0, !syncAccounts.isEmpty else { return nil }
        let accounts = syncAccounts.count
        let total = SyncPlan.totalWindows(depthMonths: syncState.depthMonths, accounts: accounts)
        let done = syncAccounts.reduce(0) { sum, account in
            guard let cursor = syncState.cursors[account.id],
                  let newest = cursor.newest, let oldest = cursor.oldest else { return sum }
            return sum + max(1, Int((newest.timeIntervalSince(oldest) / SyncPlan.window).rounded(.up)))
        }
        return (min(done, total), total)
    }

    enum ConnectOutcome: Equatable {
        case connected
        /// The token belongs to a different monobank client. Merging two
        /// people's money silently would be the worst failure this app has.
        case differentClient(MonobankClientInfo)
        case failed(MonobankError)
    }

    /// The token screen's one call. Spends the first minute of the sync
    /// budget on `client-info` — the accounts and client hash it returns are
    /// handed to the store rather than discarded, so `SyncEngine` never has
    /// to ask again.
    @MainActor
    func verifyAndConnect(bankId: String, token: String) async -> ConnectOutcome {
        let info: MonobankClientInfo
        do {
            info = try await api.clientInfo(token: token)
        } catch let error as MonobankError {
            return .failed(error)
        } catch {
            return .failed(.offline(error.localizedDescription))
        }
        if adoptClient(info) == .differentClient { return .differentClient(info) }
        finishConnecting(bankId: bankId, token: token, info: info)
        return .connected
    }

    /// The user chose to start over with the new client. The only caller of
    /// `wipeForNewClient` — reachable exclusively from the confirmation
    /// alert's destructive button on `TokenView`, never from a path that
    /// runs without a person choosing it.
    @MainActor
    func acceptNewClient(bankId: String, token: String, info: MonobankClientInfo) {
        wipeForNewClient(info)
        finishConnecting(bankId: bankId, token: token, info: info)
    }

    @MainActor
    private func finishConnecting(bankId: String, token: String, info: MonobankClientInfo) {
        connect(bankId: bankId, token: token)
        applyAccounts(info, bankId: bankId)
        // A 403 during sync raised this; a good token must lower it or the
        // reconnect banner never goes away.
        syncState.needsReconnect = false
        persistNow()
    }

    /// Replaces the bank's seeded accounts with the real ones. Non-UAH accounts
    /// are dropped rather than shown as syncable: `Transaction` has no currency
    /// and every total sums amounts blindly.
    @MainActor
    func applyAccounts(_ info: MonobankClientInfo, bankId: String) {
        guard let i = banks.firstIndex(where: { $0.id == bankId }) else { return }
        let previous = banks[i].accounts
        banks[i].accounts = info.accounts.compactMap { account in
            guard let currency = MonobankMapper.currency(account.currencyCode) else { return nil }
            return Account(id: account.id,
                           suffix: MonobankMapper.cardSuffix(account),
                           type: account.type ?? "account",
                           currency: currency,
                           balance: account.balance,
                           creditLimit: account.creditLimit,
                           // A reconnect must not undo the user's card choice.
                           syncEnabled: previous.first { $0.id == account.id }?.syncEnabled)
        }
        persist()
    }

    /// The merge half of `ingest`, shared with the Privat statement import.
    /// No cursor advance and NO persist — each caller persists, so rows and
    /// whatever else that caller writes still commit under one write.
    ///
    /// Lives in this file on purpose: `clearDemoRowsIfNeeded` and
    /// `applyingRule` are file-private.
    @MainActor
    @discardableResult
    func ingestRows(_ rows: [Transaction]) -> (imported: Int, merged: Int) {
        clearDemoRowsIfNeeded()

        var index: [Transaction.ID: Int] = [:]
        for (i, tx) in transactions.enumerated() where index[tx.id] == nil { index[tx.id] = i }

        var imported = 0
        var merged = 0
        for row in rows {
            if let i = index[row.id] {
                merged += 1
                // The bank owns these. Everything else is the user's and is
                // deliberately left alone — a re-fetch must never erase a
                // decision a human made.
                transactions[i].date = row.date
                // Board #80. Noted BEFORE the write, and acted on after every
                // other bank-owned field has landed: the resplit reads the
                // transaction back, so it has to see the settled row and not
                // a half-updated one.
                let amountSettledAtANewFigure = transactions[i].amount != row.amount
                transactions[i].amount = row.amount
                transactions[i].merchant = row.merchant
                transactions[i].cardSuffix = row.cardSuffix
                transactions[i].bankId = row.bankId
                transactions[i].hold = row.hold
                transactions[i].externalId = row.externalId
                // MCC is bank-owned like the rest, with one asymmetry: it
                // arrived late, so every row stored before it existed carries
                // nil, and a re-fetch is the ONLY chance to fill those in —
                // monobank's window is 31 days and then the code is gone for
                // good. Hence the coalesce rather than a plain assignment: a
                // response that omits the code must not blank one already
                // held. Losing a fact we cannot re-ask for is the worse of
                // the two errors.
                transactions[i].mcc = row.mcc ?? transactions[i].mcc
                // Same asymmetry, same coalesce, and it arrived later still —
                // every row synced before board #56 carries nil here even
                // though it has an `mcc`.
                transactions[i].originalMcc = row.originalMcc ?? transactions[i].originalMcc
                // Same asymmetry once more. A Privat row already on the phone
                // was stored before this field existed and carries nil, and
                // the cross-source matcher can only see a row that has one —
                // so a re-import is the chance to fill it in. Coalesced, not
                // assigned: a source that sends no balance (a letter for an
                // interest row) must not blank a balance the statement gave.
                transactions[i].balanceAfterMinor = row.balanceAfterMinor ?? transactions[i].balanceAfterMinor
                // A settled hold's splits still describe the amount it was
                // authorised for. Board #80.
                if amountSettledAtANewFigure { resplitAfterSettlement(at: i) }
            } else {
                imported += 1
                transactions.append(applyingRule(to: row))
                index[row.id] = transactions.count - 1
            }
        }
        return (imported, merged)
    }

    /// Rows and the cursor advance, committed together under one write.
    ///
    /// Separating them is the failure mode that matters: rows without the
    /// cursor mean the window is fetched again; the cursor without the rows
    /// means a hole nothing will ever fill and nothing will ever report.
    @MainActor
    func ingest(_ rows: [Transaction], step: SyncPlan.Step, wasEmpty: Bool) {
        ingestRows(rows)
        advance(step, wasEmpty: wasEmpty)
        // The scan usually beats the purchase into the app — the bank sync is
        // paced at one request per 61 seconds — so this is the path by which
        // MOST receipts find their transaction, not the scan itself (spec §3).
        matchLooseReceipts()
        persistNow()
    }

    /// A rule the user taught, applied to a row that has just arrived.
    /// Returns the row unchanged when no rule applies.
    ///
    /// New rows only. Re-deciding an existing row would violate the merge rule
    /// — the user owns `category`, `kind` and `resolution` once they exist.
    private func applyingRule(to row: Transaction) -> Transaction {
        // A generic merchant is never auto-decided, whatever the rule table
        // happens to hold — a rule taught before `GenericMerchant` existed, or
        // one written by a build that predates it, must not start typing
        // transfers again at ingest.
        guard !GenericMerchant.matches(row.merchant) else { return row }
        let key = MerchantKey.normalize(row.merchant)
        // `governing`, not `first(where:)` — board #81. A merchant may now
        // hold a rule for its expenses and another for its income, and the one
        // that answers for THIS row is the one scoped to its kind, falling
        // back to an unscoped rule. `first` would have returned whichever the
        // person happened to teach earlier.
        guard let rule = rules.governing(key, kind: row.kind) else { return row }
        // An ambiguous merchant is one the user has said belongs in different
        // categories at different times. Asking is the whole point of the flag.
        guard !rule.ambiguous else { return row }
        // The scope guard that used to stand here is now `governing`'s job and
        // is gone rather than kept as a second brace: it could only ever be
        // true after that call, so it was a line no test could fail and a
        // mutation could not kill. What it protected against is unchanged and
        // still worth stating — a category rule learned from an EXPENSE must
        // never type an income row of the same merchant with a spending
        // category and withdraw it from the queue unasked.

        var decided = row
        if rule.kind == .transfer {
            decided.kind = .transfer
            decided.category = ""
            decided.resolution = .rule
        } else if let category = rule.category, !category.isEmpty {
            decided.category = category
            decided.resolution = .rule
        }
        return decided
    }

    private func advance(_ step: SyncPlan.Step, wasEmpty: Bool) {
        let now = Date()
        switch step {
        case .forward(let account, let from, let to):
            var cursor = syncState.cursors[account] ?? SyncState.Cursor()
            // Clamped: `to` comes from the device clock at planning time, and a
            // clock that ran ahead would park `newest` in the future. Once the
            // clock is corrected, `now.timeIntervalSince(newest)` stays negative
            // for the length of the skew and the planner never asks for another
            // forward window for this account.
            cursor.newest = min(to, now)
            cursor.oldest = min(cursor.oldest ?? from, from)
            syncState.cursors[account] = cursor

        case .backward(let account, let from, _):
            var cursor = syncState.cursors[account] ?? SyncState.Cursor()
            cursor.oldest = from
            cursor.emptyStreak = wasEmpty ? cursor.emptyStreak + 1 : 0
            if let floor = SyncPlan.depthFloor(depthMonths: syncState.depthMonths, now: now),
               from <= floor {
                cursor.exhausted = true
            }
            // «Усе, що є» has no floor: one empty month is a quiet month, two
            // in a row is the end of what monobank still holds.
            if syncState.depthMonths == 0, cursor.emptyStreak >= 2 { cursor.exhausted = true }
            syncState.cursors[account] = cursor
        }
        syncState.lastSuccess = now
    }

    /// Demo rows carry no `externalId`. Once real data has landed once, they
    /// go — this is the spec's D3, "drop the seed", carried out exactly once
    /// and recorded so it cannot run again over rows a person added later.
    ///
    /// Seeded RULES are left alone: their merchant keys are scrubbed inventions
    /// that no real statement text can match, so they are inert rather than
    /// wrong.
    ///
    /// **Receipts go by PROVENANCE, not by whether anything points at them**
    /// (board #53). The rule used to be "delete every receipt no surviving row
    /// references and nothing has queued", which reads as a definition of
    /// orphan and is not one: a receipt whose items have landed and which
    /// matches no purchase is a `.noPurchase` card in Розібрати — an ordinary,
    /// designed state (D5), sitting on screen asking to be attached by hand.
    /// It has left `receiptQueue` (the fetch is done) and no row references it,
    /// so the old rule deleted precisely the receipt the user was being asked
    /// about. The `queued` half only ever covered the earlier window, before
    /// the fetch landed.
    ///
    /// `sampleReceipts` is the seed's own list, held from `init`. A receipt the
    /// user scanned can never be in it, whatever it is or is not attached to —
    /// which is the property the old test could not express.
    private func clearDemoRowsIfNeeded() {
        guard !syncState.seedCleared else { return }
        syncState.seedCleared = true
        guard transactions.contains(where: { $0.externalId == nil }) else { return }
        transactions.removeAll { $0.externalId == nil }
        let seeded = Set(sampleReceipts.map(\.id))
        receipts.removeAll { seeded.contains($0.id) }
    }
}
