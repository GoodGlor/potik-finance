import Foundation

/// What a learned rule says, in words a person can read.
///
/// **One vocabulary, two screens.** Board #11 puts the rule table on screen in
/// two places at once — the list in Налаштування → Категорії → «Правила», and
/// the sentence on `TransactionDetailView` that replaced its dead toggle. Those
/// two describing the same rule differently is the exact failure the card
/// exists to fix, so neither of them spells a rule itself; both ask here.
///
/// A `Rule` is four fields with an unwritten precedence between them, and the
/// order below IS that precedence — `applyingRule` reads them in the same
/// order, so a sentence produced here is a description of what will actually
/// happen at ingest and not a hopeful summary of the struct.
enum RuleText {

    /// The answer half of «merchant → answer», with no merchant in it — the two
    /// callers frame it differently (a list row puts an arrow in front, the
    /// detail card puts a whole sentence around it).
    ///
    /// The `ambiguous` check comes before the category on purpose: an ambiguous
    /// rule can still CARRY a category (`upsertRule` writes `category: nil`, but
    /// a rule decoded from an older build need not have), and `applyingRule`
    /// bails on `ambiguous` before it ever reads one. Reading them the other way
    /// round would promise a category the app will never apply.
    static func answer(_ rule: Rule) -> String {
        if rule.kind == .transfer { return "переказ між своїми картками" }
        if rule.ambiguous { return "питаємо щоразу" }
        guard let category = rule.category, !category.isEmpty else {
            // Neither a category, nor a transfer, nor flagged ambiguous:
            // `applyingRule` falls through every branch and returns the row
            // untouched, so this rule asks. It cannot be written by any path in
            // the app today and exists only as a shape an older `rules.json`
            // could decode into — which is precisely why it must not render as
            // a blank arrow pointing at nothing.
            return "питаємо щоразу"
        }
        return category
    }

    /// Which kind of row this rule answers for, or `nil` when it answers for
    /// every kind. Board #81.
    ///
    /// **Only worth saying when a merchant has more than one rule** — the
    /// caller decides that, not this. Where a merchant appears once, «для
    /// витрат» beside it invites the question "as opposed to what?"; where it
    /// appears twice, the line is the only thing telling the two rows apart,
    /// and without it the screen shows one merchant with two contradictory
    /// answers and no explanation.
    ///
    /// Returned as the Ukrainian key so the caller can hand it to
    /// `LocalizedStringKey` — the same shape `answer` uses, for the same
    /// reason: this file has no view and no environment to read.
    static func scopeNote(_ rule: Rule) -> String? {
        switch rule.scope {
        case .expense: "для витрат"
        case .income: "для надходжень"
        // A transfer-scoped rule cannot be written by any path in the app —
        // `markNotAnExpense` scopes its transfer rule to nothing on purpose —
        // but `rules.json` is decoded, not trusted.
        case .transfer: "для переказів"
        case nil: nil
        }
    }

    /// Whether this rule is dead letter — present in the table and refused at
    /// ingest every time.
    ///
    /// `applyingRule`'s FIRST line rejects a `GenericMerchant` whatever the rule
    /// table holds, and the bundled demo ships two such rules (a delivery
    /// company and a bare masked card number). A screen that lists them beside
    /// the three live ones, with nothing to tell them apart, would be a new
    /// untruth about rules told by the screen built to end them.
    ///
    /// Takes the stored key rather than a display name: the key is already
    /// normalized and `GenericMerchant.matches` normalizes again, which is
    /// idempotent.
    static func isInert(_ rule: Rule) -> Bool {
        GenericMerchant.matches(rule.merchantKey)
    }

    /// What the list screen has to say about every rule at once: the merchant
    /// as a bank most recently wrote it, and how many rows it has.
    ///
    /// **One pass over the transactions for all the rules together**, and that
    /// is the point of the shape. The obvious version — a `merchantName(for:)`
    /// and a `count(for:)` each filtering the whole array, called per row — is
    /// quadratic in exactly the direction that hurts: the person this screen
    /// exists for is the one with a year of history and a hundred merchants
    /// answered, and 100 rules × 5 000 rows is half a million
    /// `MerchantKey.normalize` calls (a canonical-mapping pass, a trim and a
    /// lowercase, each) on every single render of a `List` that re-renders as
    /// it scrolls.
    ///
    /// Newest row wins the name, matching how `AppStore.groups` picks a card's
    /// display name — `MerchantKey.normalize` lowercases, so the key alone
    /// renders a shop's name in lower case, a spelling nobody's statement
    /// contains and nobody recognises as theirs. A key with no rows left keeps
    /// the key as its name: a rule outlives the transactions that taught it (a
    /// merchant not seen this year, a reset that keeps rules), and a row with
    /// no name at all cannot be forgotten by someone who cannot tell which rule
    /// it is.
    struct Summary: Equatable {
        var name: String
        var count: Int
    }

    static func summarise(_ keys: [String], in transactions: [Transaction]) -> [String: Summary] {
        let wanted = Set(keys)
        var newest: [String: Date] = [:]
        var out = wanted.reduce(into: [String: Summary]()) { $0[$1] = Summary(name: $1, count: 0) }
        for tx in transactions {
            let key = MerchantKey.normalize(tx.merchant)
            guard wanted.contains(key) else { continue }
            out[key]?.count += 1
            if tx.date > (newest[key] ?? .distantPast) {
                newest[key] = tx.date
                out[key]?.name = tx.merchant
            }
        }
        return out
    }
}
