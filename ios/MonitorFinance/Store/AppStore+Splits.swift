import Foundation

/// Confirming and clearing a receipt's split into PRODUCT GROUPS — what was
/// bought. Never the transaction's SPENDING category (where the money
/// went): the two namespaces stay separate here exactly as they do in
/// `SplitMath`.
extension AppStore {

    /// Saves a draft group choice for one receipt line, before the split is
    /// confirmed. Written straight onto the receipt's own item — the same
    /// field `SplitMath.build` already prefers over its keyword guess — so a
    /// reopened split screen shows the human's choice rather than the guess,
    /// and a killed app mid-edit does not lose it.
    func setItemGroup(_ itemId: UUID, on receiptId: UUID, to group: String) {
        guard let ri = receipts.firstIndex(where: { $0.id == receiptId }),
              let ii = receipts[ri].items.firstIndex(where: { $0.id == itemId }) else { return }
        let item = receipts[ri].items[ii]
        receipts[ri].items[ii].category = group
#if DEBUG
        // The keyword matcher's own answer, not `item.category` — a second
        // correction of the same line must still be recorded against what the
        // MATCHER would say, or the training pair becomes "the app agreed with
        // my previous tap", which teaches nothing.
        //
        // Main-actor assumed for the same reason `AppStore.note` does: the
        // only route here is a tap in `ReceiptItemsView`.
        MainActor.assumeIsolated {
            categorizationLog.recordProduct(
                name: item.name,
                guessed: ProductGuess.group(for: item.name, in: productGroups),
                chosen: group,
                seller: receipts[ri].sellerName)
        }
#endif
        persist()
    }

    /// Runs `SplitMath` against the transaction's current receipt (including
    /// any draft group choices `setItemGroup` wrote onto its items) and, only
    /// when the arithmetic checks out, writes the result onto the
    /// transaction.
    ///
    /// Writes NOTHING on refusal — a half-applied refusal would be worse
    /// than none. And on success it writes only `splits`: `resolution` and
    /// `category` describe a human decision about the SPENDING category, and
    /// confirming a product-group split is not that decision, so stamping
    /// `.user` or a merchant rule here would make the queue and the detail
    /// screen claim something that never happened.
    @discardableResult
    func confirmSplits(for id: Transaction.ID) -> SplitMath.Outcome {
        guard let index = transactions.firstIndex(where: { $0.id == id }),
              let receipt = receipt(for: transactions[index]) else {
            return .ok([])
        }
        let outcome = SplitMath.build(transactions[index], receipt, groups: productGroups)
        if case .ok(let splits) = outcome {
            transactions[index].splits = splits
            persist()
        }
        return outcome
    }

    /// How far a receipt overshoots the purchase it is attached to, or nil
    /// when it fits. Board #80.
    ///
    /// **On the store rather than in `ReceiptItemsView`, and that was bought
    /// by a mutation.** As a private computed property on the view it was
    /// unreachable from any test: making it fire unconditionally — so every
    /// receipt in the app announced «Чек більший за покупку на 0,00 ₴» —
    /// passed the whole suite. The store already owns all three inputs, so
    /// the view has no business deriving it.
    func splitMismatch(forReceipt receiptId: UUID) -> Int? {
        guard let tx = transactions.first(where: { $0.receiptId == receiptId }),
              let receipt = receipt(for: tx),
              case .receiptExceedsPurchase(let by) =
                SplitMath.build(tx, receipt, groups: productGroups) else { return nil }
        return by
    }

    /// Board #80. A hold that settles at a different figure leaves splits
    /// describing the old one.
    ///
    /// **The two views of Статистика stop agreeing, silently.**
    /// `Derived.byProductGroup` sums the SPLITS; `Derived.byCategory` sums the
    /// AMOUNT. A restaurant hold that settles with a tip on it, or a fuel
    /// pre-authorisation that releases down to what was pumped, moves the
    /// amount and leaves the splits where they were — and the difference just
    /// vanishes from one of the two screens.
    ///
    /// **Rebuilt from the receipt rather than scaled.** `SplitMath.build`
    /// already puts anything the items do not account for into a «Не
    /// деталізовано» line, so a tip lands there and is visible on the detail
    /// screen as its own row. Scaling the item amounts to fit would invent
    /// prices nobody paid, and it would be the app writing fiction into the
    /// one place that holds what a receipt actually said.
    ///
    /// **Only for a row that already has splits.** An amount change must not
    /// confirm a split nobody confirmed: an attached receipt whose items are
    /// still undrafted stays that way.
    func resplitAfterSettlement(at index: Int) {
        guard transactions.indices.contains(index),
              !transactions[index].splits.isEmpty else { return }
        // Splits without a receipt behind them describe goods nobody can see,
        // which is `clearSplits`' own invariant.
        guard let receipt = receipt(for: transactions[index]) else {
            clearSplits(on: index)
            return
        }
        switch SplitMath.build(transactions[index], receipt, groups: productGroups) {
        case .ok(let splits):
            transactions[index].splits = splits
        case .receiptExceedsPurchase:
            // The settled amount is now SMALLER than the receipt's own items.
            // There is no honest split of it, so the row keeps its receipt —
            // that is a real fact and the person may want to detach it
            // themselves — and loses the arithmetic. `byProductGroup` then
            // counts the whole charge under «Без чека», which is at least
            // true, and `ReceiptItemsView` says so on sight rather than
            // waiting for somebody to press «Підтвердити».
            clearSplits(on: index)
        }
    }

    /// A split describes ONE receipt's items. Once that receipt is gone —
    /// replaced by `attach` or removed by `detachReceipt` — a leftover split
    /// would describe goods nobody can see any more. Called from both paths,
    /// after each has already changed `receiptId`.
    func clearSplits(on index: Int) {
        guard transactions.indices.contains(index) else { return }
        transactions[index].splits = []
    }
}
