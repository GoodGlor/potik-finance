import XCTest
@testable import MonitorFinance

/// Serves canned responses in-process. A test that reaches the real
/// api.monobank.ua is a failing test, not a slow one.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class MonobankClientTests: XCTestCase {
    private var client: MonobankClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = MonobankClient(session: URLSession(configuration: config))
    }

    private func respond(_ status: Int, _ body: String) {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
    }

    func testClientInfoDecodes() async throws {
        respond(200, """
        {"clientId":"c1","name":"Тест","accounts":[
          {"id":"a1","type":"black","currencyCode":980,"balance":100,
           "creditLimit":0,"maskedPan":["000000******1111"]}]}
        """)
        let info = try await client.clientInfo(token: "tok")
        XCTAssertEqual(info.clientId, "c1")
        XCTAssertEqual(info.accounts.first?.id, "a1")
    }

    func testTheTokenTravelsInXToken() async throws {
        respond(200, #"{"clientId":"c","name":"n","accounts":[]}"#)
        _ = try await client.clientInfo(token: "secret-token")
        let sent = StubURLProtocol.requests.first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-Token"), "secret-token")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sent?.url?.path, "/personal/client-info")
    }

    func testStatementPathCarriesUnixSeconds() async throws {
        respond(200, "[]")
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_086_400)
        _ = try await client.statement(token: "t", accountId: "acc", from: from, to: to)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path,
                       "/personal/statement/acc/1700000000/1700086400")
    }

    /// `amount` is the account's currency; `currencyCode` describes
    /// `operationAmount`. A mapping that swaps them turns a €499 Netflix charge
    /// into ₴499 and nothing complains.
    func testStatementDecodesAndKeepsTheTwoAmountsApart() async throws {
        respond(200, """
        [{"id":"x1","time":1700000000,"description":"Тест","mcc":5411,
          "amount":-43120,"operationAmount":-999,"currencyCode":978,
          "commissionRate":0,"cashbackAmount":0,"hold":false,
          "receiptId":"mono-r-1","counterName":"Хтось"}]
        """)
        let rows = try await client.statement(
            token: "t", accountId: "a",
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86_400))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, -43_120)
        XCTAssertEqual(rows[0].operationAmount, -999)
        XCTAssertEqual(rows[0].currencyCode, 978)
        XCTAssertEqual(rows[0].monoReceiptId, "mono-r-1")
        XCTAssertEqual(rows[0].counterName, "Хтось")
    }

    /// monobank omits keys rather than nulling them.
    func testAbsentOptionalKeysDecode() async throws {
        respond(200, #"[{"id":"x","time":1,"description":"d","amount":-1}]"#)
        let rows = try await client.statement(
            token: "t", accountId: "a",
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10))
        XCTAssertNil(rows[0].hold)
        XCTAssertNil(rows[0].mcc)
        XCTAssertNil(rows[0].monoReceiptId)
    }

    func test403IsInvalidToken() async {
        respond(403, "forbidden")
        await XCTAssertThrowsErrorAsync(try await client.clientInfo(token: "t")) {
            XCTAssertEqual($0 as? MonobankError, .invalidToken)
        }
    }

    func test429IsRateLimited() async {
        respond(429, "too many")
        await XCTAssertThrowsErrorAsync(try await client.clientInfo(token: "t")) {
            XCTAssertEqual($0 as? MonobankError, .rateLimited)
        }
    }

    func test500IsServer() async {
        respond(500, "boom")
        await XCTAssertThrowsErrorAsync(try await client.clientInfo(token: "t")) {
            guard case .server(let code, _) = ($0 as? MonobankError) else {
                return XCTFail("expected .server, got \($0)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    func testATransportFailureIsOfflineRatherThanACrash() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await XCTAssertThrowsErrorAsync(try await client.clientInfo(token: "t")) {
            guard case .offline = ($0 as? MonobankError) else {
                return XCTFail("expected .offline, got \($0)")
            }
        }
    }

    func testA200WeCannotDecodeIsMalformedRatherThanOffline() async {
        respond(200, "{ not json")
        await XCTAssertThrowsErrorAsync(try await client.clientInfo(token: "t")) {
            guard case .malformed = ($0 as? MonobankError) else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    /// Windowing is the engine's job. A client that silently truncates would
    /// leave a hole nobody could see.
    func testAWindowLongerThan31DaysIsRefusedWithoutARequest() async {
        respond(200, "[]")
        let from = Date(timeIntervalSince1970: 0)
        await XCTAssertThrowsErrorAsync(
            try await client.statement(token: "t", accountId: "a",
                                       from: from, to: from.addingTimeInterval(32 * 86_400))
        ) { XCTAssertEqual($0 as? MonobankError, .windowTooLong) }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "it must not reach the network")
    }

    /// The boundary that actually ships. `SyncPlan.window` is exactly
    /// `31 * 86_400` and every backward window is built as a full one, so the
    /// comparison in `statement` has to be `<=`: a `<` would refuse every
    /// backfill request the engine ever makes, and the test above — which
    /// asks for 32 days — would still pass.
    func testAWindowOfExactly31DaysIsSentRatherThanRefused() async throws {
        XCTAssertEqual(SyncPlan.window, MonobankClient.maxWindow,
                       "the planner and the client must mean the same 31 days")
        respond(200, "[]")
        let from = Date(timeIntervalSince1970: 0)
        _ = try await client.statement(token: "t", accountId: "a",
                                       from: from,
                                       to: from.addingTimeInterval(MonobankClient.maxWindow))
        XCTAssertEqual(StubURLProtocol.requests.count, 1,
                       "the window the engine actually sends must reach the network")
    }

    // MARK: nothing the bank says is written to disk by URLSession

    /// `URLSession.shared` routes through `URLCache.shared`, whose DISK store
    /// lives in `Library/Caches` under the system default protection class —
    /// not the `completeUntilFirstUserAuthentication` `Repository.save` asks
    /// for. A 200 without `Cache-Control: no-store` is heuristically cacheable,
    /// so a statement could land there, unreadable to `wipe()`, `disconnect`
    /// and `wipeForNewClient` alike: person A's spending still on the phone
    /// after person B's token is pasted in.
    func testTheDefaultSessionIsNotTheSharedOneAndHasNoCache() {
        XCTAssertFalse(MonobankClient.privateSession === URLSession.shared,
                       "statements must never travel on the shared session")
        let config = MonobankClient.privateSession.configuration
        XCTAssertNil(config.urlCache, "no cache means no disk store to leak from")
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    /// Belt and braces: the policy travels on the request too, so an injected
    /// session cannot put a statement back on disk.
    func testEveryRequestRefusesTheCacheOnItsOwn() async throws {
        respond(200, #"{"clientId":"c","name":"n","accounts":[]}"#)
        _ = try await client.clientInfo(token: "t")
        XCTAssertEqual(StubURLProtocol.requests.first?.cachePolicy,
                       .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testABackwardsWindowIsRefused() async {
        respond(200, "[]")
        let from = Date(timeIntervalSince1970: 86_400)
        await XCTAssertThrowsErrorAsync(
            try await client.statement(token: "t", accountId: "a",
                                       from: from, to: from.addingTimeInterval(-1))
        ) { XCTAssertEqual($0 as? MonobankError, .windowInvalid) }
    }
}
