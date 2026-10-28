#if DEBUG
import Foundation

/// An email backend that answers instantly and never touches the network.
/// Every merchant here is INVENTED — the privacy guard scans this target.
struct PrivatEmailStub: PrivatEmailAPI {
    var mode: Launch.EmailStubMode

    static let address = "u-stub@in.example.test"
    static let credentials = PrivatEmailCredentials(userId: "stub-email-user",
                                                   secret: "stub-email-secret")

    /// Four UAH rows and one USD (the mapper must skip it). Ids are the
    /// cursor: a call with `since >= 5` gets an empty page, so a sync run
    /// terminates and a re-run merges instead of duplicating.
    static let rows: [PrivatEmailTransaction] = [
        .init(id: 1, occurredAt: Date(timeIntervalSince1970: 1_787_900_000),
              amountMinor: -12_550, currency: "UAH", cardSuffix: "5*99",
              merchantRaw: "Тест-Маркет Вигадана", balanceAfterMinor: 903_450),
        .init(id: 2, occurredAt: Date(timeIntervalSince1970: 1_787_903_600),
              amountMinor: -4_800, currency: "UAH", cardSuffix: "5*99",
              merchantRaw: "Кавʼярня Прикладова", balanceAfterMinor: 898_650),
        .init(id: 3, occurredAt: Date(timeIntervalSince1970: 1_787_907_200),
              amountMinor: 250_000, currency: "UAH", cardSuffix: "5*99",
              merchantRaw: "Зарахування зарплати", balanceAfterMinor: 1_148_650),
        .init(id: 4, occurredAt: Date(timeIntervalSince1970: 1_787_910_800),
              amountMinor: -30_000, currency: "UAH", cardSuffix: "4*11",
              merchantRaw: "Переказ на свою картку", balanceAfterMinor: 1_118_650),
        .init(id: 5, occurredAt: Date(timeIntervalSince1970: 1_787_914_400),
              amountMinor: -900, currency: "USD", cardSuffix: "5*99",
              merchantRaw: "Схід-Сервіс Тест", balanceAfterMinor: nil),
    ]

    private func failIfAsked() throws {
        switch mode {
        case .ok: break
        case .fail401: throw PrivatEmailError.unauthorized
        case .offline: throw PrivatEmailError.offline("stub offline")
        }
    }

    func register() async throws -> PrivatEmailRegistration {
        try failIfAsked()
        return .init(userId: Self.credentials.userId,
                     secret: Self.credentials.secret, email: Self.address)
    }

    func transactions(credentials: PrivatEmailCredentials,
                      since: Int, limit: Int) async throws -> PrivatEmailPage {
        try failIfAsked()
        let rows = Self.rows.filter { $0.id > since }.prefix(limit)
        return .init(transactions: Array(rows),
                     nextCursor: rows.last?.id ?? since)
    }

    func pendingLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailPending {
        try failIfAsked()
        return .init(confirmations: [
            .init(id: 1, receivedAt: Date(timeIntervalSince1970: 1_787_899_000),
                  from: "forwarding-noreply@example.test",
                  subject: "Код підтвердження пересилання (вигаданий)",
                  body: "Код: 0000000"),
        ], parseFailures: 0)
    }

    func status(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatus {
        try failIfAsked()
        return .init(email: Self.address,
                     lastLetterAt: Date(timeIntervalSince1970: 1_787_914_400),
                     transactionsTotal: Self.rows.count)
    }

    func deleteAccount(credentials: PrivatEmailCredentials) async throws {
        try failIfAsked()
        Self.statementState.reset()
    }

    // MARK: - Board #97, an emailed statement

    /// **The same bytes `-stubPrivatStatement` feeds past the file picker.**
    /// One invented statement in the repo and no second copy to drift — and
    /// because they are a real xlsx, a test that follows this through
    /// `importPrivatStatement` exercises the actual parser rather than a
    /// stand-in for it.
    static var sampleStatement: Data { PrivatStatementStub.sampleData }

    static let statementId = 1
    static let statementFilename = "vypyska-pryklad.xlsx"
    /// Board #187's second waiting statement, so the state the card is about
    /// — TWO of them, indistinguishable — can be reached and looked at. A
    /// different filename, size and arrival, because those three are exactly
    /// what the fix shows. Invented, like every fixture here.
    static let secondStatementId = 2
    static let secondStatementFilename = "vypyska-pryklad-2.xlsx"

    /// The one piece of mutable state a stub needs: whether the phone has
    /// already taken the statement. Without it "list, import, list again"
    /// cannot be told apart from "list, list", and the second listing is the
    /// assertion that matters — an imported statement must stop being offered
    /// or the same history arrives twice.
    ///
    /// A reference type because `PrivatEmailAPI`'s methods are non-mutating
    /// and the stub is a struct copied into the store.
    final class StatementState: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false
        var isConsumed: Bool { lock.withLock { consumed } }
        func consume() { lock.withLock { consumed = true } }
        func reset() { lock.withLock { consumed = false } }
    }

    static let statementState = StatementState()

    func statements(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatements {
        try failIfAsked()
        // A backend that predates board #97 — the 404 a phone meets when it
        // has updated ahead of its server.
        if Launch.stubNoStatementRoute { throw PrivatEmailError.server(404, "not found") }
        guard Launch.stubEmailStatement, !Self.statementState.isConsumed else {
            return .init(statements: [])
        }
        let first = PrivatEmailStatement(
            id: Self.statementId, filename: Self.statementFilename,
            sizeBytes: Self.sampleStatement.count,
            receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
        guard Launch.stubTwoStatements else { return .init(statements: [first]) }
        // Board #187. One statement is the state that HIDES this bug: with a
        // single button there is nothing to tell apart, and the screen looks
        // fine. Two is the state the owner met.
        return .init(statements: [
            first,
            .init(id: Self.secondStatementId, filename: Self.secondStatementFilename,
                  sizeBytes: Self.sampleStatement.count + 4_096,
                  receivedAt: Date(timeIntervalSince1970: 1_787_630_000)),
        ])
    }

    func statementBytes(credentials: PrivatEmailCredentials, id: Int) async throws -> Data {
        try failIfAsked()
        guard id == Self.statementId || id == Self.secondStatementId else {
            throw PrivatEmailError.server(404, "no such statement")
        }
        return Self.sampleStatement
    }

    func consumeStatement(credentials: PrivatEmailCredentials, id: Int) async throws {
        try failIfAsked()
        Self.statementState.consume()
    }

    // MARK: - Board #145, a statement that arrived as a link

    static let statementLinkId = 8_145
    /// An invented host on an invented domain. It must NOT be a privatbank.ua
    /// URL: the backend is what validates the host, and a stub that looked
    /// real would invite somebody to test the allowlist from this side, where
    /// it does not live.
    static let statementLinkURL = "https://example.test/statement/stub-link"
    static let statementLinkState = StatementState()

    func statementLinks(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatementLinks {
        try failIfAsked()
        if Launch.stubNoStatementRoute { throw PrivatEmailError.server(404, "not found") }
        guard Launch.stubStatementLink, !Self.statementLinkState.isConsumed else {
            return .init(links: [])
        }
        return .init(links: [
            .init(id: Self.statementLinkId, url: Self.statementLinkURL,
                  receivedAt: Date(timeIntervalSince1970: 1_787_890_000)),
        ])
    }

    func consumeStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws {
        try failIfAsked()
        Self.statementLinkState.consume()
    }

    // MARK: - Board #175, the last few letters

    /// Three invented letters covering the three states worth telling apart:
    /// one that became a transaction, one the app could not read, and one that
    /// is not a bank letter at all. **Every value here is made up** — real
    /// subjects are the owner's data and this repository is public.
    ///
    /// The middle one is the reason the feature exists: today it is invisible,
    /// because a letter that arrived and was not understood shows up as a
    /// count that simply did not move.
    func recentLetters(credentials: PrivatEmailCredentials) async throws -> PrivatEmailRecentLetters {
        try failIfAsked()
        if Launch.stubNoStatementRoute { throw PrivatEmailError.server(404, "not found") }
        guard Launch.stubRecentLetters else { return .init(letters: []) }
        return .init(letters: [
            .init(id: 3, receivedAt: Date(timeIntervalSince1970: 1_787_914_400),
                  from: "ПриватБанк <info@pb.ua>",
                  subject: "Операція за карткою (вигаданий)",
                  kind: "transaction", parseFailed: false),
            .init(id: 2, receivedAt: Date(timeIntervalSince1970: 1_787_910_800),
                  from: "ПриватБанк <info@pb.ua>",
                  subject: "Лист, який застосунок не зрозумів (вигаданий)",
                  kind: "transaction", parseFailed: true),
            .init(id: 1, receivedAt: Date(timeIntervalSince1970: 1_787_907_200),
                  from: "Розсилка <news@example.test>",
                  subject: "Не банківський лист (вигаданий)",
                  kind: "other", parseFailed: false),
        ])
    }

    // MARK: - Board #171, the server follows the link on the person's say-so

    /// Answers with the SAME statement `statements()` would offer, because the
    /// real route does: what comes back from a followed link is an ordinary
    /// attachment, so the phone's existing import path takes it from there.
    ///
    /// It consumes the LINK and un-consumes the statement, which is the state
    /// the real backend leaves: the link has been acted on and stops being
    /// offered; a file is now waiting that was not waiting before.
    func downloadStatementLink(credentials: PrivatEmailCredentials,
                               id: Int) async throws -> PrivatEmailStatement {
        try failIfAsked()
        guard id == Self.statementLinkId else {
            throw PrivatEmailError.server(404, "no such statement link")
        }
        Self.statementLinkState.consume()
        return .init(id: Self.statementId, filename: Self.statementFilename,
                     sizeBytes: Self.sampleStatement.count,
                     receivedAt: Date(timeIntervalSince1970: 1_787_890_000))
    }

    // MARK: - Board #186, receipts the server chases

    /// Accepted and forgotten. The stub has no scheduler, so nothing it is
    /// asked to chase ever becomes an answer — which is deliberate: it keeps
    /// every existing receipt test on the DIRECT path, exactly as it was
    /// before this card, so a UI suite asserting fetched goods is asserting
    /// the same thing it always did.
    func queueReceipt(credentials: PrivatEmailCredentials, check: FiscalCheck) async throws {
        try failIfAsked()
    }

    /// Always empty, for the reason above. `ServerFirstTaxCabinet` then falls
    /// straight through to `TaxCabinetStub`.
    func readyReceipts(credentials: PrivatEmailCredentials) async throws -> [PrivatEmailReceipt] {
        try failIfAsked()
        return []
    }

    func consumeReceipt(credentials: PrivatEmailCredentials, id: Int) async throws {
        try failIfAsked()
    }
}
#endif
