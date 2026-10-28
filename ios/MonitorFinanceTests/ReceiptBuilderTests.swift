import XCTest
@testable import MonitorFinance

final class ReceiptBuilderTests: XCTestCase {

    private let check = FiscalCheck(
        registerNumber: "9999999999", documentNumber: "777777",
        fiscalTime: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00+02:00")!,
        // The real control number, straight from the same fixture document
        // `CheckFixture.base64` decodes — never re-typed as its own literal,
        // so this file carries no independent copy of it.
        fiscalSum: 799_23, mac: CheckFixture.mac)

    func testAScanBecomesAReceiptWithEverythingTheQrCarriedAndNoGoods() {
        let now = Date()
        let r = ReceiptBuilder.shell(from: check, now: now)
        XCTAssertEqual(r.registerNumber, "9999999999")
        XCTAssertEqual(r.documentNumber, "777777")
        XCTAssertEqual(r.fiscalSum, 799_23)
        XCTAssertEqual(r.scannedAt, now)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertNil(r.itemsLandedAt, "no goods yet is not the same as no goods")
        XCTAssertTrue(r.isWaitingForItems)
        // D8: the name comes from the purchase it matches, never from the
        // vendor extension the document happens to carry.
        XCTAssertEqual(r.sellerName, "")
    }

    func testItemsCarryTheNetSumAndTheNetUnitPrice() throws {
        let parsed = try CheckXML.parse(base64: CheckFixture.base64)
        let items = ReceiptBuilder.items(from: parsed)
        let want = try XCTUnwrap(CheckFixture.lines.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sum, want.netSum)
        XCTAssertEqual(items[0].price, want.netUnitPrice)
        XCTAssertEqual(items[0].qty, Double(want.qtyMilli) / 1000, accuracy: 0.0001)
        // The PRODUCT GROUP is guessed lazily where it is rendered, never
        // written here — `Receipt.Item.category` stays nil until a human
        // confirms it.
        XCTAssertNil(items[0].category)
    }

    /// `Derived.fillUps` hands `item.price` straight to the fuel log as ₴/л,
    /// beside a total that is net. Storing the pump price there would print
    /// two numbers that cannot both be true.
    func testTheUnitPriceIsTheOneTheMoneyImplies() throws {
        let parsed = try CheckXML.parse(base64: CheckFixture.base64)
        let item = try XCTUnwrap(ReceiptBuilder.items(from: parsed).first)
        XCTAssertEqual(Int((Double(item.sum) / item.qty).rounded()), item.price)
    }

    func testEveryItemGetsItsOwnIdentity() throws {
        let parsed = try CheckXML.parse(base64: CheckFixture.base64)
        let first = ReceiptBuilder.items(from: parsed)
        let second = ReceiptBuilder.items(from: parsed)
        // `Derived.fillUps` uses `item.id` as a `ForEach` id. Two scans of the
        // same receipt sharing item ids renders wrong.
        XCTAssertNotEqual(first.first?.id, second.first?.id)
    }

    func testTheControlNumberIsComparedWhenBothSidesHaveOne() throws {
        let parsed = try CheckXML.parse(base64: CheckFixture.base64)
        XCTAssertTrue(ReceiptBuilder.macMatches(parsed, check))

        var other = check
        other.mac = "AAAA="
        XCTAssertFalse(ReceiptBuilder.macMatches(parsed, other))

        // A sample's synthesised URL has none, and that is not a mismatch.
        var none = check
        none.mac = nil
        XCTAssertTrue(ReceiptBuilder.macMatches(parsed, none))
    }

    func testAReceiptWrittenBeforeThisStageStillDecodes() throws {
        let old = """
        {"id":"\(UUID().uuidString)","scannedAt":"2026-08-01T10:00:00Z",\
        "registerNumber":"1","documentNumber":"2","fiscalTime":"2026-08-01T10:00:00Z",\
        "fiscalSum":100,"sellerName":"","items":[]}
        """
        let r = try SeedLoader.decoder.decode(Receipt.self, from: Data(old.utf8))
        XCTAssertNil(r.registerModel)
        XCTAssertNil(r.itemsLandedAt)
    }
}
