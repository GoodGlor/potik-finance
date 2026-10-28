import XCTest
@testable import MonitorFinance

final class MonobankStubTests: XCTestCase {

    // MARK: the argument parser

    func testAbsentFlagMeansNoStub() {
        XCTAssertNil(Launch.stubMode(from: ["-resetState", "-noBiometrics"]))
    }

    func testBareFlagMeansOk() {
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank"]), .ok)
    }

    func testFlagWithModeIsRead() {
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank", "fail403"]), .fail403)
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank", "fail429"]), .fail429)
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank", "offline"]), .offline)
    }

    /// The next argument is the NEXT FLAG, not a mode. Reading it as a mode
    /// would silently disable the stub for every test that writes the flags in
    /// this order — and `-stubMonobank -resetState` is the order a person
    /// naturally writes.
    func testAnotherFlagAfterItStillMeansOk() {
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank", "-resetState"]), .ok)
    }

    func testAnUnknownModeMeansOkRatherThanNoStub() {
        XCTAssertEqual(Launch.stubMode(from: ["-stubMonobank", "banana"]), .ok)
    }

    // MARK: the stub itself

    func testOkModeReturnsClientInfoWithAccounts() async throws {
        let info = try await MonobankStub(mode: .ok).clientInfo(token: "t1")
        XCTAssertFalse(info.clientId.isEmpty)
        XCTAssertEqual(info.accounts.count, 2)
        XCTAssertEqual(info.accounts.map(\.currencyCode), [980, 980])
    }

    func testFail403Throws() async {
        await XCTAssertThrowsErrorAsync(
            try await MonobankStub(mode: .fail403).clientInfo(token: "t1")
        ) { XCTAssertEqual($0 as? MonobankError, .invalidToken) }
    }

    func testFail429Throws() async {
        await XCTAssertThrowsErrorAsync(
            try await MonobankStub(mode: .fail429).clientInfo(token: "t1")
        ) { XCTAssertEqual($0 as? MonobankError, .rateLimited) }
    }

    func testOfflineThrows() async {
        await XCTAssertThrowsErrorAsync(
            try await MonobankStub(mode: .offline).clientInfo(token: "t1")
        ) {
            guard case .offline = ($0 as? MonobankError) else {
                return XCTFail("expected .offline, got \($0)")
            }
        }
    }

    /// The statement is deterministic — a test that asserts a row's category
    /// must get the same row every run.
    func testStatementIsDeterministicAndInsideTheWindow() async throws {
        let stub = MonobankStub(mode: .ok)
        let to = Date(timeIntervalSince1970: 1_756_800_000)
        let from = to.addingTimeInterval(-31 * 86_400)
        let a = try await stub.statement(token: "t1", accountId: "acc-1", from: from, to: to)
        let b = try await stub.statement(token: "t1", accountId: "acc-1", from: from, to: to)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        for row in a {
            let at = Date(timeIntervalSince1970: TimeInterval(row.time))
            XCTAssertTrue(at >= from && at <= to, "row \(row.id) outside the window")
        }
    }

    /// Two accounts must not return the same rows, or nothing in the sync
    /// tests can tell a per-account bug from a working one.
    func testDifferentAccountsReturnDifferentRows() async throws {
        let stub = MonobankStub(mode: .ok)
        let to = Date(timeIntervalSince1970: 1_756_800_000)
        let from = to.addingTimeInterval(-31 * 86_400)
        let one = try await stub.statement(token: "t", accountId: "acc-1", from: from, to: to)
        let two = try await stub.statement(token: "t", accountId: "acc-2", from: from, to: to)
        XCTAssertTrue(Set(one.map(\.id)).isDisjoint(with: Set(two.map(\.id))))
    }

    // MARK: the email argument parser

    func testEmailStubModeParses() {
        XCTAssertNil(Launch.emailStubMode(from: ["-resetState"]))
        XCTAssertEqual(Launch.emailStubMode(from: ["-stubPrivatEmail"]), .ok)
        XCTAssertEqual(Launch.emailStubMode(from: ["-stubPrivatEmail", "fail401"]), .fail401)
        // A following flag is not a mode — same rule as -stubMonobank.
        XCTAssertEqual(Launch.emailStubMode(from: ["-stubPrivatEmail", "-resetState"]), .ok)
    }
}
