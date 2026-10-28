import XCTest
@testable import MonitorFinance

final class PinStoreTests: XCTestCase {
    private var keychain: Keychain!
    private var defaults: UserDefaults!
    private var suite: String!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        suite = "pin-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        keychain.wipe()
        // A per-test suite is only isolated, not temporary: without this each
        // run leaves another plist behind in the simulator's preferences.
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> PinStore {
        PinStore(keychain: keychain, defaults: defaults, now: { self.clock })
    }

    func testSetAndVerify() throws {
        let pin = store()
        XCTAssertFalse(pin.isSet)
        try pin.set("1234")
        XCTAssertTrue(pin.isSet)
        XCTAssertTrue(pin.verify("1234"))
        XCTAssertFalse(pin.verify("1235"))
    }

    func testDigitsAreNeverStored() throws {
        let pin = store()
        try pin.set("1234")
        let stored = keychain.getString("pin.hash") ?? ""
        XCTAssertFalse(stored.isEmpty)
        XCTAssertFalse(stored.contains("1234"))
        XCTAssertNotNil(keychain.get("pin.salt"))
    }

    func testSameDigitsHashDifferentlyPerInstall() throws {
        let a = store(); try a.set("1234")
        let hashA = keychain.getString("pin.hash")
        keychain.wipe()
        let b = store(); try b.set("1234")
        XCTAssertNotEqual(hashA, keychain.getString("pin.hash"))
    }

    func testFiveFailuresLockFor30sThenDouble() throws {
        let pin = store(); try pin.set("1234")
        for _ in 0..<4 { XCTAssertFalse(pin.verify("0000")) }
        XCTAssertNil(pin.lockedUntil)
        XCTAssertFalse(pin.verify("0000"))               // 5th
        XCTAssertEqual(pin.lockedUntil, clock.addingTimeInterval(30))
        XCTAssertFalse(pin.verify("1234"), "right PIN must not unlock during lockout")

        clock = clock.addingTimeInterval(31)
        XCTAssertNil(pin.lockedUntil)
        for _ in 0..<5 { _ = pin.verify("0000") }
        XCTAssertEqual(pin.lockedUntil, clock.addingTimeInterval(60))
    }

    func testSuccessResetsTheEscalation() throws {
        let pin = store(); try pin.set("1234")
        for _ in 0..<5 { _ = pin.verify("0000") }
        clock = clock.addingTimeInterval(31)
        XCTAssertTrue(pin.verify("1234"))
        XCTAssertEqual(pin.failedAttempts, 0)
        for _ in 0..<5 { _ = pin.verify("0000") }
        XCTAssertEqual(pin.lockedUntil, clock.addingTimeInterval(30), "round restarts at 30s after a success")
    }

    func testLockoutSurvivesANewInstance() throws {
        let pin = store(); try pin.set("1234")
        for _ in 0..<5 { _ = pin.verify("0000") }
        let again = store()
        XCTAssertEqual(again.lockedUntil, clock.addingTimeInterval(30))
    }

    func testClearRemovesEverything() throws {
        let pin = store(); try pin.set("1234")
        _ = pin.verify("0000")
        pin.clear()
        XCTAssertFalse(pin.isSet)
        XCTAssertEqual(pin.failedAttempts, 0)
        XCTAssertNil(pin.lockedUntil)
    }
}
