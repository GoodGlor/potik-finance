import XCTest
@testable import MonitorFinance

final class PrivatStatementParserTests: XCTestCase {
    private func sampleRows() throws -> [[String]] {
        try XLSXReader.rows(from: Data(base64Encoded: PrivatFixtureData.sampleBase64)!)
    }

    func testParsesTheFixtureEndToEnd() throws {
        let statement = try PrivatStatementParser.parse(try sampleRows())
        XCTAssertEqual(statement.rows.count, 12)      // 14 minus the 2 USD rows
        XCTAssertEqual(statement.skippedNonUAH, 2)
    }

    func testFirstRowFieldByField() throws {
        let row = try XCTUnwrap(try PrivatStatementParser.parse(try sampleRows()).rows.first)
        XCTAssertEqual(row.category, "Тварини")
        XCTAssertEqual(row.cardSuffix, "*1111")
        XCTAssertEqual(row.descriptionText, "Крамниця Хвіст")
        XCTAssertEqual(row.amountMinor, -174_50)
        XCTAssertEqual(row.balanceMinor, 8885_00)
        XCTAssertEqual(row.balanceCurrency, "UAH")
        var kyiv = Calendar(identifier: .gregorian)
        kyiv.timeZone = PrivatStatementParser.kyiv
        let parts = kyiv.dateComponents([.year, .month, .day, .hour, .minute, .second], from: row.date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 8, 20, 18, 7, 59])
    }

    func testEmptyCardCellSurvivesAsEmptySuffix() throws {
        let statement = try PrivatStatementParser.parse(try sampleRows())
        let interest = try XCTUnwrap(statement.rows.first { $0.category == "Кредити" })
        XCTAssertEqual(interest.cardSuffix, "")
        XCTAssertEqual(interest.amountMinor, -1500_00)
    }

    func testPeriodSpansOldestToNewestRow() throws {
        let period = try XCTUnwrap(try PrivatStatementParser.parse(try sampleRows()).period)
        var kyiv = Calendar(identifier: .gregorian)
        kyiv.timeZone = PrivatStatementParser.kyiv
        // Fixture's oldest UAH row is the cardless "Кредити" interest row
        // (01.08.2026 00:00:00); the newest is the first row in the sheet
        // (20.08.2026 18:07:59, also checked field-by-field above).
        let oldest = try XCTUnwrap(kyiv.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 0, minute: 0, second: 0)))
        let newest = try XCTUnwrap(kyiv.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 18, minute: 7, second: 59)))
        XCTAssertEqual(period.lowerBound, oldest)
        XCTAssertEqual(period.upperBound, newest)
    }

    func testWrongHeaderIsNotAPrivatStatement() {
        let rows = [["Назва"], ["Дата", "Сума"], ["01.01.2026", "5"]]
        XCTAssertThrowsError(try PrivatStatementParser.parse(rows)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAPrivatStatement)
        }
    }

    func testMalformedAmountNamesItsLine() throws {
        var rows = try sampleRows()
        rows[2][4] = "сто гривень"
        XCTAssertThrowsError(try PrivatStatementParser.parse(rows)) {
            XCTAssertEqual($0 as? PrivatImportError, .badRow(3))
        }
    }

    func testHeaderAloneIsAnEmptyStatement() throws {
        let rows = Array((try sampleRows()).prefix(2))
        XCTAssertThrowsError(try PrivatStatementParser.parse(rows)) {
            XCTAssertEqual($0 as? PrivatImportError, .emptyStatement)
        }
    }

    func testExtraYearDigitNamesItsLine() throws {
        // `yyyy` in the date format is greedy: without a shape check first,
        // "20.08.20261 18:07:59" parses as year 20261 instead of failing.
        var rows = try sampleRows()
        rows[2][0] = "20.08.20261 18:07:59"
        XCTAssertThrowsError(try PrivatStatementParser.parse(rows)) {
            XCTAssertEqual($0 as? PrivatImportError, .badRow(3))
        }
    }

    func testShortRowRefusesRatherThanCrashing() {
        let rows = [PrivatStatementParser.header, ["01.01.2026 00:00:00", "x"]]
        XCTAssertThrowsError(try PrivatStatementParser.parse(rows)) {
            XCTAssertEqual($0 as? PrivatImportError, .badRow(2))
        }
    }

    func testCardSuffixShapes() {
        XCTAssertEqual(PrivatStatementParser.cardSuffix("5168 **** **** 1111"), "*1111")
        XCTAssertEqual(PrivatStatementParser.cardSuffix(""), "")
        XCTAssertEqual(PrivatStatementParser.cardSuffix("**** 39"), "")
    }

    func testMinorUnitsAreExact() {
        XCTAssertEqual(PrivatStatementParser.minor("-174.5"), -17450)
        XCTAssertEqual(PrivatStatementParser.minor("0.1"), 10)
        XCTAssertEqual(PrivatStatementParser.minor("30000.0"), 3_000_000)
        XCTAssertNil(PrivatStatementParser.minor("н/д"))

        // Pins the hardening in place: every case below ALSO "succeeds"
        // (with a wrong, plausible-looking answer) against the brief's
        // original one-line `Decimal(string:) → .intValue`. Nothing else
        // in this suite would notice if that hardening were reverted.
        XCTAssertNil(PrivatStatementParser.minor("12abc"))                 // partial parse
        XCTAssertNil(PrivatStatementParser.minor("1.2.3"))
        XCTAssertNil(PrivatStatementParser.minor("-"))
        XCTAssertNil(PrivatStatementParser.minor("9223372036854775807"))   // overflow
        XCTAssertNil(PrivatStatementParser.minor("1 234,56"))              // locale-styled
        XCTAssertNil(PrivatStatementParser.minor("1.005"))                 // more than 2 decimals

        // Pins the exact Int boundary the bounds check implements, in
        // both directions.
        XCTAssertEqual(PrivatStatementParser.minor("92233720368547758.07"), Int.max)
        XCTAssertNil(PrivatStatementParser.minor("92233720368547758.08"))
    }
}
