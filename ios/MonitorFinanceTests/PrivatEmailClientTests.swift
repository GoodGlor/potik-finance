import XCTest
@testable import MonitorFinance

final class PrivatEmailClientTests: XCTestCase {
    private var client: PrivatEmailClient!
    private let creds = PrivatEmailCredentials(userId: "u1", secret: "s1")

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = PrivatEmailClient(session: URLSession(configuration: config))
    }

    private func respond(_ status: Int, _ body: String) {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    func testTheCredentialTravelsAsBearer() async throws {
        respond(200, #"{"transactions":[],"next_cursor":0}"#)
        _ = try await client.transactions(credentials: creds, since: 0, limit: 200)
        let sent = StubURLProtocol.requests.first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer u1:s1")
        XCTAssertEqual(sent?.url?.path, "/transactions")
        XCTAssertEqual(sent?.url?.query, "since=0&limit=200")
    }

    func testRegisterPostsWithoutAuth() async throws {
        respond(201, #"{"user_id":"u2","secret":"s2","email":"u-a@in.example"}"#)
        let r = try await client.register()
        XCTAssertEqual(r.email, "u-a@in.example")
        let sent = StubURLProtocol.requests.first
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "Authorization"))
    }

    func testA401IsUnauthorized() async {
        respond(401, #"{"detail":"unknown user or wrong secret"}"#)
        do {
            _ = try await client.status(credentials: creds)
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? PrivatEmailError, .unauthorized) }
    }

    func testA429IsRateLimited() async {
        respond(429, #"{"detail":"too many"}"#)
        do {
            _ = try await client.register()
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? PrivatEmailError, .rateLimited) }
    }

    func testDeleteAcceptsA204() async throws {
        respond(204, "")
        try await client.deleteAccount(credentials: creds)
        XCTAssertEqual(StubURLProtocol.requests.first?.httpMethod, "DELETE")
    }

    func testATransportFailureIsOffline() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.status(credentials: creds)
            XCTFail("expected a throw")
        } catch {
            guard case .offline = error as? PrivatEmailError else {
                return XCTFail("expected .offline, got \(error)")
            }
        }
    }
}
