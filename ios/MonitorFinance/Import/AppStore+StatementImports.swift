import Foundation

/// Board #148 — listing imported statements, and undoing one.
///
/// The owner asked for both halves of the delete and for the choice to be
/// theirs: «ask the user whether to delete just the file or with transactions».
/// So there is no single `delete`; there are two named operations, and the
/// screen puts the question before the tap rather than reporting afterwards.
extension AppStore {

    /// What «Видалити разом з операціями» would actually cost, asked BEFORE it
    /// happens.
    ///
    /// `decided` is the number the person cares about and the reason this
    /// returns a pair: a row they have already categorized, split or skipped
    /// carries work that no import can give back, and "412 rows" hides it.
    /// This project has been here before — the budget scope card states its
    /// cost before the tap for the same reason.
    ///
    /// Counts only rows that are still present: a row already deleted by hand
    /// is not a cost of doing this.
    @MainActor
    func statementDeletionCost(_ record: StatementImport) -> (rows: Int, decided: Int) {
        let ids = Set(record.created)
        let live = transactions.filter { ids.contains($0.id) }
        return (rows: live.count,
                decided: live.filter { $0.resolution != .pending }.count)
    }

    /// «Видалити лише файл» — forget the record, keep every transaction.
    ///
    /// The statement was a delivery, not the data. This is the answer for
    /// "I do not need this file listed any more", and it is deliberately
    /// incapable of touching history.
    @MainActor
    func forgetStatementImport(_ id: StatementImport.ID) {
        removeStatementImport(id)
        persistNow()
    }

    /// «Видалити разом з операціями» — forget the record AND remove the rows
    /// this file brought into being.
    ///
    /// **Only `created`, which is the whole safety of this operation.** A row
    /// the statement merged into (`PrivatCrossSource`, in `applyStatement`)
    /// was delivered by a notification letter first, exists independently of
    /// this file, and would still be here had the file never been imported.
    /// Taking it would delete history that came from somewhere else.
    ///
    /// Splits ride inside the transaction, so they go with it. A receipt that
    /// pointed at a removed row simply becomes loose again — a state the app
    /// already models and re-matches from — so nothing is stranded.
    @MainActor
    func deleteStatementImport(_ id: StatementImport.ID) {
        guard let record = statementImports.first(where: { $0.id == id }) else { return }
        let ids = Set(record.created)

        // `receiptQueue` is deliberately NOT touched. Its entries are keyed by
        // RECEIPT, not by transaction: a receipt whose transaction goes away is
        // a loose receipt, which is a state the app already models and
        // re-matches from — `matchLooseReceipts` exists for exactly this. An
        // earlier version of this method removed queue entries here and would
        // have thrown away receipts still waiting on the tax cabinet for their
        // goods, for no reason at all.
        transactions.removeAll { ids.contains($0.id) }
        removeStatementImport(id)
        persistNow()
    }
}
