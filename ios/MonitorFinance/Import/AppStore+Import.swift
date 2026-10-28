import Foundation

/// What the summary screen reports. Hashable so it can ride in a
/// NavigationStack path value.
struct ImportSummary: Hashable {
    var imported: Int
    var merged: Int
    var skippedNonUAH: Int
    var period: ClosedRange<Date>?
    var cardSuffixes: [String]
}

extension AppStore {
    /// The whole import: bytes → rows → transactions → the same
    /// merge/dedup/rules pipeline sync uses. Nothing is written unless
    /// parsing succeeded in full — every throw happens before `ingestRows`.
    @MainActor
    @discardableResult
    /// `filename` has **no default**, and both production call sites know one
    /// (`ImportStatementView`'s picked URL, the emailed statement's own name).
    /// A default here is exactly how a call site keeps silently recording
    /// nothing, and board #148's whole list is the filename.
    func importPrivatStatement(_ data: Data, filename: String) throws -> ImportSummary {
        try applyStatement(PrivatStatementParser.parse(XLSXReader.rows(from: data)),
                           filename: filename)
    }

    /// Everything after the parse. Split out from `importPrivatStatement` so a
    /// test can hand the store rows without also having to author a valid xlsx
    /// archive to carry them — the parse half stays covered by the fixture
    /// tests that already read real bytes.
    @MainActor
    @discardableResult
    func applyStatement(_ statement: PrivatStatement, filename: String) -> ImportSummary {
        // Board #148. Captured BEFORE the ingest so the diff after it names
        // exactly the rows this file brought into being — never the ones it
        // merged into. `ingestRows` reports counts, not identities, and is
        // shared with sync, so this is read here rather than by changing a
        // signature sync depends on.
        let before = Set(transactions.map(\.id))
        // A purchase the notification letters already delivered must not land a
        // second time under its statement identity — the two sources cannot
        // produce the same `externalId`, so `ingestRows` alone would see two
        // unrelated rows. `PrivatCrossSource` explains why the amount/balance
        // pair is the only thing they can be matched on.
        //
        // The letter's row is the one that stays: it is already in the queue,
        // may already carry a rule's answer, and replacing it would ask the
        // person a question they have answered.
        var emailRows: [String: Int] = [:]
        for (i, tx) in transactions.enumerated()
        where tx.externalId?.hasPrefix(PrivatEmailMapper.externalIdPrefix) == true {
            if let key = PrivatCrossSource.key(amountMinor: tx.amount,
                                               balanceAfterMinor: tx.balanceAfterMinor) {
                emailRows[key] = i
            }
        }

        var mapped: [Transaction] = []
        var crossMerged = 0
        for row in statement.rows {
            let tx = PrivatMapper.transaction(row)
            if let key = PrivatCrossSource.key(amountMinor: tx.amount,
                                               balanceAfterMinor: tx.balanceAfterMinor),
               let i = emailRows[key],
               PrivatCrossSource.matches(date: tx.date, suffix: tx.cardSuffix,
                                         candidateDate: transactions[i].date,
                                         candidateSuffix: transactions[i].cardSuffix) {
                crossMerged += 1
                // One letter can only be one purchase. Without this, a second
                // statement row carrying the same pair would vanish into the
                // same letter — a running balance makes that all but
                // impossible, and "all but" is not a reason to lose a row.
                emailRows.removeValue(forKey: key)
                // The letter carried no category and the statement does, so
                // the queue's card can finally offer a chip. Only while the
                // row is still the queue's, and only when it has nothing to
                // offer yet: a decided row must never be re-opened, and a
                // re-import must not append the same word twice.
                if transactions[i].resolution == .pending,
                   transactions[i].suggestions.isEmpty, !row.category.isEmpty {
                    transactions[i].suggestions = [row.category]
                }
                continue
            }
            mapped.append(tx)
        }
        let (imported, ownMerged) = ingestRows(mapped)
        // A cross-source match IS a merge as far as the person is concerned —
        // the summary screen counts rows that did not become new rows.
        let merged = ownMerged + crossMerged

        // One account per non-empty UAH card suffix; the newest row of each
        // suffix carries that card's balance. The empty-suffix interest rows
        // and foreign-currency cards create nothing.
        //
        // This filter keys on `row.balanceCurrency` (column J, "Валюта
        // залишку"); the parser's own non-UAH skip (`skippedNonUAH`, in
        // `PrivatStatementParser`) keys on the CARD's currency instead
        // (column F, "Валюта картки"), and only column F is guarded against
        // being empty. So a row with F == "UAH" but a blank or foreign J
        // still imports its transaction (via `ingestRows` above) while
        // contributing nothing here — a card with transaction history and no
        // balance row. This is spec-compliant and intentional, not a bug to
        // fix: it just was not obvious from reading either function alone.
        var suffixes: [String] = []
        if let b = banks.firstIndex(where: { $0.id == "privatbank" }) {
            var newest: [String: PrivatRow] = [:]
            for row in statement.rows where !row.cardSuffix.isEmpty && row.balanceCurrency == "UAH" {
                if row.date > (newest[row.cardSuffix]?.date ?? .distantPast) {
                    newest[row.cardSuffix] = row
                }
            }
            for (suffix, row) in newest.sorted(by: { $0.key < $1.key }) {
                let id = "privat-" + suffix.dropFirst()
                if let a = banks[b].accounts.firstIndex(where: { $0.id == id }) {
                    banks[b].accounts[a].balance = row.balanceMinor
                } else {
                    banks[b].accounts.append(Account(
                        id: id, suffix: suffix, type: "card",
                        currency: "UAH", balance: row.balanceMinor, creditLimit: nil))
                }
                suffixes.append(suffix)
            }
            banks[b].connected = true
        }
        // Recorded even when it created nothing: "I imported that file and it
        // was all already here" is an answer the list has to be able to give,
        // and a re-import that vanishes silently looks like a failed one.
        appendStatementImport(StatementImport(
            filename: filename,
            importedAt: Date(),
            created: transactions.map(\.id).filter { !before.contains($0) },
            merged: merged,
            from: statement.period?.lowerBound,
            to: statement.period?.upperBound))

        persistNow()
        return ImportSummary(imported: imported, merged: merged,
                             skippedNonUAH: statement.skippedNonUAH,
                             period: statement.period, cardSuffixes: suffixes)
    }
}
