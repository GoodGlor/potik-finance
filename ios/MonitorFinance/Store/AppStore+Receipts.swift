import Foundation

extension AppStore {

    func receipt(for tx: Transaction) -> Receipt? {
        guard let id = tx.receiptId else { return nil }
        return receipts.first { $0.id == id }
    }

    /// Attaching writes both sides. Replacing an existing receipt removes the
    /// old one: `receipts` is keyed by nothing but its own array position, so a
    /// dropped link is a permanent orphan nothing can ever reach or delete.
    @MainActor
    func attach(_ receipt: Receipt, to id: Transaction.ID) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        if let previous = transactions[index].receiptId {
            receipts.removeAll { $0.id == previous }
            // Same orphan `detachReceipt` guards against: without this, a
            // still-queued previous receipt would keep being re-fetched by
            // `ReceiptFetcher` forever with nothing left to land it onto.
            receiptQueue.removeAll { $0.receiptId == previous }
        }
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
        transactions[index].receiptId = receipt.id
        // The old receipt's splits described ITS items; a new receipt means
        // those items are gone, and any leftover split would describe goods
        // nobody can see any more.
        clearSplits(on: index)
        persist()
    }

    @MainActor
    func detachReceipt(from id: Transaction.ID) {
        guard let index = transactions.firstIndex(where: { $0.id == id }),
              let receiptId = transactions[index].receiptId else { return }
        transactions[index].receiptId = nil
        receipts.removeAll { $0.id == receiptId }
        // Without this, a receipt detached during its ~1h fetch window
        // leaves its `PendingReceipt` behind: invisible (no `Receipt` -> no
        // card) and undeletable (`deleteReceipt` is card-only), but still
        // due, so `ReceiptFetcher` re-fetches it on every wake for 48h and
        // then leaves it in `receiptQueue.json` forever.
        receiptQueue.removeAll { $0.receiptId == receiptId }
        clearSplits(on: index)
        persist()
    }

    /// D4 — advisory, no tolerance. `abs` because an expense is negative and a
    /// receipt's sum never is.
    static func mismatch(_ tx: Transaction, _ receipt: Receipt) -> String? {
        guard abs(tx.amount) != receipt.fiscalSum else { return nil }
        return String(format: L10n.t("Чек на %@, покупка на %@", L10n.formatting),
                      receipt.fiscalSum.uahExact, abs(tx.amount).uahExact)
    }

    // MARK: the queue — scan, land, fail, match, attach, delete

    /// No transaction points at these — either still waiting on the bank sync
    /// to bring the matching purchase (the ordinary, temporary case) or,
    /// once its items have landed and the automatic match still found
    /// nothing, a `receiptCards` candidate.
    var looseReceipts: [Receipt] {
        let referenced = Set(transactions.compactMap(\.receiptId))
        return receipts.filter { !referenced.contains($0.id) }
    }

    /// The entry point for a scanned QR. Builds the shell immediately — no
    /// network wait, the tax cabinet is not asked here — tries the automatic
    /// match against purchases already in the app, and enqueues the receipt
    /// for `ReceiptFetcher` (task 11) to fetch its goods.
    ///
    /// A rescan of a document that already has a `Receipt` — still queued, or
    /// already landed — must not mint a second one: `(registerNumber,
    /// documentNumber)` is the fiscal document's identity; `receipt.id` is
    /// minted fresh on every scan and would never dedupe anything. Checked
    /// against `receipts`, not `receiptQueue`, because `landItems` removes the
    /// queue entry once the goods arrive but leaves the receipt itself — a
    /// rescan of the same paper after that point (plausible: it is still in
    /// the user's hand) must still return the receipt already on file rather
    /// than mint an unmatchable twin. `deleteReceipt` removes it from
    /// `receipts`, so a deliberate delete-then-rescan still starts fresh.
    @discardableResult
    @MainActor
    func scan(_ check: FiscalCheck, now: Date) -> Receipt {
        if let receipt = receipts.first(where: {
            $0.registerNumber == check.registerNumber && $0.documentNumber == check.documentNumber
        }) {
            return receipt
        }

        let shell = ReceiptBuilder.shell(from: check, now: now)
        receipts.append(shell)
        // Reuses `attach` rather than writing `transactions[i].receiptId = …`
        // directly, so the "replacing a receipt drops the old one and clears
        // its splits" invariant is not re-implemented here.
        if let txId = ReceiptMatch.sole(for: shell, in: transactions) {
            attach(shell, to: txId)
        }
        // Enqueued regardless of whether the match above just succeeded: the
        // goods still have to be fetched either way.
        receiptQueue.append(PendingReceipt(
            receiptId: shell.id, check: check, scannedAt: now, attempts: 0,
            nextAttempt: ReceiptSchedule.firstAttempt(after: now), lastError: nil))
        askTheServerToChase(check)
        persist()
        return shell
    }

    /// Board #186 — hand the question to the server the moment the QR is read.
    ///
    /// **This call, not `ServerFirstTaxCabinet`, is what the card is actually
    /// about.** The wrapper only collects; this is what makes there be
    /// something to collect. It fires at SCAN time, so the server starts
    /// chasing while the phone goes back in a pocket and iOS grants it no
    /// wakes for two days — the exact case `ReceiptSchedule.hasGivenUp` had to
    /// be written around.
    ///
    /// **Detached and unawaited on purpose.** `scan` returns a `Receipt` to a
    /// view that is about to show it; making that wait on a network round trip
    /// would put the scanner's own latency behind an optimisation. A failed
    /// post costs nothing either: the phone's own client still fetches the
    /// receipt, and the next scan of anything re-posts nothing while
    /// `startReceipts` re-queues what is still pending.
    ///
    /// Silent on failure, and that is the whole error handling. There is no
    /// state to show a person here — «we could not ask our server to ask the
    /// tax service» is not a sentence anybody can act on, and the receipt is
    /// being fetched either way.
    @MainActor
    private func askTheServerToChase(_ check: FiscalCheck) {
        guard let credentials = privatEmailCredentials else { return }
        let api = emailAPI
        Task.detached { try? await api.queueReceipt(credentials: credentials, check: check) }
    }

    /// `ReceiptFetcher` (task 11) hands its parsed document back here — never
    /// touching `AppStore` itself, matching `SyncEngine`'s discipline.
    ///
    /// Ignored, rather than resurrecting anything, if there is no queue entry
    /// (or, past that, no receipt) left for this id: a wipe (`resetEverything`,
    /// `wipeForNewClient`) or a detach can outrun a fetch already in flight.
    /// `receiptGeneration` is the guard task 11's own commit closure checks
    /// before ever calling this, but a defensive `guard` here costs nothing
    /// and keeps this method correct standing alone.
    @MainActor
    func landItems(_ parsed: ParsedCheck, on receiptId: UUID, now: Date) {
        // The queue entry is looked up, not just removed, before anything
        // else: its `FiscalCheck` is what `ReceiptBuilder.macMatches` checks
        // the fetched document against — `landItems` itself is only ever
        // handed the parsed document, never the QR it was fetched for. No
        // entry here means nothing to land against at all (a wipe, or a
        // detach that has already cleared it — see `detachReceipt`).
        guard let pendingIndex = receiptQueue.firstIndex(where: { $0.receiptId == receiptId }) else {
            return
        }
        let pending = receiptQueue[pendingIndex]
        // The lookup is keyed on id+fn+sm+date — the endpoint's own key —
        // so a `<MAC>` mismatch here is not evidence this is the wrong
        // document, only that the control number could not be confirmed.
        // Routing it through `failFetch` was tried and reverted: one
        // captured vendor (`fiscal_check_2`) ships `<MAC>` as hex where the
        // other seven ship base64, no capture in this repo carries a QR to
        // check that vendor's encoding against, and `failFetch` keeps the
        // queue entry and advances the backoff — so a real encoding
        // difference would strand every receipt from that vendor for 48h
        // and then tell the user the tax service never published a receipt
        // it published fine. The goods land regardless; the mismatch is
        // kept only as an inert diagnostic (`Receipt.controlNumberMismatch`)
        // that nothing branches on.
        let macMismatch = !ReceiptBuilder.macMatches(parsed, pending.check)
        // Dequeued BEFORE the guard below, not after: a receipt detached
        // while still queued (see `detachReceipt`) is gone from `receipts`,
        // so that guard's `firstIndex` fails and returns early. Dequeuing
        // first means that orphan still leaves `receiptQueue` the next time
        // a fetch for it lands, instead of being re-fetched forever.
        receiptQueue.remove(at: pendingIndex)
        guard let index = receipts.firstIndex(where: { $0.id == receiptId }) else {
            persist()
            return
        }
        receipts[index].items = ReceiptBuilder.items(from: parsed)
        receipts[index].registerModel = parsed.registerModel
        receipts[index].itemsLandedAt = now
        receipts[index].controlNumberMismatch = macMismatch
        // No `matchLooseReceipts()` call here on purpose: `ReceiptMatch` reads
        // only `fiscalSum` and `fiscalTime`, both fixed at scan time and
        // untouched by landing goods, so nothing this method just wrote could
        // ever change which transaction this or any other loose receipt
        // matches. The match that can newly become possible is a NEW
        // transaction arriving — that race is `ingest`'s to close, not this
        // method's.
        persist()
    }

    /// Advances the backoff and keeps both the receipt and the queue entry —
    /// a `notPublished` today is very likely a `notPublished` that publishes
    /// tomorrow. `ReceiptSchedule.hasGivenUp` is what eventually stops
    /// asking; this method never deletes anything on its own.
    @MainActor
    func failFetch(_ receiptId: UUID, reason: TaxCabinetError, now: Date) {
        guard let index = receiptQueue.firstIndex(where: { $0.receiptId == receiptId }) else { return }
        let attempts = receiptQueue[index].attempts + 1
        receiptQueue[index].attempts = attempts
        receiptQueue[index].nextAttempt = ReceiptSchedule.nextAttempt(afterAttempts: attempts, now: now)
        receiptQueue[index].lastError = String(describing: reason)
        persist()
    }

    /// Tries the automatic match for every receipt no transaction points at
    /// yet. Called from `ingest`, right after new rows are committed — spec
    /// §3: because the bank sync is paced at one request per 61 seconds, a
    /// scan usually wins the race, so THIS is the path by which most receipts
    /// find their transaction, not the scan itself. NOT called from
    /// `landItems`: see the comment there for why landing goods can never
    /// newly satisfy `ReceiptMatch`.
    @MainActor
    func matchLooseReceipts() {
        for receipt in looseReceipts {
            if let txId = ReceiptMatch.sole(for: receipt, in: transactions) {
                attach(receipt, to: txId)
            }
        }
    }

    /// The hand-picked path, reachable from the "no purchase found" card. It
    /// must go through even when `AppStore.mismatch` would still flag the
    /// result: that advisory is a decision the owner made and deliberately
    /// kept in an earlier stage (A5/A6) — this task tightens the AUTOMATIC
    /// match (`ReceiptMatch.sole`) only, and must not quietly reverse it.
    ///
    /// Unlike `scan`'s automatic attach, `receiptId` here can already belong
    /// to a DIFFERENT transaction — the user is re-pointing it, not filing it
    /// for the first time. `attach` only ever writes the new side; left
    /// alone, the old transaction would keep a `receiptId` pointing at a
    /// receipt `attach` is about to move out from under it, together with
    /// splits describing goods it can no longer show — exactly what
    /// `clearSplits`'s own doc comment exists to prevent. Cleared directly
    /// here rather than through `detachReceipt(from:)`, which would delete
    /// the receipt from `receipts` before `attach` got a chance to re-file it.
    @MainActor
    func attachManually(_ receiptId: UUID, to txId: Transaction.ID) {
        guard let receipt = receipts.first(where: { $0.id == receiptId }) else { return }
        if let old = transactions.firstIndex(where: { $0.receiptId == receiptId }),
           transactions[old].id != txId {
            transactions[old].receiptId = nil
            clearSplits(on: old)
        }
        attach(receipt, to: txId)
    }

    /// Removes a receipt everywhere it is reachable from: the transaction it
    /// is attached to, if any — going through `detachReceipt` so its splits
    /// are cleared the same way a detach's are, rather than re-implementing
    /// that here — and the queue, so a deleted receipt is never re-offered as
    /// a fetch or a card.
    @MainActor
    func deleteReceipt(_ receiptId: UUID) {
        if let tx = transactions.first(where: { $0.receiptId == receiptId }) {
            detachReceipt(from: tx.id)
        } else {
            receipts.removeAll { $0.id == receiptId }
        }
        receiptQueue.removeAll { $0.receiptId == receiptId }
        persist()
    }

    /// The "hasn't published" card's retry button. Restarts the clock rather
    /// than only nudging `nextAttempt`: a receipt reaches that card because
    /// `ReceiptSchedule.hasGivenUp` returned true, and `hasGivenUp` reads
    /// `scannedAt` — leaving it alone would make the entry due but still
    /// given-up, and `ReceiptSchedule.due` excludes a given-up entry whatever
    /// its `nextAttempt` says.
    @MainActor
    func retryNow(_ receiptId: UUID, now: Date) {
        guard let index = receiptQueue.firstIndex(where: { $0.receiptId == receiptId }) else { return }
        receiptQueue[index].scannedAt = now
        receiptQueue[index].attempts = 0
        receiptQueue[index].nextAttempt = now
        receiptQueue[index].lastError = nil
        persist()
    }

    // MARK: running the fetcher (task 12 — the wiring)

    /// Builds (once) or reuses the process's one `ReceiptFetcher` and drains
    /// whatever in `receiptQueue` is due. Mirrors `AppStore.startSync` one
    /// host over: ONE fetcher for the process, not one per call — a fresh
    /// actor starts with no `lastRequest` and would fire immediately, and
    /// would also forget any stand-down the previous run just entered.
    ///
    /// `now` is a parameter — defaulting to the real wall clock, threaded
    /// through to `makeReceiptFetcher` — rather than read as `Date()` inside
    /// the fetcher's closures, for the same reason `receiptCards(now:)`
    /// takes it explicitly: the 48-hour `ReceiptSchedule.hasGivenUp` boundary
    /// this wiring depends on (via `ReceiptSchedule.due`) must be something a
    /// test can walk without waiting in real time. A fixed `Date()` read at
    /// the wiring level is exactly what silently deadlocked this task's own
    /// first pass at testing it: a receipt scanned at a test's fixed, long-past
    /// `now` looked "given up" against the real clock, `due()` came back
    /// empty, and a gated fake tax cabinet was never asked — so a test
    /// waiting on that request hung forever.
    @MainActor
    @discardableResult
    func fetchDueReceipts(maxRequests: Int = .max,
                          now: @escaping () -> Date = { Date() }) async -> ReceiptFetcher.Outcome {
        if receiptFetcher == nil { receiptFetcher = makeReceiptFetcher(now: now) }
        let fetcher = receiptFetcher!
        return await fetcher.run(maxRequests: maxRequests)
    }

    /// The foreground-activation entry point — what `RootView`'s
    /// `scenePhase` handler calls when the app opens. Needs the SAME
    /// suppression `startSyncIfConnected` applies to a sync; see that
    /// method's comment on `AppStore+Sync.swift` for why: `-skipOnboarding`
    /// pairs with a bundled fixture several UI suites assert exact totals
    /// against, and a live fetch would mutate it out from under them on
    /// every launch.
    ///
    /// `skipOnboarding`/`noDemoData` are parameters, defaulting to the real
    /// `Launch` flags, rather than read from `Launch` directly in the body:
    /// those flags are fixed for the whole life of a process, and this test
    /// bundle's process is never launched with `-skipOnboarding`, so a test
    /// could not otherwise reach the branch that suppresses the fetch.
    @MainActor
    @discardableResult
    func fetchDueReceiptsIfAllowed(maxRequests: Int = .max,
                                    now: @escaping () -> Date = { Date() },
                                    skipOnboarding: Bool = Launch.skipOnboarding,
                                    noDemoData: Bool = Launch.noDemoData) async -> ReceiptFetcher.Outcome? {
        guard !skipOnboarding || noDemoData else { return nil }
        return await fetchDueReceipts(maxRequests: maxRequests, now: now)
    }

    /// Stored on `AppStore` as `@ObservationIgnored var receiptFetcher: ReceiptFetcher?`.
    @MainActor
    private func makeReceiptFetcher(now: @escaping () -> Date = { Date() }) -> ReceiptFetcher {
        // Captured ONCE, here, and carried by every closure below that
        // writes — exactly as `makeSyncEngine` captures `syncGeneration`, one
        // host over. `wipeForNewClient` and `resetEverything` move the store
        // past this value, and from that moment this fetcher — an actor
        // parked inside a tax-cabinet request, which cannot be stopped from
        // here — can no longer put anything back. See
        // `AppStore.abandonReceiptFetch`.
        let generation = receiptGeneration
        return ReceiptFetcher(.init(
            // Board #186. Wrapped HERE rather than at injection, so a test
            // that hands the store a fake `taxCabinetAPI` still exercises the
            // same wiring the app runs — the wrapper falls straight through to
            // that fake whenever there is no mailbox, which is every unit test
            // that has not deliberately set one up.
            api: ServerFirstTaxCabinet(
                direct: taxCabinetAPI,
                api: emailAPI,
                credentials: { [weak self] in
                    await MainActor.run { self?.privatEmailCredentials }
                },
                now: { now() }),
            now: now,
            sleep: { try await Task.sleep(for: .seconds($0)) },
            due: { [weak self] in
                await MainActor.run { ReceiptSchedule.due(self?.receiptQueue ?? [], now: now()) }
            },
            // Gated the same way `makeSyncEngine`'s `commit` is: a receipt
            // fetched for a dataset that has since been wiped must be
            // dropped, not landed in the one that replaced it.
            commit: { [weak self] receiptId, parsed in
                await MainActor.run {
                    guard let self, self.isCurrentReceiptFetch(generation) else { return }
                    self.landItems(parsed, on: receiptId, now: now())
                }
            },
            // `failFetch` advances a backoff — a write, exactly like
            // `commit` — so it is gated too, and for the same reason: a
            // failure belonging to an abandoned generation must not touch a
            // queue entry that (however briefly) still carries the same id.
            fail: { [weak self] receiptId, error in
                await MainActor.run {
                    guard let self, self.isCurrentReceiptFetch(generation) else { return }
                    self.failFetch(receiptId, reason: error, now: now())
                }
            }))
    }
}

/// The two questions a receipt can leave for the user. Everything else —
/// still waiting on its goods, still inside its retry window, already
/// attached — is work in progress, not a card: showing it would ask the user
/// to answer something the app is already handling on its own.
///
/// Owned by the store rather than the UI task, on purpose: `AppStore` is the
/// one place every member gets a test, and a view computing this itself is
/// how a store grows state nothing ever covers.
enum ReceiptCard: Identifiable, Equatable {
    /// Its items landed, no transaction claims it, and the automatic match
    /// already ran — at scan time, and after every `ingest` since — and found
    /// nothing. Only the user can say which purchase this was, or that it was
    /// cash and there is no purchase to find.
    case noPurchase(Receipt)
    /// Still no items after 48 hours (`ReceiptSchedule.hasGivenUp`): the
    /// queue has stopped asking on its own. Only the user's retry restarts it.
    case notPublished(Receipt)
    /// **The goods arrived and nobody has sorted them. Board #185.**
    ///
    /// The owner: «I think it needs to be placed in the queue itself, combined
    /// with the categorization itself.» This case is what makes that true
    /// rather than approximate — before it, a receipt whose items published
    /// hours after the purchase was categorized left the person no way back to
    /// those items except finding the transaction again in the feed and
    /// expanding it. Nothing on any screen said there was anything to find.
    ///
    /// Unlike its two siblings this receipt is **attached** to a purchase, so
    /// it is not a question about which purchase it belongs to — it is work
    /// waiting to be done, in the one place the person already does that work.
    case itemsWaiting(Receipt)

    var id: UUID {
        switch self {
        case .noPurchase(let receipt): return receipt.id
        case .notPublished(let receipt): return receipt.id
        case .itemsWaiting(let receipt): return receipt.id
        }
    }
}

extension AppStore {
    /// A receipt still inside its retry window with no items yet is
    /// deliberately NOT a card — see `ReceiptCard`'s doc comment.
    ///
    /// Takes `now` explicitly, rather than reading the wall clock itself, for
    /// the same reason every other clock-sensitive member here does: the
    /// 48-hour boundary this depends on (`ReceiptSchedule.hasGivenUp`) must be
    /// something a test can walk without waiting in real time, and something
    /// `@Observable` has an actual chance to react to when the caller re-reads
    /// it against a fresh `Date()` rather than one baked into a stored
    /// property nothing ever invalidates.
    func receiptCards(now: Date = Date()) -> [ReceiptCard] {
        let questions: [ReceiptCard] = looseReceipts.compactMap { receipt in
            if receipt.itemsLandedAt != nil {
                return .noPurchase(receipt)
            }
            guard let pending = receiptQueue.first(where: { $0.receiptId == receipt.id }),
                  ReceiptSchedule.hasGivenUp(pending, now: now) else {
                return nil
            }
            return .notPublished(receipt)
        }
        // AFTER the two questions, on purpose. Those are things the app cannot
        // resolve without the person; this is work the person can now do
        // because the app finished its half. Answer what is blocked first.
        return questions + receiptsAwaitingItemSort.map { .itemsWaiting($0) }
    }

    /// Receipts whose goods have landed on a purchase nobody has sorted yet.
    /// Board #185.
    ///
    /// **Attached, unlike `looseReceipts`** — which is what makes this a
    /// different list rather than a third branch of the same `compactMap`. A
    /// loose receipt is a question about WHICH purchase; these already know,
    /// and are waiting on what was in the bag.
    ///
    /// `splits.isEmpty` is the test for "not sorted", because `confirmSplits`
    /// is the only thing that ever writes them and it writes nothing on a
    /// refusal. A receipt with no items at all is excluded: there is nothing
    /// to sort, and offering to sort nothing is worse than staying quiet.
    var receiptsAwaitingItemSort: [Receipt] {
        receipts.filter { receipt in
            guard receipt.itemsLandedAt != nil, !receipt.items.isEmpty else { return false }
            guard let transaction = transactions.first(where: { $0.receiptId == receipt.id })
            else { return false }
            return transaction.splits.isEmpty
        }
    }
}
