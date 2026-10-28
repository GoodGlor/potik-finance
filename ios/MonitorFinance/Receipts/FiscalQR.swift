import Foundation

/// What a Ukrainian fiscal receipt's QR carries: the tax service's check-lookup
/// URL. The seller and the goods are NOT in it — they live on the page that URL
/// opens, which is backend work (`ReceiptFetcher`/`TaxCabinetAPI`).
struct FiscalCheck: Equatable, Codable, Hashable {
    var registerNumber: String      // «РРО ФН» — the till, QR param `fn`
    var documentNumber: String      // «ЧЕК ФН» — this receipt, QR param `id`
    var fiscalTime: Date
    var fiscalSum: Int      // minor units, >= 0
    /// The control number, «MAC». Optional: real QRs carry it, the bundled
    /// samples' synthesised URLs do not, and refusing those would refuse the
    /// only scanning path a simulator has.
    var mac: String?
}

enum FiscalQR {

    /// Nil for anything this cannot read with certainty. A guessed sum would
    /// attach a wrong total to a real purchase, which is worse than refusing.
    static func parse(_ payload: String) -> FiscalCheck? {
        guard let components = URLComponents(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host,
              host == "tax.gov.ua" || host.hasSuffix(".tax.gov.ua"),
              let items = components.queryItems else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value.flatMap {
                $0.isEmpty ? nil : $0
            }
        }

        // `id` is the DOCUMENT number (printed «ЧЕК ФН»), `fn` the REGISTER's
        // fiscal number (printed «РРО ФН»). They were read the other way round
        // until 2026-08-24 — inert while both were carried opaquely, and a
        // wrong query to the tax service the moment anything fetches goods.
        guard let documentNumber = value("id"),
              let registerNumber = value("fn"),
              let rawDate = value("date"),
              let rawTime = value("time"),
              let rawSum = value("sm"),
              let sum = minorUnits(rawSum),
              let time = instant(date: rawDate, time: rawTime) else { return nil }

        // `+` is a legal base64 character and percent-decoding turns `%20`
        // into a space, so the QR's control number arrives one character
        // different from the one the document contains. Restored here, at the
        // single place a QR becomes a value.
        let mac = value("mac").map { $0.replacingOccurrences(of: " ", with: "+") }

        return FiscalCheck(registerNumber: registerNumber, documentNumber: documentNumber,
                           fiscalTime: time, fiscalSum: sum, mac: mac)
    }

    /// "1240.50", "1240,50", "1240.5" and "7" all mean kopecks. Parsed as a
    /// Decimal rather than a Double so 1240.50 cannot arrive as 1240.4999.
    private static func minorUnits(_ text: String) -> Int? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalised), value >= 0 else { return nil }
        let unrounded = value * 100
        let kopecks = unrounded as NSDecimalNumber
        let rounded = kopecks.rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0,
                                   raiseOnExactness: false, raiseOnOverflow: false,
                                   raiseOnUnderflow: false, raiseOnDivideByZero: false))
        // A sum finer than a kopeck (e.g. 1240.505) would round to a
        // plausible but wrong value; refuse rather than guess. Trailing
        // zeros (1240.500) round to themselves and still parse.
        guard rounded.decimalValue == unrounded else { return nil }
        return Int(rounded.intValue)
    }

    /// `date` is YYYYMMDD; `time` is HHMMSS **or** HHMM, with or without
    /// colons — plenty of registers print the seconds and plenty do not, and
    /// refusing the shorter form failed the scan of a perfectly good receipt.
    /// Every other length is still refused: a guessed time is a wrong time.
    /// Read as Kyiv local — a receipt's printed time is wall-clock in the shop.
    private static func instant(date: String, time: String) -> Date? {
        let d = date.filter(\.isNumber)
        let t = time.filter(\.isNumber)
        guard d.count == 8, t.count == 6 || t.count == 4,
              let year = Int(d.prefix(4)),
              let month = Int(d.dropFirst(4).prefix(2)),
              let day = Int(d.dropFirst(6)),
              let hour = Int(t.prefix(2)),
              let minute = Int(t.dropFirst(2).prefix(2)),
              // HHMM carries no seconds; the minute it names started at :00.
              let second = Int(t.count == 6 ? t.dropFirst(4) : "00") else { return nil }
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        parts.hour = hour; parts.minute = minute; parts.second = second
        parts.timeZone = .kyiv
        // `date(from:)` is lenient about impossible components, so the result
        // is checked back: 2026-13-45 must not quietly become 2027-02-14.
        guard let built = Calendar.kyiv.date(from: parts) else { return nil }
        let read = Calendar.kyiv.dateComponents([.year, .month, .day, .hour, .minute, .second], from: built)
        guard read.year == year, read.month == month, read.day == day,
              read.hour == hour, read.minute == minute, read.second == second else { return nil }
        return built
    }
}
