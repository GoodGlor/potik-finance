import XCTest
@testable import MonitorFinance

final class FiscalQRTests: XCTestCase {

    private let valid = "https://cabinet.tax.gov.ua/cashregs/check?id=1234567890&fn=3000000000&date=20260821&time=181200&sm=1240.50"

    func testAWellFormedCheckUrlYieldsEveryField() throws {
        let c = try XCTUnwrap(FiscalQR.parse(valid))
        // Which parameter feeds which field, spelled out: `id` is the
        // document, `fn` the register. The values are deliberately
        // unmistakable, so reading them the other way round reddens here.
        XCTAssertEqual(c.documentNumber, "1234567890", "`id` is the document number")
        XCTAssertEqual(c.registerNumber, "3000000000", "`fn` is the register number")
        XCTAssertEqual(c.fiscalSum, 1_240_50)
        // 18:12:00 Kyiv on 2026-08-21 — asserted as an instant, so a parser
        // that read the clock in UTC would land three hours out and fail.
        XCTAssertEqual(c.fiscalTime,
                       ISO8601DateFormatter().date(from: "2026-08-21T18:12:00+03:00"))
    }

    /// Both separators appear on real receipts, and a parser that took only
    /// one would silently return nil for half of them.
    func testTheSumAcceptsACommaOrADotAndAlwaysLandsOnKopecks() {
        XCTAssertEqual(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "1240,50"))?.fiscalSum, 1_240_50)
        XCTAssertEqual(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "1240.5"))?.fiscalSum, 1_240_50)
        XCTAssertEqual(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "7"))?.fiscalSum, 7_00)
        XCTAssertEqual(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "0"))?.fiscalSum, 0)
    }

    /// Trailing zeros are a formatting choice by the register and still
    /// parse; a sum truly finer than a kopeck would round to a plausible
    /// but wrong value, so it must be refused instead.
    func testASumFinerThanAKopeckIsRefusedRatherThanRounded() {
        XCTAssertEqual(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "1240.500"))?.fiscalSum, 1_240_50)
        XCTAssertNil(FiscalQR.parse(valid.replacingOccurrences(of: "1240.50", with: "1240.505")))
    }

    /// Some registers print HH:MM:SS in the query.
    func testAColonSeparatedTimeIsAccepted() {
        let c = FiscalQR.parse(valid.replacingOccurrences(of: "time=181200", with: "time=18:12:00"))
        XCTAssertEqual(c?.fiscalTime,
                       ISO8601DateFormatter().date(from: "2026-08-21T18:12:00+03:00"))
    }

    /// Plenty of registers print HHMM and no seconds. Refusing those failed
    /// the scan of a perfectly good receipt — the minute it names started at
    /// :00, which is not a guess.
    func testATimeWithoutSecondsIsAcceptedAsTheStartOfThatMinute() {
        for form in ["time=1812", "time=18:12"] {
            let c = FiscalQR.parse(valid.replacingOccurrences(of: "time=181200", with: form))
            XCTAssertEqual(c?.fiscalTime,
                           ISO8601DateFormatter().date(from: "2026-08-21T18:12:00+03:00"),
                           form)
        }
        // Every OTHER length is still refused: 5 digits is a typo, not a
        // shorter convention, and 18:12:0 could mean :00 or :05.
        for bad in ["time=18120", "time=181", "time=18", "time=1812000"] {
            XCTAssertNil(FiscalQR.parse(valid.replacingOccurrences(of: "time=181200", with: bad)), bad)
        }
    }

    func testAnythingMissingOrMalformedIsRefusedRatherThanGuessed() {
        for bad in [
            "not a url at all",
            "https://example.com/check?id=1&fn=2&date=20260821&time=181200&sm=10",   // wrong host
            valid.replacingOccurrences(of: "&sm=1240.50", with: ""),                 // no sum
            valid.replacingOccurrences(of: "&fn=3000000000", with: ""),              // no register number
            valid.replacingOccurrences(of: "id=1234567890&", with: ""),               // no document number
            valid.replacingOccurrences(of: "date=20260821", with: "date=2026-13-45"),// impossible date
            valid.replacingOccurrences(of: "sm=1240.50", with: "sm=abc"),            // unparseable sum
            valid.replacingOccurrences(of: "sm=1240.50", with: "sm=-5"),             // negative sum
        ] {
            XCTAssertNil(FiscalQR.parse(bad), "must refuse: \(bad)")
        }
        // …and the valid one still parses, so the loop above cannot be passing
        // because `parse` returns nil for everything.
        XCTAssertNotNil(FiscalQR.parse(valid))
    }

    /// The control number, which the register also prints inside the document.
    /// Carried so the fetched check can be proven to be the check that was
    /// scanned — see `CheckXML`.
    func testTheControlNumberSurvivesPercentDecodingWithItsPlusIntact() throws {
        // A real QR spells `+` as `%20`... which decodes to a SPACE, not a plus.
        // Compared naively against the XML's `+`, every genuine receipt fails its
        // own integrity check — and the failure reads as "wrong receipt".
        let payload = valid + "&mac=ABoAAAddAAAAABYAEwdiAAOWwXRxIIB2lGgd9%20w%3D"
        let c = try XCTUnwrap(FiscalQR.parse(payload))
        XCTAssertEqual(c.mac, "ABoAAAddAAAAABYAEwdiAAOWwXRxIIB2lGgd9+w=")
    }

    /// Every sample the picker offers is synthesised without one, and the
    /// simulator has no camera — so a required `mac` would refuse the only
    /// scanning path a UI test can reach.
    func testAQrWithNoControlNumberStillParses() throws {
        let c = try XCTUnwrap(FiscalQR.parse(valid))
        XCTAssertNil(c.mac)
        XCTAssertEqual(c.documentNumber, "1234567890")
    }

    /// It is persisted inside the fetch queue, so it must survive a round trip
    /// through the same coder `Repository` uses.
    func testAParsedCheckSurvivesAJsonRoundTrip() throws {
        let c = try XCTUnwrap(FiscalQR.parse(valid + "&mac=AAAA%2B%3D"))
        let data = try SeedLoader.encoder.encode(c)
        XCTAssertEqual(try SeedLoader.decoder.decode(FiscalCheck.self, from: data), c)
    }
}
