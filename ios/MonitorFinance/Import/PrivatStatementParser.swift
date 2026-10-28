import Foundation

struct PrivatRow: Equatable {
    var date: Date
    var category: String
    var cardSuffix: String
    var descriptionText: String
    var amountMinor: Int
    var currency: String
    var balanceMinor: Int
    var balanceCurrency: String
}

struct PrivatStatement: Equatable {
    var rows: [PrivatRow]
    var skippedNonUAH: Int
    // Optional even though `.emptyStatement` makes `rows` (and so `nil`
    // here) unreachable through `parse(_:)` today — kept open because the
    // next task's API surface may construct a `PrivatStatement` some other
    // way.
    var period: ClosedRange<Date>?
}

/// Rows of strings → typed statement rows. The ten-column header is the
/// guard that turns "the user picked some random xlsx" into one clear
/// sentence; everything after it either parses in full or refuses with
/// the sheet row number.
enum PrivatStatementParser {
    static let header = ["Дата", "Категорія", "Картка", "Опис операції",
                         "Сума в валюті картки", "Валюта картки",
                         "Сума в валюті транзакції", "Валюта транзакції",
                         "Залишок на кінець періоду", "Валюта залишку"]

    /// The export writes local Kyiv wall-clock time with no zone marker.
    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = kyiv
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    /// `yyyy` is greedy — "20.08.20261 18:07:59" would parse as year 20261
    /// instead of failing, blowing out `period`'s upper bound with a
    /// garbage date — so the shape is checked before the formatter ever
    /// sees the string. (A round-trip check does NOT catch this: the
    /// formatter happily re-renders year 20261 back to "20261".)
    private static let dateShapePattern = #"^\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}$"#

    static func parse(_ rows: [[String]]) throws -> PrivatStatement {
        guard let headerIndex = rows.prefix(5).firstIndex(where: { Array($0.prefix(10)) == header })
        else { throw PrivatImportError.notAPrivatStatement }

        var out: [PrivatRow] = []
        var skipped = 0
        for (offset, raw) in rows.dropFirst(headerIndex + 1).enumerated() {
            let line = headerIndex + offset + 2   // 1-based sheet row number
            if raw.allSatisfy(\.isEmpty) { continue }
            var cells = raw
            if cells.count < 10 { cells += Array(repeating: "", count: 10 - cells.count) }
            // Trimmed once, here, for every cell — so a currency cell like
            // " UAH" can't slip past the exact-match check below and get
            // silently counted as foreign-currency instead of UAH, quietly
            // dropping a real transaction from someone's financial history.
            cells = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // A whole foreign-currency card's rows are skipped, not errors —
            // `Transaction` has no currency and every total sums blindly.
            guard !cells[5].isEmpty else { throw PrivatImportError.badRow(line) }
            if cells[5] != "UAH" { skipped += 1; continue }
            guard cells[0].range(of: dateShapePattern, options: .regularExpression) != nil,
                  let date = dateFormatter.date(from: cells[0]),
                  let amount = minor(cells[4]),
                  let balance = minor(cells[8]) else { throw PrivatImportError.badRow(line) }
            out.append(PrivatRow(
                date: date, category: cells[1],
                cardSuffix: cardSuffix(cells[2]),
                descriptionText: cells[3],
                amountMinor: amount, currency: cells[5],
                balanceMinor: balance, balanceCurrency: cells[9]))
        }
        guard !out.isEmpty else { throw PrivatImportError.emptyStatement }
        let dates = out.map(\.date)
        return PrivatStatement(rows: out, skippedNonUAH: skipped,
                               period: dates.min().flatMap { lo in dates.max().map { lo...$0 } })
    }

    /// «5168 **** **** 1111» → "*1111". The full PAN fragment is never
    /// stored. Empty or unrecognized → "" (credit-interest rows carry no
    /// card at all).
    static func cardSuffix(_ masked: String) -> String {
        let digits = masked.split(whereSeparator: { !$0.isNumber })
        guard let last = digits.last, last.count == 4 else { return "" }
        return "*" + last
    }

    /// "-174.5" → -17450 via `Decimal`, so tenths never pick up float dust.
    ///
    /// Three refusals guard this, all earned by hostile-input review:
    /// - `Decimal(string:)` parses a leading numeric *prefix* and silently
    ///   drops trailing garbage — `"12abc"` becomes `1200`, `"1.2.3"`
    ///   becomes `120`, bare `"-"` or `"."` become `0`, and a locale-styled
    ///   `"1 234,56"` becomes `1`. A shape check runs first so any of that
    ///   fails loudly instead of fabricating a number.
    /// - That same shape caps the fraction at two digits, so a third
    ///   decimal place is refused rather than silently truncated —
    ///   `"1.005"` would otherwise become `100`, not `100` *or* `101`, just
    ///   quietly wrong either way.
    /// - `.intValue` on a value outside `Int`'s range does not fail either;
    ///   it wraps to an unrelated in-range number. Bounds are checked on
    ///   the `Decimal` before the conversion, not after.
    /// A statement row is never that large or that malformed, so all three
    /// paths only ever fire on a corrupt or hostile file — and must
    /// refuse (`nil` → `badRow`) rather than hand back a plausible balance.
    static func minor(_ s: String) -> Int? {
        guard s.range(of: #"^-?[0-9]+(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let scaled = d * 100
        guard scaled >= Decimal(Int.min), scaled <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: scaled).intValue
    }
}
