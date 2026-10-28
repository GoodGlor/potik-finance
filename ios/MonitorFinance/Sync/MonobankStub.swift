#if DEBUG
import Foundation

/// A bank that answers instantly and never touches the network.
///
/// Every string here is INVENTED. The privacy guard in `tests/test_ios_seed.py`
/// scans this target; a real merchant, name or card number would fail it, and
/// would also be wrong — a fixture that quotes reality is a leak with a
/// plausible excuse.
struct MonobankStub: MonobankAPI {
    var mode: Launch.StubMode

    /// Two UAH cards. Both masked PANs are invented and are not valid card
    /// numbers.
    static let accounts: [MonobankAccount] = [
        MonobankAccount(id: "stub-acc-1", type: "black", currencyCode: 980,
                        balance: 1_234_500, creditLimit: 0,
                        maskedPan: ["000000******1111"]),
        MonobankAccount(id: "stub-acc-2", type: "white", currencyCode: 980,
                        balance: 98_700, creditLimit: 0,
                        maskedPan: ["000000******2222"]),
    ]

    func clientInfo(token: String) async throws -> MonobankClientInfo {
        try failIfAsked()
        return MonobankClientInfo(clientId: "stub-client",
                                  name: "Тестовий Користувач",
                                  accounts: Self.accounts)
    }

    func statement(token: String, accountId: String,
                   from: Date, to: Date) async throws -> [MonobankStatementItem] {
        try failIfAsked()
        // `-noDemoData` is the one launch configuration that means "a
        // genuinely empty app, nothing has arrived yet" (EmptyStateTests).
        // Answering instantly there — as this stub does for every other
        // scenario, by design — would make the very first commit land
        // faster than any UI query can observe it: `SyncEngine.pace()`
        // lets the first request of a run go immediately, so an instant
        // reply here means `isSyncing` and `store.transactions.isEmpty`
        // are both true for well under a millisecond, a window no XCUITest
        // poll can catch. A short, real delay — never in any other launch
        // configuration — gives the loading state something to observe.
        //
        // Its LENGTH is `-stubStatementDelay`, defaulting to the 3.5 s this
        // used to hardcode. `EmptyStateTests` passes 600: those tests only
        // need the sync in flight, and a fixed 3.5 s made them race a wall
        // clock they could lose on a loaded machine. `Task.sleep` is
        // cancellation-aware, so a long delay still tears down cleanly.
        if Launch.noDemoData { try await Task.sleep(for: .seconds(Launch.stubStatementDelay)) }
        guard to >= from else { throw MonobankError.windowInvalid }
        guard to.timeIntervalSince(from) <= 31 * 86_400 else { throw MonobankError.windowTooLong }
        // Deterministic: six rows spread evenly across the window, ids seeded
        // by account so two accounts never return the same row.
        let span = to.timeIntervalSince(from)
        return (0..<6).map { n in
            let at = from.addingTimeInterval(span * Double(n) / 6.0)
            let seconds = Int(at.timeIntervalSince1970)
            return MonobankStatementItem(
                id: "\(accountId)-\(seconds)",
                time: seconds,
                description: n == 5 ? "Тестове надходження" : "Тестовий продавець \(n % 3)",
                mcc: 5411,
                // Every stub row is a domestic UAH purchase, so the network's
                // code and the bank's agree. The divergent pair the field
                // exists for lives in the corpus fixture, not here.
                originalMcc: 5411,
                amount: n == 5 ? 2_500_00 : -(100_00 + n * 37_00),
                operationAmount: nil, currencyCode: 980,
                commissionRate: 0, cashbackAmount: 0, balance: nil,
                hold: n == 0, monoReceiptId: nil, counterName: nil)
        }
    }

    private func failIfAsked() throws {
        switch mode {
        case .ok: return
        case .fail403: throw MonobankError.invalidToken
        case .fail429: throw MonobankError.rateLimited
        case .offline: throw MonobankError.offline("stubbed")
        }
    }
}
#endif
