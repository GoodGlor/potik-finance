import Foundation

/// The email backend as the app sees it. Wire shapes only, like
/// `MonobankModels` — the real client and the Debug stub both conform.
struct PrivatEmailCredentials: Equatable {
    var userId: String
    var secret: String
    var authorization: String { "Bearer \(userId):\(secret)" }
}

struct PrivatEmailRegistration: Codable, Hashable {
    var userId: String
    /// Shown once by the backend. The caller MUST land it in the Keychain
    /// before letting go of this value.
    var secret: String
    var email: String
}

struct PrivatEmailTransaction: Codable, Hashable {
    /// Insertion-order id — also the cursor. Per-user, already deduplicated
    /// server-side, so it is the row's identity on the phone too.
    var id: Int
    var occurredAt: Date
    /// Signed minor units; negative = money out. Direction, commission
    /// folding and the midnight rollover are all the backend's job.
    var amountMinor: Int
    /// "UAH" or "USD". A dollar letter with a UAH equivalent arrives
    /// already converted as UAH; bare USD rows get skipped by the mapper.
    var currency: String
    /// Masked as the letter writes it: "5*99" — first digit + last two.
    /// NOT the statement's "*1234"; only the last two digits are shared.
    var cardSuffix: String
    var merchantRaw: String
    var balanceAfterMinor: Int?
}

struct PrivatEmailPage: Codable, Hashable {
    var transactions: [PrivatEmailTransaction]
    var nextCursor: Int
}

struct PrivatEmailConfirmation: Codable, Hashable {
    var id: Int
    var receivedAt: Date
    var from: String
    var subject: String
    var body: String
}

/// Board #175 — one of the last few letters, as metadata and nothing else.
///
/// **There is no body here and there never will be.** The backend discards
/// them on arrival; what it keeps for every letter is `from` and `subject`,
/// indefinitely, which board #158 accepted knowingly. This type is that
/// decision made visible: showing somebody what is being kept about them is
/// strictly better than keeping it and never showing them.
struct PrivatEmailRecentLetter: Codable, Hashable, Identifiable {
    var id: Int
    var receivedAt: Date
    var from: String
    var subject: String
    /// `transaction`, `forwarding_confirmation`, `statement_link`, `other`,
    /// `unknown`. A raw string rather than an enum: a backend that learns a
    /// new kind must not make an older phone fail to decode the whole list,
    /// and an unrecognised value is displayable as «лист» without ceremony.
    var kind: String
    /// **The single most useful thing this list can say.** A letter that
    /// arrived and was not understood looks exactly like a letter that never
    /// arrived — the count simply fails to move — and those two want
    /// completely different actions.
    var parseFailed: Bool
}

struct PrivatEmailRecentLetters: Codable, Hashable {
    var letters: [PrivatEmailRecentLetter]
}

struct PrivatEmailPending: Codable, Hashable {
    var confirmations: [PrivatEmailConfirmation]
    var parseFailures: Int
}

struct PrivatEmailStatus: Codable, Hashable {
    var email: String
    var lastLetterAt: Date?
    var transactionsTotal: Int
}

enum PrivatEmailError: Error, Equatable {
    /// 401 — the secret is wrong or the account was deleted. The only fix
    /// is re-registering, so sync stops until the user acts (issue #91's UI).
    case unauthorized
    /// 429 — /register is limited to 5/hour/IP.
    case rateLimited
    case offline(String)
    case server(Int, String)
    case malformed(String)
}

/// One decoder for every email-backend payload. `occurred_at` is always
/// whole-second UTC, but `received_at`/`last_letter_at` come from Python's
/// isoformat() and keep microseconds — so try both shapes, never only one.
enum PrivatEmailDecoding {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// For the one thing the phone SENDS with a date in it — board #186's
    /// receipt question. `plain` above is the reader's; this is the writer's,
    /// and it is separate only because the reader has to accept two shapes
    /// while a writer must pick exactly one.
    static let iso8601 = ISO8601DateFormatter()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = plain.date(from: s) ?? fractional.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath,
                    debugDescription: "unrecognised date: \(s)"))
            }
            return date
        }
        return d
    }()
}

/// The seam. `PrivatEmailClient` in Release; `PrivatEmailStub` under
/// `-stubPrivatEmail`.
/// Board #97 — one statement waiting on the server, without its bytes.
///
/// The listing is deliberately separate from the download: a person's whole
/// financial history is a megabyte-scale file, and the screen that asks
/// "is there anything to import?" must not pull one down to find out.
struct PrivatEmailStatement: Codable, Hashable, Identifiable {
    let id: Int
    let filename: String
    let sizeBytes: Int
    let receivedAt: Date
}

struct PrivatEmailStatements: Codable, Hashable {
    let statements: [PrivatEmailStatement]
}

/// Board #145 — PrivatBank emails a download LINK, not a file — and board
/// #171, which lets the person ask the server to follow it.
///
/// This carries a URL and not bytes, and **nothing follows it on its own**:
/// no fetch on arrival, no sweep. #171 re-measured #145's three reasons and
/// found two of them already solved by #145 itself — the SES wrapper is
/// unwrapped at parse time, and «Контакти» is excluded by anchor text before
/// anything is stored. The third was real: the stored URL is a redirector,
/// and `app/statement_fetch.py` walks the chain by hand, checking every hop.
///
/// So the person still sees where the link goes and still decides. What
/// changed is that saying yes no longer means leaving the app.
struct PrivatEmailStatementLink: Codable, Hashable, Identifiable {
    let id: Int
    let url: String
    let receivedAt: Date

    /// What to show the person so they can see where they are going. The
    /// backend has already unwrapped the tracker and checked the host, so this
    /// is PrivatBank's own — but a link nobody can read is a link nobody can
    /// judge, and the host is the readable part.
    var host: String { URL(string: url)?.host() ?? url }
}

struct PrivatEmailStatementLinks: Codable, Hashable {
    let links: [PrivatEmailStatementLink]
}

protocol PrivatEmailAPI {
    func register() async throws -> PrivatEmailRegistration
    func transactions(credentials: PrivatEmailCredentials,
                      since: Int, limit: Int) async throws -> PrivatEmailPage
    func pendingLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailPending
    func status(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatus
    func deleteAccount(credentials: PrivatEmailCredentials) async throws
    /// Board #97. Three calls, because they cost three different things:
    /// listing is cheap and answers "is there anything?", fetching moves the
    /// whole file, and consuming is what stops it being offered again.
    func statements(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatements
    func statementBytes(credentials: PrivatEmailCredentials, id: Int) async throws -> Data
    func consumeStatement(credentials: PrivatEmailCredentials, id: Int) async throws
    /// Board #145. Two calls and no third: there is no `linkBytes`, because
    /// nothing on this side ever fetches what the link points at.
    func statementLinks(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatementLinks
    func consumeStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws
    /// Board #171. Ask the server to follow a link it already holds and keep
    /// what comes back. Answers with the same shape `statements` lists, so
    /// the result imports through `importEmailedStatement` with no second
    /// type and no re-listing.
    func downloadStatementLink(credentials: PrivatEmailCredentials,
                               id: Int) async throws -> PrivatEmailStatement
    /// Board #175. The last few letters, capped by the SERVER — a window, not
    /// a mailbox, and the phone cannot ask for more.
    func recentLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailRecentLetters
    /// Board #186. Ask the server to chase a fiscal receipt while this phone
    /// is asleep. Idempotent by (register, document) on the server, because
    /// re-asking is the normal case: a failed POST is retried and everything
    /// still pending is re-queued on relaunch.
    func queueReceipt(credentials: PrivatEmailCredentials, check: FiscalCheck) async throws
    /// Every answer waiting for this phone, blob and all — one round trip for
    /// all of them, because a second per receipt would be the latency board
    /// #186 exists to remove, added back.
    func readyReceipts(credentials: PrivatEmailCredentials) async throws -> [PrivatEmailReceipt]
    /// Collected. Stops it being offered and lets the server forget it within
    /// the hour — the contents of somebody's shopping do not sit there.
    func consumeReceipt(credentials: PrivatEmailCredentials, id: Int) async throws
}

/// One fetched fiscal receipt as the server hands it over. Board #186.
///
/// `checkXml` is the base64 the tax service returned, **unparsed by the
/// server** — that is the whole privacy decision on that card, and it means
/// the phone stays the only thing in the system that ever reads a receipt's
/// contents. `CheckXML.parse` takes it exactly as `TaxCabinetClient` would.
struct PrivatEmailReceipt: Codable, Hashable, Identifiable {
    var id: Int
    var registerNumber: String
    var documentNumber: String
    var checkXml: String
}
