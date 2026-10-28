import XCTest
@testable import MonitorFinance

@MainActor
final class SmokeTests: XCTestCase {
    override func setUp() { super.setUp(); pinUkrainianFormatting() }

    func testHostAppSymbolsAreVisible() {
        // Theme lives in the app target; seeing it proves @testable import works.
        XCTAssertEqual(1_234_56.uah, "1 235 ₴")
    }

    /// `signedUahExact` is now the single home of the sign that three screens
    /// used to spell for themselves, so the sign is worth pinning: it is
    /// U+2212 MINUS SIGN, not the hyphen-minus a keyboard produces, and the
    /// magnitude that follows it is unsigned.
    func testSignedUahExactCarriesTheDirectionAndTheKopecks() {
        XCTAssertEqual((-25_050).signedUahExact, "\u{2212}250,50 ₴")
        XCTAssertEqual(25_050.signedUahExact, "+250,50 ₴")
        XCTAssertEqual(0.signedUahExact, "\u{2212}0,00 ₴",
                       "zero is not income; it takes the same sign every screen already gave it")
    }
}
