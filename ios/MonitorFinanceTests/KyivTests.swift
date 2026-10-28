import XCTest
@testable import MonitorFinance

/// The seed carries Kyiv offsets and the Python side groups by Kyiv-local
/// month. These tests exist so a device in another timezone cannot quietly
/// disagree with the statement the owner reads in their bank app.
final class KyivTests: XCTestCase {

    /// 2026-04-01 00:30 in Kyiv is 2026-03-31 21:30 UTC — the two calendars
    /// give different months, so this fails the moment bucketing switches to
    /// `Calendar.current` on a UTC (or US) device.
    func testMonthKeyBucketsByKyivNotUTC() {
        let justAfterMidnightInKyiv = Date(timeIntervalSince1970: 1_774_992_600)

        XCTAssertEqual(MonthKey(justAfterMidnightInKyiv).description, "2026-04")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.component(.month, from: justAfterMidnightInKyiv), 3,
                       "if this is 4 the fixture stopped straddling the boundary and the test proves nothing")
    }

    /// The same across a year boundary, where getting it wrong is loudest.
    func testMonthKeyCrossesTheYearInKyivTerms() {
        let newYearInKyiv = Date(timeIntervalSince1970: 1_767_220_200)   // 2026-01-01 00:30 +02:00
        XCTAssertEqual(MonthKey(newYearInKyiv).description, "2026-01")
    }

    func testAdvancedWrapsTheYearInBothDirections() {
        XCTAssertEqual(MonthKey(year: 2026, month: 12).advanced(by: 1).description, "2027-01")
        XCTAssertEqual(MonthKey(year: 2026, month: 1).advanced(by: -1).description, "2025-12")
        XCTAssertEqual(MonthKey(year: 2026, month: 3).advanced(by: -14).description, "2025-01")
        XCTAssertEqual(MonthKey(year: 2026, month: 8).advanced(by: 0).description, "2026-08")
    }

    func testOrderingIsChronological() {
        XCTAssertLessThan(MonthKey(year: 2025, month: 12), MonthKey(year: 2026, month: 1))
        XCTAssertLessThan(MonthKey(year: 2026, month: 1), MonthKey(year: 2026, month: 2))
        XCTAssertFalse(MonthKey(year: 2026, month: 2) < MonthKey(year: 2026, month: 2))
    }

    /// `start` must round-trip: the first instant of a month is in that month.
    func testStartOfMonthBelongsToThatMonth() {
        for month in 1...12 {
            let key = MonthKey(year: 2026, month: month)
            XCTAssertEqual(MonthKey(key.start), key, "month \(month) does not contain its own start")
            XCTAssertTrue(key.contains(key.start))
        }
    }

    /// Every seeded transaction must fall inside the eight months the seed
    /// claims to cover.
    ///
    /// Honest limit: this one does NOT go red when `Calendar.kyiv` is
    /// switched to UTC — no seeded row sits within the two or three hours
    /// after a Kyiv midnight that would move it across a boundary. It is a
    /// range check, not timezone coverage; `testMonthKeyBucketsByKyivNotUTC`
    /// above is the test that actually constrains the timezone.
    func testSeedTransactionsBucketIntoTheExpectedKyivMonths() throws {
        let seed = try SeedLoader.load()
        let months = Set(seed.transactions.map { MonthKey($0.date).description })
        XCTAssertEqual(months.sorted(),
                       ["2026-01", "2026-02", "2026-03", "2026-04",
                        "2026-05", "2026-06", "2026-07", "2026-08"])
    }
}
