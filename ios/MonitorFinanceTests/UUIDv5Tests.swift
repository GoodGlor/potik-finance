import XCTest
@testable import MonitorFinance

final class UUIDv5Tests: XCTestCase {

    /// The whole point: Swift must agree with Python's `uuid.uuid5`, for names
    /// that include Cyrillic, an empty string and a long one.
    func testEveryGeneratedCaseMatchesPython() {
        let namespace = UUID(uuidString: UUIDv5Fixture.namespace)!
        XCTAssertFalse(UUIDv5Fixture.cases.isEmpty)
        for c in UUIDv5Fixture.cases {
            let made = UUIDv5.make(namespace: namespace, name: c.name)
            XCTAssertEqual(made.uuidString.lowercased(), c.uuid.lowercased(),
                           "name: \(c.name.prefix(40))")
        }
    }

    func testTheAppNamespaceIsTheOneTheSeedBuilderUses() {
        XCTAssertEqual(UUIDv5.appNamespace.uuidString.lowercased(),
                       "6f1c2a6e-5b7e-4d0c-9a1e-2b3c4d5e6f70")
    }

    func testVersionAndVariantBitsAreSet() {
        let u = UUIDv5.make(namespace: UUIDv5.appNamespace, name: "anything")
        let s = u.uuidString.lowercased()
        // 8-4-4-4-12: the 15th hex digit is the version nibble, the 20th the
        // variant. Asserted on the STRING so a wrong byte index is visible.
        let hex = s.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(hex[hex.index(hex.startIndex, offsetBy: 12)], "5")
        XCTAssertTrue("89ab".contains(hex[hex.index(hex.startIndex, offsetBy: 16)]))
    }

    func testItIsDeterministic() {
        let a = UUIDv5.make(namespace: UUIDv5.appNamespace, name: "monobank|abc")
        let b = UUIDv5.make(namespace: UUIDv5.appNamespace, name: "monobank|abc")
        XCTAssertEqual(a, b)
    }

    func testDifferentNamesDiffer() {
        XCTAssertNotEqual(UUIDv5.make(namespace: UUIDv5.appNamespace, name: "a"),
                          UUIDv5.make(namespace: UUIDv5.appNamespace, name: "b"))
    }
}
