import XCTest
@testable import MonitorFinance

final class TaxCabinetClientTests: XCTestCase {
    private var client: TaxCabinetClient!

    private let check = FiscalCheck(
        registerNumber: "9999999999", documentNumber: "777777",
        // 00:00:52 Kyiv — with seconds, deliberately. +02:00: Kyiv is EET,
        // not EEST, on January 1st.
        fiscalTime: ISO8601DateFormatter().date(from: "2026-01-01T00:00:52+02:00")!,
        fiscalSum: 799_23, mac: nil)

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = TaxCabinetClient(session: URLSession(configuration: config))
    }

    private func respond(_ status: Int, _ body: String, contentType: String = "application/json") {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                             headerFields: ["Content-Type": contentType])!,
             Data(body.utf8))
        }
    }

    func testTheRequestAsksForTheMinuteAndNeverTheSecond() {
        let items = TaxCabinetClient.query(for: check)
        let by = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // The QR truncates to the minute; the API matches on it. Sending :52
        // returns "Інформація відсутня" for a receipt that exists.
        XCTAssertEqual(by["date"], "2026-01-01 00:00:00")
        XCTAssertEqual(by["id"], "777777", "`id` is the DOCUMENT number")
        XCTAssertEqual(by["fn"], "9999999999", "`fn` is the REGISTER number")
        XCTAssertEqual(by["sm"], "799.23")
        XCTAssertEqual(by["type"], "3")
        XCTAssertNil(by["captcha"], "the app sends only the receipt's own fields")
    }

    /// Errors do not use status codes. Branching on `response.status` would
    /// treat every failure as a success.
    func testA200CarryingAnErrorIsNotPublished() async {
        respond(200, #"{"error":"Помилка","error_description":"Інформація відсутня Не знайдено."}"#)
        await assertThrows(.notPublished)
    }

    func testA200WithNoCheckXmlIsNotPublished() async {
        respond(200, #"{"fn":"9999999999","xml":false}"#)
        await assertThrows(.notPublished)
    }

    /// The only warning this endpoint will ever give that we are asking too
    /// often: an HTML page where JSON was promised.
    func testAnHtmlBodyIsThrottledRatherThanMalformed() async {
        respond(200, "<html><body>429</body></html>", contentType: "text/html")
        await assertThrows(.throttled)
    }

    func testATransportFailureIsOfflineRatherThanAnUnhandledError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.check(check)
            XCTFail("must throw")
        } catch let error as TaxCabinetError {
            guard case .offline = error else { return XCTFail("threw \(error)") }
        } catch { XCTFail("threw \(error)") }
    }

    func testAGoodBodyIsParsedIntoLines() async throws {
        respond(200, #"{"checkXml":"\#(CheckFixture.base64)"}"#)
        let parsed = try await client.check(check)
        XCTAssertEqual(parsed.fiscalTotal, CheckFixture.fiscalTotal)
        XCTAssertEqual(parsed.lines.count, CheckFixture.lines.count)
    }

    /// A fiscal receipt must never land in a disk cache outside the app's own
    /// protection class.
    func testTheRequestForbidsCaching() async throws {
        respond(200, #"{"checkXml":"\#(CheckFixture.base64)"}"#)
        _ = try? await client.check(check)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    private func assertThrows(_ expected: TaxCabinetError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.check(check)
            XCTFail("must throw \(expected)", file: file, line: line)
        } catch let error as TaxCabinetError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
    }
}
