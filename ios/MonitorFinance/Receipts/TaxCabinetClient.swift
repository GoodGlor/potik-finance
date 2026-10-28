import Foundation

/// The one place in the app that fetches a fiscal receipt from the tax
/// service's public lookup. Model and comments follow `MonobankClient` —
/// same shape, one host over.
struct TaxCabinetClient: TaxCabinetAPI {
    static let defaultBase = URL(string: "https://cabinet.tax.gov.ua")!
    static let path = "/ws/api_public/rro/chkAllWeb"

    private let session: URLSession
    private let base: URL

    /// Never `URLSession.shared`, for the reason `MonobankClient.privateSession`
    /// documents at length: the shared session's disk cache sits in
    /// `Library/Caches` under the system default protection class — outside
    /// everything this app does to keep money data encrypted, and it survives
    /// `wipe()`. A fiscal receipt names the cashier and can carry a loyalty
    /// number, so it is exactly the payload that must not land there.
    ///
    /// Its own session, not `MonobankClient.privateSession` shared: different
    /// host, different connection pool — one instance for the process, same
    /// reasoning as the other client's.
    static let privateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init(session: URLSession = TaxCabinetClient.privateSession,
         base: URL = TaxCabinetClient.defaultBase) {
        self.session = session
        self.base = base
    }

    /// `date` matches the endpoint's Kyiv-local, minute-truncated wall clock —
    /// see `dateFormatter` below. `sm` is rebuilt from `fiscalSum`, never
    /// replayed from the QR's original text (which is not kept), because the
    /// endpoint compares it numerically.
    static func query(for check: FiscalCheck) -> [URLQueryItem] {
        [
            URLQueryItem(name: "id", value: check.documentNumber),
            URLQueryItem(name: "fn", value: check.registerNumber),
            URLQueryItem(name: "sm", value: String(format: "%.2f", Double(check.fiscalSum) / 100)),
            URLQueryItem(name: "date", value: dateFormatter.string(from: check.fiscalTime)),
            URLQueryItem(name: "type", value: "3"),
        ]
    }

    /// The QR truncates to the minute and the endpoint matches on the minute
    /// — a real receipt's true fiscal time can end `:52`, and sending the
    /// seconds returns "not found" for a receipt that exists. The pattern
    /// ends in a LITERAL `00`, never `ss`. `.kyiv`, never the device's
    /// calendar: the receipt's wall clock is Kyiv's, not wherever the phone
    /// happens to be.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:'00'"
        formatter.timeZone = .kyiv
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        var components = URLComponents(url: base.appendingPathComponent(Self.path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = Self.query(for: check)

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        // Belt and braces with `privateSession`: this one travels with the
        // request, so an injected session cannot reintroduce a disk cache for
        // a fiscal receipt.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No headers at all — no `Authorization`, no cookie, no `User-Agent`,
        // no `Referer`. The endpoint wants none and sending them is a
        // fingerprint.

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A timeout or a DNS failure is the network being unreachable,
            // not a bug here. Without this it escapes as an unhandled error
            // instead of a retriable one.
            throw TaxCabinetError.offline(error.localizedDescription)
        }

        // Errors never use status codes here — a wrong parameter and an
        // unpublished receipt both return 200 with an `error` member — so
        // this branches on the body, never on the HTTP status.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The endpoint publishes no rate-limit headers. An HTML body
            // where JSON was promised is the only warning the app will ever
            // get that it is asking too often — decided before JSON is
            // attempted a second time, not after a decode failure.
            throw TaxCabinetError.throttled
        }

        if json["error"] != nil {
            throw TaxCabinetError.notPublished
        }
        guard let base64 = json["checkXml"] as? String else {
            throw TaxCabinetError.notPublished
        }

        return try CheckXML.parse(base64: base64)
    }
}
