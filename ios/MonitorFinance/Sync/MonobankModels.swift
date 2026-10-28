import Foundation

/// The monobank personal API as the app sees it. Wire shapes only — no
/// behaviour — so the real client and the Debug stub can both conform without
/// either importing the other's concerns.
///
/// Every field the API is known to omit rather than null is optional. monobank
/// leaves keys out; it does not send nulls.
struct MonobankAccount: Codable, Hashable {
    var id: String
    var type: String?
    var currencyCode: Int
    var balance: Int
    var creditLimit: Int?
    var maskedPan: [String]?
}

struct MonobankClientInfo: Codable, Hashable {
    /// Identifies the PERSON, not the device. Never stored; only its SHA-256
    /// is kept, to notice a token belonging to somebody else.
    var clientId: String
    /// The owner's real name. Decoded because a decoder that ignores fields
    /// hides API changes — and then dropped. It never reaches storage.
    var name: String
    var accounts: [MonobankAccount]
}

struct MonobankStatementItem: Codable, Hashable {
    var id: String
    /// Unix seconds. An absolute instant — converted once, in the mapper.
    var time: Int
    var description: String
    var mcc: Int?
    /// The code the CARD NETWORK sent, before monobank rewrote it.
    ///
    /// When the two disagree the original is the one describing the real shop:
    /// the corpus carries `mcc 7829` (motion-picture distribution) against
    /// `originalMcc 4899` (cable/streaming) for one subscription. **15 of its
    /// 111 rows are recoded and three of those are in UAH** — 5499 → 5411 is
    /// «miscellaneous food» against a grocery — so this is not only the
    /// foreign-currency case, whatever the shape of the twelve EUR rows
    /// suggests. Decoded because a row synced without it can never be
    /// backfilled: the statement window is 31 days.
    var originalMcc: Int?
    /// Minor units, signed. ALWAYS in the account's own currency.
    var amount: Int
    var operationAmount: Int?
    /// Describes `operationAmount`, NOT `amount`. Reading it as the currency of
    /// `amount` is the most common monobank bug; `app/connectors/base.py`
    /// documents it at length and this comment is the Swift side of that.
    var currencyCode: Int?
    var commissionRate: Int?
    var cashbackAmount: Int?
    var balance: Int?
    var hold: Bool?
    /// monobank's OWN reference to a purchase. Deliberately not named
    /// `receiptId`: `Transaction.receiptId` is a local `UUID` pointing at a
    /// scanned fiscal receipt, and the mapper sits between the two. Decoded
    /// and dropped. The receipt-decoder stage checked whether it could stand
    /// in for a scan and it cannot: monobank publishes no endpoint that
    /// returns fiscal line items, so the QR on the paper receipt remains the
    /// only route to the goods.
    var monoReceiptId: String?
    /// A transfer counterparty's real name. Decoded and dropped — it becomes
    /// no part of `Transaction` and must never leave the phone.
    var counterName: String?

    enum CodingKeys: String, CodingKey {
        case id, time, description, mcc, originalMcc, amount, operationAmount, currencyCode
        case commissionRate, cashbackAmount, balance, hold, counterName
        case monoReceiptId = "receiptId"
    }
}

enum MonobankError: Error, Equatable {
    /// 403 — wrong, revoked, or for a different environment. The only fix is a
    /// new token, so the UI shows a persistent banner rather than a toast.
    case invalidToken
    /// 429 — asked too soon despite pacing.
    case rateLimited
    /// Asked for more than 31 days. A programmer error, surfaced as an error
    /// rather than a trap so a test can prove the guard exists.
    case windowTooLong
    /// `to` is before `from`.
    case windowInvalid
    case offline(String)
    case server(Int, String)
    case malformed(String)
}

/// The seam. `MonobankClient` in Release; `MonobankStub` under `-stubMonobank`.
protocol MonobankAPI {
    func clientInfo(token: String) async throws -> MonobankClientInfo
    func statement(token: String, accountId: String,
                   from: Date, to: Date) async throws -> [MonobankStatementItem]
}
