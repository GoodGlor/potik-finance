import Foundation

/// The email backend's client — the same shape as `MonobankClient`, and for
/// the same reasons (its doc comments are the authority): a private
/// no-cache session so money data never lands in a disk cache outside the
/// app's protection class, one session per process, transport errors
/// wrapped, bodies truncated before they can reach a view. No pacer: this
/// backend has no request-rate contract.
struct PrivatEmailClient: PrivatEmailAPI {
    /// A placeholder: point it at your own deployment of the inbound email backend.
    static let defaultBase =
        URL(string: "https://inbound.example.com")!

    private let session: URLSession
    private let base: URL

    static let privateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init(session: URLSession = PrivatEmailClient.privateSession,
         base: URL = PrivatEmailClient.defaultBase) {
        self.session = session
        self.base = base
    }

    func register() async throws -> PrivatEmailRegistration {
        try decode(try await send("POST", "/register", credentials: nil))
    }

    func transactions(credentials: PrivatEmailCredentials,
                      since: Int, limit: Int) async throws -> PrivatEmailPage {
        try decode(try await send("GET", "/transactions", credentials: credentials,
                                  query: [("since", String(since)), ("limit", String(limit))]))
    }

    func pendingLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailPending {
        try decode(try await send("GET", "/letters/pending", credentials: credentials))
    }

    func status(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatus {
        try decode(try await send("GET", "/status", credentials: credentials))
    }

    func deleteAccount(credentials: PrivatEmailCredentials) async throws {
        _ = try await send("DELETE", "/account", credentials: credentials)
    }

    // MARK: - Board #97, emailed statements

    func statements(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatements {
        try decode(try await send("GET", "/statements", credentials: credentials))
    }

    /// **Returns the raw bytes, undecoded**, and that is the card's decision:
    /// the phone parses. These go straight to `importPrivatStatement`, the
    /// same entry point the file picker uses, so `PrivatStatementParser`
    /// stays the only parser in the system.
    func statementBytes(credentials: PrivatEmailCredentials, id: Int) async throws -> Data {
        try await send("GET", "/statements/\(id)", credentials: credentials)
    }

    func consumeStatement(credentials: PrivatEmailCredentials, id: Int) async throws {
        _ = try await send("DELETE", "/statements/\(id)", credentials: credentials)
    }

    // MARK: - Board #145, a statement that arrived as a link

    func statementLinks(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatementLinks {
        try decode(try await send("GET", "/statement-links", credentials: credentials))
    }

    func consumeStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws {
        _ = try await send("DELETE", "/statement-links/\(id)", credentials: credentials)
    }

    // MARK: - Board #171, following the link on the person's say-so

    func downloadStatementLink(credentials: PrivatEmailCredentials,
                               id: Int) async throws -> PrivatEmailStatement {
        try decode(try await send("POST", "/statement-links/\(id)/download",
                                  credentials: credentials))
    }

    // MARK: - Board #175, the last few letters

    func recentLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailRecentLetters {
        try decode(try await send("GET", "/letters/recent", credentials: credentials))
    }

    // MARK: - Board #186, receipts the server chases

    func queueReceipt(credentials: PrivatEmailCredentials, check: FiscalCheck) async throws {
        // Only what is printed on the QR. The server can ask nothing smaller
        // and is given nothing more — see board #186's privacy decision.
        let body = try JSONSerialization.data(withJSONObject: [
            "registerNumber": check.registerNumber,
            "documentNumber": check.documentNumber,
            "fiscalSum": check.fiscalSum,
            "fiscalTime": PrivatEmailDecoding.iso8601.string(from: check.fiscalTime),
        ])
        _ = try await send("POST", "/receipts", credentials: credentials, body: body)
    }

    func readyReceipts(credentials: PrivatEmailCredentials) async throws -> [PrivatEmailReceipt] {
        try decode(try await send("GET", "/receipts", credentials: credentials))
    }

    func consumeReceipt(credentials: PrivatEmailCredentials, id: Int) async throws {
        _ = try await send("DELETE", "/receipts/\(id)", credentials: credentials)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try PrivatEmailDecoding.decoder.decode(T.self, from: data) }
        catch { throw PrivatEmailError.malformed(String(describing: error)) }
    }

    private func send(_ method: String, _ path: String,
                      credentials: PrivatEmailCredentials?,
                      query: [(String, String)] = [],
                      body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let credentials {
            request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PrivatEmailError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PrivatEmailError.malformed("not an HTTP response")
        }
        switch http.statusCode {
        case 200, 201, 204: return data
        case 401: throw PrivatEmailError.unauthorized
        case 429: throw PrivatEmailError.rateLimited
        default:
            throw PrivatEmailError.server(http.statusCode,
                                          String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
