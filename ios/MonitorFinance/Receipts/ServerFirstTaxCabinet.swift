import Foundation

/// Ask our own server first; fall back to asking the tax service directly.
/// Board #186.
///
/// **Owner:** «Are fiscal check requests sent from the phone? I think it's
/// better to use our server, and set a task there so that as soon as it
/// appears, everything is uploaded to the application.»
///
/// **A `TaxCabinetAPI`, not a change to `ReceiptFetcher`.** That actor is
/// three review findings deep in pacing, cancellation and re-entrancy
/// comments, and none of them is about *where* an answer comes from. Wrapping
/// the one-method protocol puts this change entirely outside the part that
/// was hard to get right — the queue, the backoff, the stand-down and the
/// commit-and-remove pairing are all untouched.
///
/// **The phone does not stop being able to ask.** `direct` is the existing
/// `TaxCabinetClient` and it runs whenever the server has no answer, is
/// unreachable, is an older build, or the person has no mail account at all.
/// Receipts worked with no server before this card and still do; this adds a
/// faster path rather than replacing the one that exists.
///
/// **What actually makes the difference is not this class.** The server only
/// has an answer waiting because `AppStore.scan` posted the question the
/// moment the QR was read — hours before, while the phone was asleep and iOS
/// was granting it no wakes at all. This is just the collection.
actor ServerFirstTaxCabinet: TaxCabinetAPI {

    private let direct: TaxCabinetAPI
    private let api: PrivatEmailAPI
    /// Read at call time rather than captured: the person can connect or
    /// disconnect the mailbox while the app is running, and a credential
    /// captured at construction would be the one they had at launch.
    private let credentials: @Sendable () async -> PrivatEmailCredentials?

    /// Answers already collected, keyed by the fiscal document's own identity.
    ///
    /// **This cache is what keeps the round trips to one.** `ReceiptFetcher`
    /// calls `check` once per receipt, so without it a queue of ten would
    /// fetch the whole ready list ten times.
    private var collected: [Key: ParsedCheck] = [:]

    /// When the ready list was last fetched, and the reason this is a clock
    /// rather than a `listed` flag.
    ///
    /// `ReceiptFetcher` is **one actor for the whole process**, so this
    /// wrapper outlives every drain. A once-ever flag would have listed on the
    /// first drain after launch and never again — every answer the server
    /// found afterwards would sit there uncollected until the app was
    /// relaunched, which is the exact failure this card set out to remove,
    /// reintroduced one layer up.
    private var listedAt: Date?

    /// Long enough to cover one drain, short enough that the next one
    /// re-lists. `ReceiptFetcher.pace` is 3 s and a background wake affords
    /// about ten receipts, so a drain is ~30 s; a minute covers it with room.
    /// The cost of being wrong in either direction is small — one extra
    /// request, or one receipt collected on the next drain instead of this
    /// one.
    static let listWindow: TimeInterval = 60

    struct Key: Hashable {
        var registerNumber: String
        var documentNumber: String
    }

    /// `now` is injected for the same reason it is everywhere else in this
    /// feature: `listWindow` is a boundary, and a boundary a test cannot walk
    /// without waiting in real time is one nobody tests.
    private let now: @Sendable () -> Date

    init(direct: TaxCabinetAPI,
         api: PrivatEmailAPI,
         credentials: @escaping @Sendable () async -> PrivatEmailCredentials?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.direct = direct
        self.api = api
        self.credentials = credentials
        self.now = now
    }

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        if let ready = await serverAnswer(for: check) { return ready }
        return try await direct.check(check)
    }

    /// The server's answer for this document, or nil for every reason there
    /// is — no mailbox, an old backend, a network failure, a blob that will
    /// not parse. **Never throws**, and that is the design: a fast path that
    /// can fail the whole fetch is not a fast path, it is a new way to lose a
    /// receipt. Every failure here falls through to the client that worked
    /// before this card existed.
    private func serverAnswer(for check: FiscalCheck) async -> ParsedCheck? {
        guard let credentials = await credentials() else { return nil }
        await listOnce(credentials)
        let key = Key(registerNumber: check.registerNumber,
                      documentNumber: check.documentNumber)
        return collected.removeValue(forKey: key)
    }

    private func listOnce(_ credentials: PrivatEmailCredentials) async {
        if let listedAt, now().timeIntervalSince(listedAt) < Self.listWindow { return }
        // Stamped BEFORE the request, not after: two receipts checked while
        // the first listing is still in flight would otherwise both see no
        // stamp and both list.
        listedAt = now()
        guard let ready = try? await api.readyReceipts(credentials: credentials) else { return }
        for row in ready {
            // Parsed HERE, on the phone, from the base64 the server never
            // looked inside. That is board #186's privacy decision arriving
            // at its other end.
            guard let parsed = try? CheckXML.parse(base64: row.checkXml) else {
                // A blob that will not parse is not a reason to keep it: the
                // direct client will re-ask and get a fresh one, and leaving
                // it on the server means holding somebody's shopping for
                // nothing. Consumed, then forgotten.
                try? await api.consumeReceipt(credentials: credentials, id: row.id)
                continue
            }
            collected[Key(registerNumber: row.registerNumber,
                          documentNumber: row.documentNumber)] = parsed
            // Consumed as soon as it is held, not after it lands: the contents
            // of a purchase should stop existing on the server at the first
            // moment they safely can, and if this phone drops it before
            // landing, the direct client asks again — the tax service still
            // has it, and always will.
            try? await api.consumeReceipt(credentials: credentials, id: row.id)
        }
    }
}
