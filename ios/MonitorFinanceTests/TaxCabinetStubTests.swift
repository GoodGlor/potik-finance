import XCTest
@testable import MonitorFinance

final class TaxCabinetStubTests: XCTestCase {

    private let check = FiscalCheck(registerNumber: "3000000001", documentNumber: "1000000001",
                                    fiscalTime: Date(timeIntervalSince1970: 1_800_000_000),
                                    fiscalSum: 100_00, mac: nil)

    func testTheStubAnswersWithLinesThatTotalTheCheck() async throws {
        let parsed = try await TaxCabinetStub(mode: .ok).check(check)
        XCTAssertEqual(parsed.lines.reduce(0) { $0 + $1.netSum }, parsed.fiscalTotal)
        XCTAssertFalse(parsed.lines.isEmpty)
    }

    func testEachFailureModeThrowsItsOwnError() async {
        for (mode, expected) in [(CheckStubMode.notPublished, TaxCabinetError.notPublished),
                                 (.offline, .offline("stub")),
                                 (.throttled, .throttled)] {
            do {
                _ = try await TaxCabinetStub(mode: mode).check(check)
                XCTFail("\(mode) must throw")
            } catch let error as TaxCabinetError {
                if case .offline = expected {
                    if case .offline = error {} else { XCTFail("\(mode) threw \(error)") }
                } else {
                    XCTAssertEqual(error, expected, "\(mode)")
                }
            } catch {
                XCTFail("\(mode) threw \(error)")
            }
        }
    }

    /// Every string in the stub is invented; the privacy guard in pytest scans
    /// this target. This is the Swift-side reminder of the same rule.
    func testTheStubNamesNothingReal() async throws {
        let parsed = try await TaxCabinetStub(mode: .ok).check(check)
        XCTAssertTrue(parsed.lines.allSatisfy { !$0.name.isEmpty })
    }
}
