import Foundation

/// The identity bridge between the two PrivatBank sources — the xlsx statement
/// export and the notification letters the email backend parses.
///
/// **Their identity keys cannot be equal, and no amount of normalising will
/// make them so.** The statement masks a card as `"*2299"` (the last four
/// digits); a letter masks the same card as `"5*99"` (first digit + last two),
/// so only two digits are shared. The merchant texts differ — the statement
/// carries Privat's own tidied description, the letter carries the terminal's
/// line. And the times differ twice over: the statement has seconds where a
/// letter has only minutes, and a letter is written at AUTHORISATION while the
/// statement may report SETTLEMENT, which for a hotel or a fuel pump lands a
/// day or more later.
///
/// What both sources do agree on is the pair **(signed amount, running balance
/// after the row)** — the same pair `PrivatMapper.key` already leans on to tell
/// two identical purchases in one second apart. So "the same purchase" is that
/// pair, guarded by the two digits of card the maskings share and by a 36-hour
/// window wide enough for the authorisation/settlement drift.
///
/// **A row with no balance never matches anything** (interest rows arrive
/// without one). In the worst case such a row lands twice and the queue's human
/// confirm is the backstop; merging two DIFFERENT purchases would destroy a row
/// nobody can get back, and that is the worse of the two errors.
enum PrivatCrossSource {

    /// `nil` = this row has no cross-source identity, so it must not be matched
    /// against anything. See the note above on why that is the safe answer.
    static func key(amountMinor: Int, balanceAfterMinor: Int?) -> String? {
        guard let balance = balanceAfterMinor else { return nil }
        // The separator is load-bearing: without it (-12, 550) and (-125, 50)
        // would produce the same string and one purchase would eat the other.
        return "\(amountMinor)|\(balance)"
    }

    /// `"*2299"` (statement, last 4) against `"5*99"` (letter, first + last 2):
    /// the last two digits are the only shared ground, so agreement is decided
    /// on those and the masks are never compared as text.
    ///
    /// Fewer than two digits on either side is NOT agreement — an interest
    /// row's empty suffix would otherwise agree with every card at once.
    static func sameCard(_ a: String, _ b: String) -> Bool {
        let da = a.filter(\.isNumber), db = b.filter(\.isNumber)
        guard da.count >= 2, db.count >= 2 else { return false }
        return da.suffix(2) == db.suffix(2)
    }

    /// The two guards that stand between an equal key and a merge. Without the
    /// window, a standing charge of the same size that leaves the same balance
    /// months later would merge into the first one; without the card check, two
    /// cards that happen to hold the same balance would trade rows.
    static func matches(date: Date, suffix: String,
                        candidateDate: Date, candidateSuffix: String) -> Bool {
        abs(date.timeIntervalSince(candidateDate)) <= 36 * 3600
            && sameCard(suffix, candidateSuffix)
    }
}
