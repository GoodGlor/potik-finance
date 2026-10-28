#if DEBUG
import Foundation

/// A tax cabinet that answers instantly and never touches the network.
///
/// Every string here is INVENTED. The privacy guard in `tests/test_ios_seed.py`
/// scans this target; a real seller name would fail it, and would also be
/// wrong — a fixture that quotes reality is a leak with a plausible excuse.
struct TaxCabinetStub: TaxCabinetAPI {
    var mode: CheckStubMode

    func check(_ check: FiscalCheck) async throws -> ParsedCheck {
        switch mode {
        case .ok: return Self.ok(for: check)
        case .notPublished: throw TaxCabinetError.notPublished
        case .offline: throw TaxCabinetError.offline("stub")
        case .throttled: throw TaxCabinetError.throttled
        }
    }

    /// Two invented lines whose `netSum` totals `check.fiscalSum` exactly —
    /// split so the split itself needs no remainder handling — with the
    /// first carrying a non-zero discount, so the stub exercises the same
    /// gross/discount/net arithmetic a real receipt does. `mac` is echoed
    /// back so Task 5's verification has something to agree with.
    private static func ok(for check: FiscalCheck) -> ParsedCheck {
        let total = check.fiscalSum
        let firstNet = total - total / 3
        let secondNet = total - firstNet
        let discount = min(50, firstNet)
        let firstGross = firstNet + discount

        let lines = [
            ParsedLine(ordinal: 1, name: "Тестовий товар А", qtyMilli: 1_000,
                      grossSum: firstGross, discount: discount, netSum: firstNet,
                      netUnitPrice: firstNet),
            ParsedLine(ordinal: 2, name: "Тестовий товар Б", qtyMilli: 1_000,
                      grossSum: secondNet, discount: 0, netSum: secondNet,
                      netUnitPrice: secondNet),
        ]
        return ParsedCheck(registerModel: "1", fiscalTotal: total,
                           fiscalTime: check.fiscalTime, mac: check.mac, lines: lines)
    }
}
#endif
