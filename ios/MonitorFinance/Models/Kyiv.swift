import Foundation

/// Every month boundary in this app is a **Kyiv** boundary, on every device.
///
/// The seed carries Kyiv offsets and the Python side groups by Kyiv-local
/// month, so a transaction stamped 2026-03-31T23:30+03:00 belongs to March.
/// Bucketing it with `Calendar.current` on a device set to, say, Los Angeles
/// puts it in March too — but one stamped 2026-04-01T00:30+03:00 lands back
/// in March there, and the monthly sums the whole budget subsystem rests on
/// quietly stop matching the statement the owner can see in their bank app.
///
/// Nothing in the app may bucket, format or compare a transaction date with
/// `Calendar.current` or `TimeZone.current`. Use these.
extension TimeZone {
    /// Falls back to a fixed +02:00 rather than trapping: a missing tz
    /// database entry must not take the app down, and Kyiv's standard offset
    /// is a closer wrong answer than the device's.
    static let kyiv = TimeZone(identifier: "Europe/Kyiv") ?? TimeZone(secondsFromGMT: 2 * 3600)!
}

extension Calendar {
    static let kyiv: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .kyiv
        // NOT the interface language (board #85). This calendar does date
        // ARITHMETIC — month boundaries, day starts — and every one of those
        // answers must be the same whichever language the app is in. The
        // formatters that turn a date into WORDS take the language; this one
        // never renders anything.
        calendar.locale = Locale(identifier: "uk_UA")
        return calendar
    }()
}

/// **One `DateFormatter` per format and language, not one per call.** Board #105.
///
/// A `DateFormatter` is an ICU object, not a struct, and building one costs
/// roughly two orders of magnitude more than formatting a date with one that
/// already exists. **Measured on this machine: ~130 µs to build and use one,
/// against ~2 µs to reuse.**
///
/// That is not academic. `QueueView.countText` formats a date for **every
/// generic-merchant card**, and the demo queue is 61 cards of which 35 are one
/// merchant's card-to-card transfers — so a single render was building 35
/// formatters on the main thread, ~4.6 ms here and more on a phone in a Debug
/// build, against a 16.7 ms frame. A fast flick rebuilds rows as they arrive.
/// The feed does the same thing per row for its time, and per section for its
/// day.
///
/// **Keyed by the LANGUAGE as well as the format.** `L10n.formatting` is
/// process-wide and mutable — somebody can change the interface language while
/// a screen is up — and a cache keyed on the format alone would keep printing
/// «18 березня» to an English reader for the rest of the session. That is board
/// #96's defect arriving through a cache, and `ScrollCostTests` pins it.
enum KyivFormat {
    /// The formatting happens inside the lock too. `DateFormatter` is
    /// documented thread-safe for reading, but the whole premise here is that
    /// formatting is the cheap half — there is nothing to win by holding the
    /// lock for less, and plenty to lose by reasoning about it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, _ format: String) -> String {
        let language = L10n.formatting
        let key = format + "\u{0}" + language.rawValue
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.calendar = .kyiv
        formatter.timeZone = .kyiv
        formatter.locale = language.locale
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter.string(from: date)
    }
}

/// A single Kyiv-local month, used as the key every monthly total groups by.
/// Comparable and Hashable so a feed can page through months without doing
/// date arithmetic at each call site.
struct MonthKey: Hashable, Comparable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date) {
        let parts = Calendar.kyiv.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// First instant of the month, in Kyiv.
    var start: Date {
        Calendar.kyiv.date(from: DateComponents(year: year, month: month)) ?? .distantPast
    }

    func advanced(by months: Int) -> MonthKey {
        let total = year * 12 + (month - 1) + months
        return MonthKey(year: total / 12, month: total % 12 + 1)
    }

    func contains(_ date: Date) -> Bool { MonthKey(date) == self }

    static func < (a: MonthKey, b: MonthKey) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }

    /// "серпень 2026" — lowercase, as Ukrainian writes it mid-sentence.
    ///
    /// **Nominative**, because `LLLL` is the standalone form. That is right for
    /// a heading and WRONG after a preposition — see `fromTitle`.
    var title: String { KyivFormat.string(start, "LLLL yyyy") }

    /// "1 вересня 2026" — the form that follows «з», and the reason this
    /// exists at all.
    ///
    /// Ukrainian inflects: «з вересень 2026» is what `title` produces after a
    /// preposition and it is simply ungrammatical. `MMMM` alongside a day is
    /// the genitive form, so naming the day both fixes the case and says
    /// exactly when the change lands — which is more useful than the month
    /// alone. Board #114, and found by reading the screen rather than the
    /// code.
    var fromTitle: String { KyivFormat.string(start, "d MMMM yyyy") }

    var description: String { String(format: "%04d-%02d", year, month) }
}
