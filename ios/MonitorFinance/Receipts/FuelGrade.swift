import Foundation

/// A fuel grade, read out of a receipt line's product name the same way
/// `ProductGuess` reads a product group: keyword tokens matched longest
/// first over `MerchantKey.normalize`d text — see `ProductGuess.group` for
/// why the ordering matters. Longest-first is kept here for consistency
/// with that rule and as a defence against a FUTURE token that collides
/// (say, a synonym added later); today none of the eight tokens below is a
/// substring of another, so the ordering is defensive rather than
/// load-bearing — no current test can (or should) prove it, see
/// task-8-report.md.
///
/// Returns the CANONICAL spelling — `А-95`, never `а-95` or the matched
/// substring — so every screen that shows a grade shows the same string
/// regardless of how the scanner or the seller capitalised the receipt
/// line. `Бензин автомобільний А-95-Євро5-Е10` still yields exactly `А-95`.
enum FuelGrade {
    /// (token to search for, canonical spelling to return). A token is the
    /// canonical spelling lowercased — `MerchantKey.normalize` lowercases
    /// (and precomposes, and trims) the receipt line before comparison, so
    /// token and name always meet in the same case.
    private static let grades: [(token: String, canonical: String)] = [
        ("а-92", "А-92"),
        ("а-95", "А-95"),
        ("а-98", "А-98"),
        ("а-100", "А-100"),
        ("дп", "ДП"),
        ("дт", "ДТ"),
        ("газ", "ГАЗ"),
        ("lpg", "LPG"),
    ]

    private static let sortedGrades = grades.sorted { $0.token.count > $1.token.count }

    /// One compiled matcher per grade, built once. Each requires a WORD
    /// BOUNDARY on both sides of the token — `\b` in ICU regex, which sits
    /// between a "word" character (a letter or digit, Unicode-aware, so
    /// Cyrillic counts) and anything that is not one. A hyphen is not a
    /// word character, so it counts as a boundary too, which is exactly
    /// what makes both halves of the rule hold at once:
    ///
    /// - `газ` must NOT match inside `негазована` (a bottle of STILL water
    ///   on the seed's corner-shop receipt — «Вода негазована 0,5 л») or
    ///   the taxonomy's own `газована` keyword: `не`|`газ`|`ована` are all
    ///   plain letters running together with no boundary between them, so
    ///   `\bгаз\b` correctly fails to match there. Same shape of risk for
    ///   `дп`/`дт` sitting inside an ordinary word — «ДТП», «ДПС» — rather
    ///   than standing as their own token.
    /// - `а-95` must still match inside the compound
    ///   `а-95-євро5-е10` (from `Бензин автомобільний А-95-Євро5-Е10`):
    ///   the hyphens on either side of `95`'s digits are themselves not
    ///   word characters, so `\b` finds a boundary right there WITHOUT the
    ///   token having to be split on its own internal hyphen first. A rule
    ///   that tokenized on `-` before matching would break exactly this
    ///   case, turning `а-95` into two pieces (`а`, `95`) that no longer
    ///   spell any grade — which is why this matches the whole token
    ///   in place rather than pre-splitting the name.
    private static let matchers: [(regex: NSRegularExpression, canonical: String)] = {
        sortedGrades.compactMap { grade in
            let escaped = NSRegularExpression.escapedPattern(for: grade.token)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") else { return nil }
            return (regex, grade.canonical)
        }
    }()

    /// The first grade whose token appears in `name` AS A WHOLE TOKEN, or
    /// nil when nothing in the table matches — a non-fuel line (coffee, a
    /// croissant, still water) must fall to nil rather than to whichever
    /// grade happens to be listed first, and must not be fooled by one of
    /// its own letters spelling a grade by coincidence.
    static func parse(_ name: String) -> String? {
        let normalized = MerchantKey.normalize(name)
        let range = NSRange(normalized.startIndex..., in: normalized)
        for matcher in matchers where matcher.regex.firstMatch(in: normalized, range: range) != nil {
            return matcher.canonical
        }
        return nil
    }
}
