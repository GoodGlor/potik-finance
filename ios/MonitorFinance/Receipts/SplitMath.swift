import Foundation

/// Turns a receipt's line items into a purchase's `[Split]`. Pure arithmetic
/// — no SwiftUI, no `AppStore`, no I/O — so statistics and the budget can
/// both trust the same total without a screen to check it on.
///
/// A split's `category` is a PRODUCT GROUP (what was bought), never the
/// transaction's spending category (where the money went). The two
/// namespaces are separate on purpose; this file must not let one leak into
/// the other.
enum SplitMath {

    /// The line that soaks up whatever the receipt's items don't itemise —
    /// e.g. a fee or a discount folded into the charge but not into any
    /// line. Grouped under `ProductGuess.other`: it names no product.
    static let remainderName = "Не деталізовано"

    enum Outcome: Equatable {
        case ok([Split])
        /// The receipt's own items add up to more than the purchase — the
        /// receipt cannot belong to this transaction. `by` is how much over,
        /// in minor units.
        case receiptExceedsPurchase(by: Int)
    }

    /// `charge` is `abs(tx.amount)`: a split carries a share, never a sign —
    /// the signed convention stays on `Transaction` alone.
    ///
    /// Compared against the SUM OF THE ITEMS, never `receipt.fiscalSum`: only
    /// item sums become splits, so the invariant that splits total `charge`
    /// has to be checked against the number that actually produced them.
    /// `fiscalSum` and the item sum agree for every generated receipt today,
    /// but nothing guarantees a scanned receipt's header total matches its
    /// own lines.
    static func build(_ tx: Transaction, _ receipt: Receipt, groups: [ProductGroup]) -> Outcome {
        // No items means nothing was actually detailed — not "one line for
        // the whole charge". The feed's `receipt.empty` state (goods not
        // synced yet) has nothing to split.
        guard !receipt.items.isEmpty else { return .ok([]) }

        let charge = abs(tx.amount)
        let itemised = receipt.items.reduce(0) { $0 + $1.sum }
        let remainder = charge - itemised
        guard remainder >= 0 else { return .receiptExceedsPurchase(by: -remainder) }

        var splits = receipt.items.map { item in
            Split(id: UUID(),
                  name: item.name,
                  amount: item.sum,
                  // An item's own category, when the receipt carries one,
                  // overrides the guess. Otherwise: the PRODUCT GROUP guess —
                  // never `tx.category`, which is a SPENDING category from a
                  // different namespace entirely.
                  category: item.category ?? ProductGuess.group(for: item.name, in: groups))
        }
        if remainder > 0 {
            splits.append(Split(id: UUID(), name: remainderName, amount: remainder, category: ProductGuess.other))
        }
        return .ok(splits)
    }
}
