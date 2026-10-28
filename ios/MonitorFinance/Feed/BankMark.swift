import Foundation

/// **Which bank and which card a row came from — the one answer four screens
/// share.** Board #98.
///
/// The feed's rows, the queue's cards, the feed's bank filter and the
/// statistics tab's per-bank scope all have to agree about this, and the way
/// they disagree is not by drawing different pixels: it is by each computing
/// the answer from `tx.bankId` in its own slightly different way and then
/// showing a person two names for one bank. `TransactionDetailView` already had
/// its own copy of the lookup before this existed.
///
/// **None of this is copy.** `Bank.displayName` is stored and matched on, in
/// the same class as a category name — «ПриватБанк» is the bank's own name, not
/// a word to translate — and a card suffix is a fact the bank sent. Every
/// caller shows the result through `Text(verbatim:)`.
enum BankMark {

    /// The bank's name, or the raw id when no bank matches.
    ///
    /// Falling back to the id rather than to a friendly «Невідомий банк» is
    /// deliberate: a row whose `bankId` names no connected bank is a real
    /// state — a bank the person disconnected while its rows stayed — and the
    /// id is the only thing that tells you *which*.
    static func bank(_ bankId: String, _ banks: [Bank]) -> String {
        banks.first { $0.id == bankId }?.displayName ?? bankId
    }

    /// «monobank · *1234» — bank and card in the shortest form that still
    /// tells two rows apart, or just the bank when the row carries no card.
    ///
    /// **` · ` with spaces, not a bare `·`.** The suffix usually arrives
    /// carrying its own mask, so a tight separator renders «monobank ·*1234»,
    /// two marks fighting over one gap — which is what the first screenshot of
    /// this showed and no assertion would have. The spaced middle
    /// dot is what the row's own subtitle already uses between a category and
    /// a time, so this reads as the same kind of separator rather than a new one.
    ///
    /// The suffix itself is printed exactly as the source sent it. A letter
    /// says «5*99» and a statement says «2299» for the same physical card,
    /// which is a real problem — but it is a problem about card IDENTITY, and
    /// inventing a third spelling here would only give the two that disagree a
    /// fourth to disagree with. It is carded separately.
    static func line(_ tx: Transaction, _ banks: [Bank]) -> String {
        let name = bank(tx.bankId, banks)
        guard !tx.cardSuffix.isEmpty else { return name }
        return "\(name) · \(tx.cardSuffix)"
    }

    /// The same mark for a GROUP of rows, which can span cards. Board #104.
    ///
    /// A queue card is a merchant AND a kind, never a card, so the same shop
    /// paid from two cards is one question — and «monobank · 2 картки» is the
    /// honest answer. Listing both suffixes would be longer, would not fit,
    /// and would suggest the person is being asked two questions.
    ///
    /// The card COUNT is copy and takes a language; the names and digits do
    /// not. Empty in and empty out: a group with no bank is not something to
    /// invent a name for.
    static func group(bankIds: [String], suffixes: [String],
                      _ banks: [Bank], _ language: AppLanguage) -> String {
        guard !bankIds.isEmpty else { return "" }
        let name = bankIds.map { bank($0, banks) }.joined(separator: " · ")
        switch suffixes.count {
        case 0: return name
        case 1: return "\(name) · \(suffixes[0])"
        default: return "\(name) · \(Plural.cards(suffixes.count, language))"
        }
    }
}
