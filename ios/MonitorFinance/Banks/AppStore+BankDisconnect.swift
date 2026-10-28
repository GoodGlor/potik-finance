import Foundation

/// Board #157 — disconnecting a bank asks whether the transactions go too.
///
/// The owner: «I think you need to ask the user when he deletes the bank
/// whether to delete transactions as well.» That is the same choice board #148
/// already built for a statement file, so the interaction is COPIED, not
/// redesigned: two named actions and no default, the cost stated before the
/// tap, and counts that are grammatical Ukrainian.
///
/// Keeping the history stays the default. `disconnect`'s own comment has said
/// so from the beginning — «History stays — it is the user's, not the bank's»
/// — and nothing here changes that. What was missing was the other answer.
extension AppStore {

    /// **What "the bank's transactions" means, decided and written down.**
    ///
    /// A statement could answer this exactly, because `StatementImport.created`
    /// records the ids one file brought into being. A bank has no such record,
    /// and the obvious substitute is wrong in an interesting way:
    /// `transactions.filter { $0.bankId == bankId }` is everything the bank
    /// ever delivered, including rows a statement import also claims —
    /// PrivatBank rows arrive by letter AND by file, and `PrivatCrossSource`
    /// merges them.
    ///
    /// **This takes all of them anyway**, which is option (1) on the card, and
    /// the reason is that the alternative is worse for the person rather than
    /// merely harder. Excluding rows a live `StatementImport` claims would
    /// leave a "disconnected" bank with transactions still in the feed, still
    /// carrying its `bankId`, and no screen anywhere offering to remove them —
    /// the person answered «разом з операціями» and the operations stayed.
    ///
    /// The statements list is kept honest by `pruneEmptyStatementImports`
    /// instead: an import whose rows are all gone stops being listed, so it
    /// cannot go on offering an undo for rows that no longer exist.
    @MainActor
    func bankTransactionIds(bankId: String) -> Set<UUID> {
        Set(transactions.filter { $0.bankId == bankId }.map(\.id))
    }

    /// **Board #166 — a bank the person disconnected that still owns rows.**
    ///
    /// `BanksSettingsView` lists `connectedBanks` and nothing else, so the
    /// moment a bank is disconnected its row disappears — taking with it the
    /// only screen in the app that offers «Відключити разом з операціями».
    /// The person was asked the question exactly once, at the instant of
    /// disconnecting, and could never revisit it: the rows stayed in the feed,
    /// the queue, Home and statistics, and the only remaining route to them was
    /// «Скинути додаток», which costs the passcode, every token, every rule and
    /// every decision they had made.
    ///
    /// **The rows are theirs and stay by design** — board #157, at the owner's
    /// own request. What this fixes is the door locking behind them.
    ///
    /// A disconnected bank with NO rows left is deliberately absent: there is
    /// nothing to act on, and listing it would make the list grow forever as a
    /// museum of banks somebody once tried.
    var pastBanks: [Bank] {
        let owned = Set(transactions.map(\.bankId))
        return banks.filter { !$0.connected && owned.contains($0.id) }
    }

    /// What «Відключити разом з операціями» would cost, asked BEFORE it runs.
    ///
    /// `decided` is the number the person actually cares about, and the reason
    /// this returns a pair — exactly as `statementDeletionCost` argues. A row
    /// they have already categorized, split or skipped carries work no
    /// re-import gives back, and a single total hides it.
    ///
    /// Counts only rows still present: one deleted by hand is not a cost of
    /// doing this.
    @MainActor
    func bankDisconnectCost(bankId: String) -> (rows: Int, decided: Int) {
        let live = transactions.filter { $0.bankId == bankId }
        return (rows: live.count,
                decided: live.filter { $0.resolution != .pending }.count)
    }

    /// Removes the rows this bank delivered, and nothing else.
    ///
    /// **`receiptQueue` is deliberately untouched.** Board #148 learned this
    /// the expensive way: its entries are keyed by RECEIPT, not by
    /// transaction, so clearing them here would throw away receipts still
    /// waiting on the tax cabinet for their goods. A receipt whose transaction
    /// goes away becomes loose, which `matchLooseReceipts` already models.
    ///
    /// Splits ride inside their transaction, so they go with it.
    @MainActor
    func removeTransactions(ofBank bankId: String) {
        let ids = bankTransactionIds(bankId: bankId)
        guard !ids.isEmpty else { return }
        transactions.removeAll { ids.contains($0.id) }
        pruneEmptyStatementImports()
    }

    /// Drops any statement record whose rows have all gone.
    ///
    /// Without this the two lists disagree: «Виписки» would go on listing a
    /// file and offering «Видалити разом з операціями» for transactions that
    /// no longer exist, which is an undo that silently does nothing. A record
    /// that still has SOME rows is kept — it can still undo those.
    ///
    /// Goes through `removeStatementImport` rather than writing the array.
    /// `statementImports` is `private(set)`, Swift scopes a private setter to
    /// the FILE, and `AppStore.swift` keeps its writers beside the declaration
    /// on purpose so the compiler enforces that rather than convention.
    /// Reusing the writer keeps it true without adding a third one.
    @MainActor
    func pruneEmptyStatementImports() {
        let alive = Set(transactions.map(\.id))
        let empty = statementImports.filter { record in
            !record.created.isEmpty && record.created.allSatisfy { !alive.contains($0) }
        }
        for record in empty { removeStatementImport(record.id) }
    }
}
