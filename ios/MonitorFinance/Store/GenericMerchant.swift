import Foundation

/// Merchants whose category belongs to the individual purchase, not to the
/// merchant.
///
/// The queue's whole design is "answer once per shop": confirm «Крамниця-Приклад» →
/// «Продукти» and every row from that shop, now and later, is answered. That trade is
/// only sound when the merchant NAMES a kind of spending. Some do not:
///
/// * «На картку», «Переказ …», a bare masked card number — one transfer pays
///   a friend back for groceries, the next splits a restaurant bill, the one
///   after is rent. The recipient is not a shop.
/// * «NovaPay» / «Нова Пошта» — a delivery company charging for whatever was
///   in the parcel.
/// * «Зняття готівки», an ATM — cash that was then spent on something the
///   bank never saw.
/// * «Платіж» — the bank's word for "a payment", which is not a word about
///   what was bought.
///
/// The demo seed makes the cost concrete: its largest queue card is «На
/// картку» with **35 rows**, and one tap used to stamp all thirty-five with
/// one category. Every one of those was a separate decision.
///
/// **Why a predicate and not seeded `Rule(ambiguous: true)` rows**, which is
/// how the card first described it: the rule table is keyed by an exact
/// normalized merchant, and these are FAMILIES of strings — one per own
/// card, and one distinct string per person ever paid. Exact keys cannot cover them, and materialising a rule
/// per counterparty would fill `rules.json` with a row per person the owner
/// has ever paid. A predicate covers the family and stores nothing.
enum GenericMerchant {

    /// Matched as substrings against the normalized merchant, so «Переказ на
    /// картку», «переказ зі своєї картки *0000» and «Зняття готівки в
    /// банкоматі» are all caught by one entry each.
    ///
    /// Deliberately short. Every addition takes a merchant away from the
    /// one-tap flow that makes the queue bearable, so the bar is "the name
    /// genuinely cannot tell you what was bought", not "transfers feel
    /// special".
    static let patterns: [String] = [
        "переказ",
        "на картку",
        "зняття готівки",
        "банкомат",
        "novapay",
        "нова пошта",
        "платіж",
    ]

    /// A bare masked card number — «*1234», «537541******1234». No shop is
    /// named this, and monobank uses it for a transfer whose recipient it
    /// will not name.
    private static let maskedCard = /\*\d{4}/

    /// **Not covered, and known:** a P2P row whose text is simply the other
    /// person's name. The backend recognises those with name-shaped regexes
    /// (`app/core/categories.py`'s `FULL_NAME` / `NAME_INITIALS`), and
    /// bringing that here means accepting false positives on shop names built
    /// the same way. It is its own decision, with its own card.
    static func matches(_ merchant: String) -> Bool {
        let key = MerchantKey.normalize(merchant)
        if patterns.contains(where: key.contains) { return true }
        // The regex only runs on a string that could possibly match. This is
        // called for every pending row on every queue render, and
        // `pendingGroups` is recomputed several times per render.
        guard key.contains("*") else { return false }
        return key.firstMatch(of: maskedCard) != nil
    }
}
