import Foundation

extension AppStore {
    static let emailUserIdKey = "privat-email.userId"
    static let emailSecretKey = "privat-email.secret"
    static let emailAddressKey = "privat-email.address"

    /// Registered = the pair is in the Keychain. There is deliberately no
    /// second "connected" boolean to drift from it.
    var privatEmailCredentials: PrivatEmailCredentials? {
        guard let userId = keychain.getString(Self.emailUserIdKey),
              let secret = keychain.getString(Self.emailSecretKey) else { return nil }
        return PrivatEmailCredentials(userId: userId, secret: secret)
    }

    var privatEmailAddress: String? { keychain.getString(Self.emailAddressKey) }

    enum EmailRegisterOutcome: Equatable {
        case registered(String)         // the issued address
        case alreadyRegistered(String)
        case failed(PrivatEmailError)
    }

    /// One account per device. The backend shows the secret exactly once,
    /// so the Keychain write is checked, not `try?` — losing it silently
    /// would burn one of the 5 registrations an hour this IP gets.
    @MainActor
    func registerPrivatEmail() async -> EmailRegisterOutcome {
        // Gated on credentials alone, NOT credentials-and-address: a stored
        // pair with a missing address is a corrupt-but-recoverable state (a
        // partial write, a manual reset), not "never registered". Calling
        // `register()` again here would burn one of the 5/hour the backend
        // allows AND mint a phantom second account on the same device.
        // Getting the address back (asking the backend again) is issue #91's
        // screen, not this function's job.
        if privatEmailCredentials != nil {
            return .alreadyRegistered(privatEmailAddress ?? "")
        }
        let registration: PrivatEmailRegistration
        do {
            registration = try await emailAPI.register()
        } catch let error as PrivatEmailError {
            return .failed(error)
        } catch {
            return .failed(.offline(error.localizedDescription))
        }
        do {
            try keychain.setString(registration.secret, for: Self.emailSecretKey)
            try keychain.setString(registration.userId, for: Self.emailUserIdKey)
            try keychain.setString(registration.email, for: Self.emailAddressKey)
        } catch {
            forgetPrivatEmail()
            return .failed(.malformed("keychain write failed"))
        }
        // A `forgetPrivatEmail()` + re-register lands here against a NEW
        // server account whose row ids restart at 1. `PrivatEmailMapper`
        // folding `userId` into the identity stops that account's row 1
        // colliding with the OLD account's row 1 still in the store, but a
        // left-alone cursor would still tell the new account "everything up
        // to N is already imported" — its own letters would never arrive.
        // Nothing has ever synced against the real backend yet, so there is
        // no history this reset could be discarding.
        syncState.emailCursor = 0
        syncState.emailNeedsReconnect = false
        // Board #111. Set HERE and cleared in `disconnectPrivatEmail`, so it
        // means exactly "an address exists that this phone was given" — and it
        // lives in `sync.json` rather than the Keychain so it outlives the
        // secret, which is the whole point.
        syncState.emailAddressIssued = true
        // Email is a mode of the PrivatBank entry, not a bank of its own, so a
        // successful registration connects that entry exactly the way
        // `applyStatement` does — no token, and no accounts, because a letter
        // carries no balance to build one from. Just the flag that the banks
        // list and onboarding's «Готово» both read.
        if let b = banks.firstIndex(where: { $0.id == PrivatMapper.bankId }) {
            banks[b].connected = true
        }
        // `persistNow()`, not `persist()`. The Keychain writes above are
        // immediate and the debounce is 300 ms, so a kill inside that window
        // left the NEW credentials beside the OLD cursor — and the symptom is
        // "no letters ever arrive", with nothing on screen to say why.
        // Registration happens once per device; the debounce buys nothing.
        persistNow()
        return .registered(registration.email)
    }

    /// Local half only — the server account (and `DELETE /account`) is
    /// issue #91's screen, which decides what the person is told.
    @MainActor
    func forgetPrivatEmail() {
        keychain.delete(Self.emailUserIdKey)
        keychain.delete(Self.emailSecretKey)
        keychain.delete(Self.emailAddressKey)
    }

    enum EmailDisconnectOutcome: Equatable {
        case disconnected
        case failed(PrivatEmailError)
    }

    /// Stop importing. **Keeps the address, the secret and the server
    /// account**, so resuming needs no registration and issues nothing new.
    ///
    /// Board #158, and it deliberately reverses board #91. #91 deleted the
    /// account here, and its reasoning was sound: an address nobody reads
    /// should stop collecting a person's mail. What it did not weigh is that
    /// **there is no route back.** `POST /register` mints a new random
    /// address; the backend has no "give me my old mailbox" call, so the
    /// address survives exactly as long as the Keychain secret does. That made
    /// the one irreplaceable thing in the app the easiest to destroy — by
    /// disconnecting the BANK, which called this without saying so.
    ///
    /// The owner chose the opposite, and this is the decision of record. #91's
    /// cost is not denied, it is accepted and written down: letter bodies are
    /// discarded on arrival, but `from` and `subject` are kept indefinitely,
    /// so a paused mailbox accumulates a list of who wrote and about what. A
    /// true server-side pause — account alive, mail stopped — is backend work
    /// and a bigger card than this one.
    ///
    /// The cursor is **not** reset: the address is unchanged, so the rows
    /// behind it are the same rows, and restarting from 0 would re-import
    /// every letter this phone already has.
    @MainActor
    func pausePrivatEmail() {
        syncState.emailPaused = true
        persistNow()
    }

    /// Resume, against the same address. No network, no registration.
    @MainActor
    func resumePrivatEmail() {
        syncState.emailPaused = false
        persistNow()
    }

    /// True when letters should be imported: an address this phone holds the
    /// secret for, and not paused.
    var privatEmailIsActive: Bool {
        privatEmailCredentials != nil && !syncState.emailPaused
    }

    /// **The one path that destroys an address** — board #158's «Змінити
    /// адресу». Deletes the server account, forgets the local half, and
    /// leaves the caller to register a fresh one.
    ///
    /// This is what «Відключити пошту» used to do silently. It is now the only
    /// thing that does it, it is labelled for what it costs, and the old
    /// address stops accepting mail the moment it runs — so the forwarding
    /// rule in the person's own mailbox has to be repointed by hand.
    ///
    /// `force` is the offline escape hatch. A failed delete deliberately keeps
    /// the local half — an account nothing can reach any more is worse than
    /// one still listed — but a person with no signal must still be able to
    /// proceed, having been told the old address will stay alive.
    ///
    /// **Board #170 made this one line.** Changing an address and deleting one
    /// are the same destruction; they differ only in what the screen offers
    /// next, and the screen is where that difference belongs. Two copies of
    /// the cursor/flag reset would have been two chances to forget one.
    @MainActor
    func changePrivatEmailAddress(force: Bool = false) async -> EmailDisconnectOutcome {
        await deletePrivatEmailAddress(force: force)
    }

    /// **Board #170 — ending the mailbox on purpose, with nothing in its
    /// place.** The deliberate act board #168 left homeless.
    ///
    /// «Змінити адресу» swaps one address for another and board #158's
    /// «Відключити пошту» pauses. Nothing *ended* a mailbox once the reset
    /// stopped doing it, and that is a real gap for somebody giving the phone
    /// away or leaving the app: the address stays live, goes on accepting
    /// mail, and `from`/`subject` are kept indefinitely — the privacy cost
    /// #158 accepted while the account was still the person's to end.
    ///
    /// **It does not touch the transactions.** Deleting an address and
    /// emptying the app are two deliberate acts in two places; folding either
    /// into the other is exactly what #168's screenshot rejected.
    ///
    /// `force` is the offline escape and is deliberately the second-best
    /// answer: forgetting locally leaves the server account alive with nobody
    /// able to read it — board #158's orphan. Offered after a failure, never
    /// first.
    @MainActor
    func deletePrivatEmailAddress(force: Bool = false) async -> EmailDisconnectOutcome {
        guard privatEmailCredentials != nil else { return .disconnected }
        if case .failed(let error) = await deletePrivatEmailAccount(), !force {
            return .failed(error)
        }
        forgetPrivatEmail()
        // Reset here and NOWHERE ELSE, which is board #158's rule: the cursor
        // moves only when the address itself ends. The next registration is a
        // new server account whose row ids restart at 1, so a cursor left at N
        // would claim everything up to N was already imported. A pause leaves
        // it alone — same address, same rows. Done even for a device that
        // never registers again, so nothing carries a cursor into a source it
        // no longer has.
        syncState.emailCursor = 0
        syncState.emailNeedsReconnect = false
        // A paused address that then ends is not paused any more: whatever
        // comes next is live from the moment it is issued. Left true, the
        // person would set the mail up again and watch nothing arrive.
        syncState.emailPaused = false
        // Board #111. Cleared here and nowhere else. This is the one way an
        // address stops existing on purpose, so after it there is no old
        // forwarding rule left to warn anybody about — and the next offer is
        // an ordinary first one, not a replacement.
        syncState.emailAddressIssued = false
        persistNow()
        return .disconnected
    }

    /// **The server half alone**, and nothing local. Written for board #158's
    /// «Видалити все»; board #168 took that caller away and board #170 gave it
    /// this one — `deletePrivatEmailAddress` is now its only use.
    ///
    /// Kept separate from the local forget because the order matters and only
    /// one of the two can fail: the secret is the sole thing that can ever
    /// reach this account again, so forgetting first would leave a live
    /// mailbox nobody can read, collecting `from` and `subject` for every
    /// letter, forever. That orphan is not hypothetical — it is what «Видалити
    /// все» did before #158.
    ///
    /// Returns the outcome rather than swallowing it: the screen decides
    /// whether to proceed anyway, because a person with no signal must not be
    /// trapped on an address they are trying to end.
    @MainActor
    func deletePrivatEmailAccount() async -> EmailDisconnectOutcome {
        guard let credentials = privatEmailCredentials else { return .disconnected }
        do {
            try await emailAPI.deleteAccount(credentials: credentials)
        } catch PrivatEmailError.unauthorized {
            // Already gone, or the secret is dead — nothing left to orphan.
        } catch let error as PrivatEmailError {
            return .failed(error)
        } catch {
            return .failed(.offline(error.localizedDescription))
        }
        return .disconnected
    }

    /// One request's worth of backlog. Hoisted so a test can build a full
    /// page without duplicating the number.
    static let emailPageLimit = 200

    /// Pulls everything past the cursor, page by page. No pacer — this backend
    /// has no request-rate contract; the loop ends when a page comes back
    /// shorter than `limit`.
    @MainActor
    @discardableResult
    func syncPrivatEmail(maxPages: Int = .max) async -> (imported: Int, merged: Int)? {
        // Board #158. A paused address still exists and its secret still
        // works, so `privatEmailCredentials` alone would keep importing after
        // the person asked it to stop.
        guard privatEmailIsActive, let credentials = privatEmailCredentials else { return nil }
        guard !isEmailSyncing else { return nil }
        isEmailSyncing = true
        let generation = syncGeneration
        defer { if isCurrentSync(generation) { isEmailSyncing = false } }

        var totals = (imported: 0, merged: 0)
        var pages = 0
        let limit = Self.emailPageLimit
        // Built once for the whole run, not once per page: a statement row
        // consumed by page 1's letter must stay consumed for page 2's, or
        // two letters for the same purchase split across a page boundary
        // both vanish into the one statement row that only exists once. See
        // `withoutRowsTheStatementAlreadyBrought`'s doc for the rest of it.
        var statementRows = statementRowIndex()
        while pages < maxPages {
            pages += 1
            let page: PrivatEmailPage
            do {
                page = try await emailAPI.transactions(credentials: credentials,
                                                       since: syncState.emailCursor,
                                                       limit: limit)
            } catch PrivatEmailError.unauthorized {
                guard isCurrentSync(generation) else { return nil }
                syncState.emailNeedsReconnect = true
                persist()
                return nil
            } catch {
                // Offline or a server hiccup: the next trigger retries. The
                // cursor is untouched, so nothing is skipped.
                return nil
            }
            // The store may have been wiped while the request was in flight —
            // this run's rows describe a dataset that no longer exists.
            guard isCurrentSync(generation) else { return nil }

            // Captured before the write below overwrites it — the stuck-cursor
            // guard needs to compare against where the loop STARTED this page.
            let previousCursor = syncState.emailCursor

            let rows = page.transactions.compactMap {
                PrivatEmailMapper.transaction($0, userId: credentials.userId)
            }
            let (kept, dropped) = withoutRowsTheStatementAlreadyBrought(
                rows, consuming: &statementRows)
            let (imported, merged) = ingestRows(kept)
            totals.imported += imported
            totals.merged += merged + dropped
            // Rows and cursor under one write — splitting them is either a
            // re-fetch (harmless) or a silent hole (not), same rule as ingest().
            syncState.emailCursor = page.nextCursor
            persistNow()

            // The real backend orders by an integer primary key, so a full
            // page can never fail to advance `nextCursor` in practice — but
            // this loop runs on the main actor and trusts a network value, so
            // a server that stalled on the cursor while still returning full
            // pages must not be allowed to spin forever and freeze the app.
            if page.transactions.count < limit || page.nextCursor <= previousCursor { break }
        }
        return totals
    }

    /// One entry per existing statement row, keyed by the cross-source
    /// (amount, balance) pair. Built once at the top of `syncPrivatEmail`,
    /// not per page — see that call site's comment.
    @MainActor
    private func statementRowIndex() -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, tx) in transactions.enumerated()
        where tx.externalId?.hasPrefix(PrivatMapper.externalIdPrefix) == true {
            if let key = PrivatCrossSource.key(amountMinor: tx.amount,
                                               balanceAfterMinor: tx.balanceAfterMinor) {
                index[key] = i
            }
        }
        return index
    }

    /// The other direction of `applyStatement`'s filter: letters for purchases
    /// a statement import already brought in. Returns the rows to ingest and
    /// how many were dropped, which the caller counts as merged.
    ///
    /// **The statement row is the one that survives**, and this is the one place
    /// the two halves are asymmetric. It is the richer record — real seconds, the
    /// full last-four suffix, and Privat's own category as a suggestion — and it
    /// may already have been decided in the queue. Keeping the letter instead
    /// would trade all of that for a minute-precision line.
    ///
    /// `statementRows` is `inout` and shared by the caller across every page
    /// of one run: a match consumed on page 1 must stay consumed on page 2,
    /// or two letters for the same purchase landing on different pages of
    /// the SAME sync would both vanish into the one statement row that only
    /// exists once — the per-call version of this guard only held within a
    /// single page. The cross-RUN case — a refund returning the balance to
    /// an earlier figure in a LATER sync, after the index has been rebuilt
    /// from scratch — is not guarded against; that coincidence was
    /// considered and left, deliberately, because guarding it would mean
    /// remembering every consumed match forever with no sound point to stop.
    @MainActor
    private func withoutRowsTheStatementAlreadyBrought(
        _ rows: [Transaction], consuming statementRows: inout [String: Int])
        -> (kept: [Transaction], dropped: Int) {
        guard !statementRows.isEmpty else { return (rows, 0) }

        var kept: [Transaction] = []
        var dropped = 0
        for row in rows {
            if let key = PrivatCrossSource.key(amountMinor: row.amount,
                                               balanceAfterMinor: row.balanceAfterMinor),
               let i = statementRows[key],
               PrivatCrossSource.matches(date: row.date, suffix: row.cardSuffix,
                                         candidateDate: transactions[i].date,
                                         candidateSuffix: transactions[i].cardSuffix) {
                dropped += 1
                // One statement row is one purchase — same reason as the
                // import side: two letters must not both vanish into it.
                statementRows.removeValue(forKey: key)
                continue
            }
            kept.append(row)
        }
        return (kept, dropped)
    }

    // MARK: - Board #97, a statement emailed to the issued address

    /// What is waiting on the backend, without its bytes.
    ///
    /// Separate from the fetch because they cost different things: this
    /// answers "is there anything to import?" and a person's whole financial
    /// history is a megabyte-scale file. A screen must not pull one down to
    /// find out there was nothing.
    @MainActor
    func privatEmailStatements() async throws -> [PrivatEmailStatement] {
        guard let credentials = privatEmailCredentials else { throw PrivatEmailError.unauthorized }
        do {
            return try await emailAPI.statements(credentials: credentials).statements
        } catch {
            noteIfUnauthorized(error)
            throw error
        }
    }

    // MARK: - Board #145, a statement that arrived as a LINK

    /// Links waiting on the backend.
    ///
    /// **There is no companion fetch, and that is the whole design.** The
    /// server has already unwrapped Amazon's click tracker and checked that
    /// the destination is PrivatBank's own, but nothing on either side
    /// FOLLOWS it: the person opens it in their own browser, downloads the
    /// file, and imports it with the picker board #97 already built.
    ///
    /// `docs/privat-statement-letters.md` in the backend repo records why a
    /// fetcher was rejected — every link is SES-wrapped, so a host allowlist
    /// would refuse the real one, and «ЗАВАНТАЖИТИ ІСТОРІЮ» shares its host
    /// AND its path with «Контакти».
    ///
    /// A backend that predates this card answers 404, which is not an error
    /// worth showing anybody: an older server simply has no links to offer.
    @MainActor
    func privatEmailStatementLinks() async -> [PrivatEmailStatementLink] {
        guard let credentials = privatEmailCredentials else { return [] }
        do {
            return try await emailAPI.statementLinks(credentials: credentials).links
        } catch PrivatEmailError.server(404, _) {
            return []
        } catch {
            noteIfUnauthorized(error)
            return []
        }
    }

    /// Shown, or dismissed. Either way stop offering it.
    ///
    /// `try?` for the same reason `importEmailedStatement`'s consume is: the
    /// person has already been handed the link, and failing that gesture
    /// because a bookkeeping call did not land would be reporting a problem
    /// they do not have. The backend's retention clears it regardless.
    @MainActor
    func forgetStatementLink(_ link: PrivatEmailStatementLink) async {
        guard let credentials = privatEmailCredentials else { return }
        try? await emailAPI.consumeStatementLink(credentials: credentials, id: link.id)
    }

    /// **Board #171 — ask the server to follow the link, then import what it
    /// got.** The owner: «the statement should be downloaded automatically,
    /// and not the user to download it and paste it somewhere».
    ///
    /// Two calls rather than one route that does everything, because they fail
    /// differently and the person needs to be told which happened: the bank
    /// may not answer, or the file may not parse, and «не вдалося завантажити»
    /// and «файл не читається» send somebody to check different things.
    ///
    /// The download answers with an ordinary `PrivatEmailStatement`, so the
    /// import goes through `importEmailedStatement` — the same entry point the
    /// file picker and the emailed-attachment path already use. Board #97's
    /// decision holds: `PrivatStatementParser` stays the only parser in the
    /// system, and `applyStatement`'s cross-source dedup applies here without
    /// a line of new code.
    @MainActor
    @discardableResult
    func downloadStatementLink(_ link: PrivatEmailStatementLink) async throws -> ImportSummary {
        guard let credentials = privatEmailCredentials else { throw PrivatEmailError.unauthorized }
        let statement: PrivatEmailStatement
        do {
            statement = try await emailAPI.downloadStatementLink(credentials: credentials,
                                                                 id: link.id)
        } catch {
            noteIfUnauthorized(error)
            throw error
        }
        return try await importEmailedStatement(statement)
    }

    /// Fetch, parse, and stop it being offered again.
    ///
    /// **The bytes go through `importPrivatStatement`, the same entry point
    /// the file picker uses.** That is board #97's decision made structural:
    /// `PrivatStatementParser` stays the only parser in the system, and the
    /// cross-source dedup in `applyStatement` — which reconciles a statement
    /// row against the same purchase already delivered by a notification
    /// letter — applies here without a line of new code. The card's third box
    /// is satisfied by routing the bytes, not by writing a matcher.
    ///
    /// **Consumed only after the import succeeded.** A throw leaves the
    /// statement on the server: a person whose import failed still has the
    /// file, and the backend's own retention clears it either way. The
    /// consume is `try?` because losing it is not worth failing an import
    /// that already landed — the row is idempotent and the next sweep takes
    /// it regardless.
    @MainActor
    @discardableResult
    func importEmailedStatement(_ statement: PrivatEmailStatement) async throws -> ImportSummary {
        guard let credentials = privatEmailCredentials else { throw PrivatEmailError.unauthorized }
        let data: Data
        do {
            data = try await emailAPI.statementBytes(credentials: credentials, id: statement.id)
        } catch {
            noteIfUnauthorized(error)
            throw error
        }
        let summary = try importPrivatStatement(data, filename: statement.filename)
        try? await emailAPI.consumeStatement(credentials: credentials, id: statement.id)
        return summary
    }

    /// **Board #175 — the last few letters, so «нічого не прийшло» and «прийшло
    /// й не зрозуміли» stop looking identical.**
    ///
    /// The owner: «I think you can briefly show the last 2-3 letters, not all
    /// of them, but part of the flood that come to the mail from Privat Bank.»
    ///
    /// Metadata only, and the cap is the server's — the phone cannot ask for
    /// more, which is what keeps this a window rather than a mailbox.
    ///
    /// Returns `[]` rather than throwing, like `privatEmailStatementLinks`:
    /// this is a decoration on a screen the person came to for something else,
    /// and a backend that predates the route answers 404. An error here must
    /// not paint over a screen whose every other part works — the forwarding
    /// CODE lives on that screen, and it is the one thing setup cannot finish
    /// without.
    @MainActor
    func privatEmailRecentLetters() async -> [PrivatEmailRecentLetter] {
        guard let credentials = privatEmailCredentials else { return [] }
        do {
            return try await emailAPI.recentLetters(credentials: credentials).letters
        } catch PrivatEmailError.server(404, _) {
            return []
        } catch {
            noteIfUnauthorized(error)
            return []
        }
    }

    /// `GET /status`. Also the recovery for a stored pair whose address went
    /// missing: the backend is authoritative about the address it issued, so a
    /// successful call writes it back and `.alreadyRegistered("")` heals
    /// itself the moment a screen loads.
    @MainActor
    func privatEmailStatus() async throws -> PrivatEmailStatus {
        guard let credentials = privatEmailCredentials else { throw PrivatEmailError.unauthorized }
        do {
            let status = try await emailAPI.status(credentials: credentials)
            if !status.email.isEmpty, status.email != privatEmailAddress {
                try? keychain.setString(status.email, for: Self.emailAddressKey)
            }
            return status
        } catch {
            noteIfUnauthorized(error)
            throw error
        }
    }

    /// `GET /letters/pending`. The forwarding confirmation code lives here,
    /// and without it a Gmail rule is never activated at all — which is the
    /// whole reason the setup screen exists.
    @MainActor
    func privatEmailPending() async throws -> PrivatEmailPending {
        guard let credentials = privatEmailCredentials else { throw PrivatEmailError.unauthorized }
        do {
            return try await emailAPI.pendingLetters(credentials: credentials)
        } catch {
            noteIfUnauthorized(error)
            throw error
        }
    }

    /// One 401 rule for every read, matching `syncPrivatEmail`'s: the secret is
    /// dead, sync must stop, and this flag is what puts the line on Головна. It
    /// is never lowered here — only a fresh registration clears it, because
    /// only a fresh registration fixes it.
    @MainActor
    private func noteIfUnauthorized(_ error: Error) {
        guard let known = error as? PrivatEmailError, known == .unauthorized else { return }
        syncState.emailNeedsReconnect = true
        persistNow()
    }

    /// How many purchases arrived as letters. Derived from the externalId
    /// prefix rather than stored: that prefix is already the source of truth
    /// for which rows a letter brought, and a second counter would be one more
    /// thing to keep in step with a wipe.
    var privatEmailRowCount: Int {
        transactions.reduce(into: 0) {
            if $1.externalId?.hasPrefix(PrivatEmailMapper.externalIdPrefix) == true { $0 += 1 }
        }
    }

    /// The newest letter THIS PHONE holds — deliberately not the backend's
    /// `last_letter_at`. It is what the person's app can actually show, and it
    /// needs no request to answer.
    var privatEmailNewestDate: Date? {
        transactions.lazy
            .filter { $0.externalId?.hasPrefix(PrivatEmailMapper.externalIdPrefix) == true }
            .map(\.date).max()
    }

    /// The trigger-facing gate, mirroring `startSyncIfConnected`: registered,
    /// not flagged for reconnect, and not a fixture-protected UI-test launch.
    @MainActor
    @discardableResult
    func syncPrivatEmailIfConnected(maxPages: Int = .max) async -> (imported: Int, merged: Int)? {
        guard privatEmailCredentials != nil, !syncState.emailNeedsReconnect else { return nil }
        // Same fixture guard as startSyncIfConnected, same reason: a
        // `-skipOnboarding` launch runs against a bundled dataset many UI
        // suites assert exact totals on.
        guard !Launch.skipOnboarding || Launch.noDemoData else { return nil }
        return await syncPrivatEmail(maxPages: maxPages)
    }
}
