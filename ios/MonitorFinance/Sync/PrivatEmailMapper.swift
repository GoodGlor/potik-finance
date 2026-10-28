import Foundation

/// One backend row → one `Transaction`, mirroring `PrivatMapper`. Pure.
///
/// Identity is the backend's own insertion id, scoped by the ACCOUNT it came
/// from: the id is only unique per-user, so a re-registration against a new
/// server account (ids restarting at 1) would otherwise collide with rows a
/// previous account already left in the store — not a duplicate, a wrong
/// merge, overwriting an unrelated old purchase's amount, merchant and date.
/// `userId` closes that: two accounts can never produce the same identity,
/// while a re-fetched page from the SAME account still merges in `ingestRows`
/// by construction.
enum PrivatEmailMapper {
    static let externalIdPrefix = "privat-email|"

    /// nil = the row must not enter the app: `Transaction` carries no
    /// currency and every total sums amounts blindly, so non-UAH is skipped
    /// exactly the way the statement import and monobank sync skip it.
    ///
    /// `userId` is the CURRENT credentials' id, supplied by the caller on
    /// every call — never read from the row, which carries none. Keep
    /// `externalIdPrefix` exactly `"privat-email|"`: the cross-source filters
    /// on both sides match against it as a prefix, and changing it would
    /// silently stop them matching anything.
    static func transaction(_ row: PrivatEmailTransaction, userId: String) -> Transaction? {
        guard row.currency == "UAH" else { return nil }
        let transfer = PrivatMapper.isOwnTransferText(row.merchantRaw)
        let income = row.amountMinor > 0
        let name = externalIdPrefix + userId + "|" + String(row.id)
        return Transaction(
            id: UUIDv5.make(namespace: UUIDv5.appNamespace, name: name),
            date: row.occurredAt,
            kind: transfer ? .transfer : (income ? .income : .expense),
            // Income must land in a category whose kind is `.earned`
            // counts, or it contributes zero to the income base — the same
            // rule PrivatMapper's own test pins.
            category: (income && !transfer) ? BudgetMath.defaultIncomeCategory : "",
            merchant: row.merchantRaw,
            amount: row.amountMinor,
            cardSuffix: row.cardSuffix,
            bankId: PrivatMapper.bankId,
            receiptId: nil,
            splits: [],
            resolution: transfer ? .transfer : .pending,
            // A letter carries no category — nothing honest to suggest.
            suggestions: [],
            externalId: name,
            hold: false,
            mcc: nil,
            // The letter's own balance line — the half of the cross-source
            // key this source contributes. `nil` on the rows that carry no
            // balance, and a row without one can never match a statement row.
            balanceAfterMinor: row.balanceAfterMinor)
    }
}
