import Foundation

/// Pure join between a scanned fiscal receipt and the transactions already
/// synced from the bank. No `AppStore`, no I/O, no system clock — every date
/// this rule ever sees is handed to it by the caller.
///
/// The QR's total and the card's charge are the same number, so the sum
/// comparison is exact: cash receipts round to the nearest ten kopecks at
/// the till, but cash has no transaction to match against, so that rounding
/// never reaches here. A tolerance would let a 99.00 coffee claim a 99.50 one.
enum ReceiptMatch {
    /// A till clock and a card authorisation drift by minutes, not hours;
    /// three hours absorbs a badly-set register while staying narrow enough
    /// that "the same amount twice today" usually still resolves to one
    /// candidate.
    static let window: TimeInterval = 3 * 3600

    /// Every transaction that could plausibly be this receipt, ordered
    /// nearest-in-time first so a later task can offer the list to the user.
    static func candidates(for receipt: Receipt, in transactions: [Transaction]) -> [Transaction] {
        transactions
            .filter { tx in
                tx.amount < 0
                    && tx.receiptId == nil
                    && abs(tx.amount) == receipt.fiscalSum
                    && abs(tx.date.timeIntervalSince(receipt.fiscalTime)) <= window
            }
            .sorted { abs($0.date.timeIntervalSince(receipt.fiscalTime)) < abs($1.date.timeIntervalSince(receipt.fiscalTime)) }
    }

    /// The id to attach the receipt to automatically — only when exactly one
    /// candidate exists. Never a best guess among several: guessing here
    /// attaches someone's groceries to the wrong purchase silently.
    static func sole(for receipt: Receipt, in transactions: [Transaction]) -> Transaction.ID? {
        let matches = candidates(for: receipt, in: transactions)
        return matches.count == 1 ? matches[0].id : nil
    }
}
