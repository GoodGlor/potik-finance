import Foundation

/// The tax service's public receipt-lookup endpoint as the app sees it. Wire
/// shapes only — no behaviour — so the real client (Task 6) and the Debug
/// stub can both conform without either importing the other's concerns.
///
/// The protocol returns `ParsedCheck` rather than raw XML: the stub then
/// answers with values instead of hand-written base64, which keeps it
/// readable and keeps XML parsing tested in exactly one place (Task 5).
struct ParsedLine: Equatable {
    var ordinal: Int
    var name: String
    var qtyMilli: Int
    var grossSum: Int
    var discount: Int
    var netSum: Int
    var netUnitPrice: Int
}

struct ParsedCheck: Equatable {
    /// The register's model and firmware (`NDv`), not a schema version — it
    /// reads as a device name string. Optional: at least one real receipt
    /// carries no `NDv` at all.
    var registerModel: String?
    var fiscalTotal: Int
    var fiscalTime: Date?
    var mac: String?
    var lines: [ParsedLine]
}

enum TaxCabinetError: Error, Equatable {
    /// A 200 carrying `error`, or one with no `checkXml`. **This is also what
    /// a wrong `sm`, `date`, `id` or `fn` returns** — the response cannot tell
    /// the two apart, so age decides: inside the retry window it means "not
    /// published yet"; past it, the receipt is given up on.
    case notPublished
    /// A `URLError` — no connectivity, DNS, timeout. Not the app's fault and
    /// not the document's; retried on the ordinary schedule.
    case offline(String)
    /// Not JSON, bad base64, XML that will not parse, or lines that out-total
    /// the receipt. A document this stage cannot trust.
    case malformed(String)
    /// A non-JSON body where JSON was promised — an HTML error page. The
    /// endpoint publishes no `RateLimit-*` and no `Retry-After`, so this is
    /// the only warning the app will ever get that it is asking too often,
    /// and it is treated as one.
    case throttled
}

/// The seam. `TaxCabinetClient` in Release (Task 6); `TaxCabinetStub` under
/// `-stubTaxCabinet`.
protocol TaxCabinetAPI {
    func check(_ check: FiscalCheck) async throws -> ParsedCheck
}
