import Foundation

/// The one place in the app that performs a network request.
///
/// Deliberately without pacing: the client makes exactly the request it is
/// asked to make. Pacing belongs to `SyncEngine`, which is the only thing that
/// knows what else is queued.
struct MonobankClient: MonobankAPI {
    static let defaultBase = URL(string: "https://api.monobank.ua")!

    /// monobank's documented maximum is 31 days + 1 hour. We ask for a flat 31
    /// so the request sits comfortably inside the limit rather than resting on
    /// the extra hour.
    static let maxWindow: TimeInterval = 31 * 86_400

    private let session: URLSession
    private let base: URL

    /// Never `URLSession.shared`. The shared session stores responses in
    /// `URLCache.shared`, which has a DISK store in `Library/Caches` under the
    /// system default protection class — not the
    /// `completeUntilFirstUserAuthentication` `Repository.save` asks for. A 200
    /// without `Cache-Control: no-store` is heuristically cacheable, so a whole
    /// statement (merchants, amounts, counterparties) could land there, outside
    /// everything the app does to keep money data encrypted, and survive
    /// `wipe()`, `disconnect` and `wipeForNewClient` — leaving one person's
    /// statements on disk after another person's token is pasted in.
    ///
    /// One instance for the process: a `URLSession` owns a connection pool and
    /// a delegate queue, and a fresh one per `MonobankClient` would leak both.
    static let privateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init(session: URLSession = MonobankClient.privateSession,
         base: URL = MonobankClient.defaultBase) {
        self.session = session
        self.base = base
    }

    func clientInfo(token: String) async throws -> MonobankClientInfo {
        try await get("/personal/client-info", token: token)
    }

    func statement(token: String, accountId: String,
                   from: Date, to: Date) async throws -> [MonobankStatementItem] {
        guard to >= from else { throw MonobankError.windowInvalid }
        guard to.timeIntervalSince(from) <= Self.maxWindow else { throw MonobankError.windowTooLong }
        let path = "/personal/statement/\(accountId)"
            + "/\(Int(from.timeIntervalSince1970))/\(Int(to.timeIntervalSince1970))"
        return try await get(path, token: token)
    }

    /// A plain decoder on purpose. `SeedLoader.decoder` is configured
    /// `.iso8601`; monobank sends `time` as an integer, and sharing that
    /// decoder would be wrong the first time any date-shaped field appears.
    private static let decoder = JSONDecoder()

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.setValue(token, forHTTPHeaderField: "X-Token")
        request.timeoutInterval = 30
        // Belt and braces with `privateSession`: this one travels with the
        // request, so an injected session cannot reintroduce a disk cache for
        // a statement.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A timeout or a DNS failure is the bank being unreachable, not a
            // bug here. Without this it escapes as an unhandled error and the
            // sync run dies instead of retrying later.
            throw MonobankError.offline(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MonobankError.malformed("not an HTTP response")
        }
        switch http.statusCode {
        case 200: break
        case 403: throw MonobankError.invalidToken
        case 429: throw MonobankError.rateLimited
        default:
            throw MonobankError.server(http.statusCode,
                                       String(decoding: data.prefix(200), as: UTF8.self))
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw MonobankError.malformed(String(describing: error))
        }
    }
}
