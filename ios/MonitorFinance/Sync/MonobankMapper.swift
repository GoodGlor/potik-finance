import Foundation

/// One monobank statement row → one `Transaction`. Pure, so it is testable
/// against Python's own answers for all 111 corpus rows.
///
/// Nothing here guesses a category. That is deliberate: the app asks, once per
/// shop, rather than shipping a merchant word list (see the spec's D4).
enum MonobankMapper {

    static func transaction(_ item: MonobankStatementItem,
                            account: MonobankAccount,
                            bankId: String = "monobank") -> Transaction {
        let income = item.amount > 0
        return Transaction(
            id: UUIDv5.make(namespace: UUIDv5.appNamespace, name: "monobank|" + item.id),
            date: Date(timeIntervalSince1970: TimeInterval(item.time)),
            kind: income ? .income : .expense,
            category: income ? BudgetMath.defaultIncomeCategory : "",
            merchant: item.description.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: item.amount,
            cardSuffix: cardSuffix(account),
            bankId: bankId,
            receiptId: nil,
            splits: [],
            resolution: .pending,
            suggestions: [],
            externalId: item.id,
            hold: item.hold ?? false,
            mcc: item.mcc,
            originalMcc: item.originalMcc)
    }

    /// `["537541******1234"]` → `"*1234"`. The app has always displayed a card
    /// this way and `Account.suffix` is stored in the same shape.
    static func cardSuffix(_ account: MonobankAccount) -> String {
        guard let pan = account.maskedPan?.first, pan.count >= 4 else { return "" }
        return "*" + pan.suffix(4)
    }

    /// 980 → "UAH", and nothing else. `Transaction` carries no currency and
    /// every total sums amounts blindly, so a foreign card must be refused
    /// rather than given a plausible-looking string.
    static func currency(_ code: Int) -> String? { code == 980 ? "UAH" : nil }
}
