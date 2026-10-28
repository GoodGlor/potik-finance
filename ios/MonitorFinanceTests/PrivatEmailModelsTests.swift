import XCTest
@testable import MonitorFinance

final class PrivatEmailModelsTests: XCTestCase {
    func testAPageDecodes() throws {
        let json = """
        {"transactions":[{"id":7,"occurred_at":"2026-08-28T09:34:00+00:00",
          "amount_minor":-12550,"currency":"UAH","card_suffix":"5*99",
          "merchant_raw":"Тест-Маркет","balance_after_minor":903450}],
         "next_cursor":7}
        """
        let page = try PrivatEmailDecoding.decoder.decode(PrivatEmailPage.self,
                                                          from: Data(json.utf8))
        XCTAssertEqual(page.nextCursor, 7)
        XCTAssertEqual(page.transactions.first?.amountMinor, -12550)
        XCTAssertEqual(page.transactions.first?.cardSuffix, "5*99")
        XCTAssertEqual(page.transactions.first?.occurredAt,
                       Date(timeIntervalSince1970: 1_787_909_640))
    }

    /// `letters/pending` and `/status` dates come from Python's isoformat(),
    /// which KEEPS microseconds — `.iso8601` alone refuses those strings.
    func testFractionalSecondsDecode() throws {
        let json = """
        {"confirmations":[{"id":1,"received_at":"2026-08-28T09:34:00.123456+00:00",
          "from":"forwarding-noreply@example.com","subject":"код","body":"123"}],
         "parse_failures":0}
        """
        let pending = try PrivatEmailDecoding.decoder.decode(PrivatEmailPending.self,
                                                             from: Data(json.utf8))
        XCTAssertEqual(pending.confirmations.first?.id, 1)
    }

    func testANullBalanceDecodes() throws {
        let json = """
        {"transactions":[{"id":8,"occurred_at":"2026-08-28T09:35:00+00:00",
          "amount_minor":500,"currency":"UAH","card_suffix":"5*99",
          "merchant_raw":"Тест","balance_after_minor":null}],"next_cursor":8}
        """
        let page = try PrivatEmailDecoding.decoder.decode(PrivatEmailPage.self,
                                                          from: Data(json.utf8))
        XCTAssertNil(page.transactions.first?.balanceAfterMinor)
    }
}
