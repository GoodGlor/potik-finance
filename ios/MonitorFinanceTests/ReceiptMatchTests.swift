import XCTest
@testable import MonitorFinance

final class ReceiptMatchTests: XCTestCase {

    private let fiscalTime = ISO8601DateFormatter().date(from: "2026-08-23T15:40:00+03:00")!

    private func receipt(sum: Int = 799_23) -> Receipt {
        Receipt(id: UUID(), scannedAt: fiscalTime, registerNumber: "1", documentNumber: "2",
                fiscalTime: fiscalTime, fiscalSum: sum, sellerName: "", items: [])
    }

    private func tx(_ amount: Int, _ offset: TimeInterval,
                    receiptId: UUID? = nil) -> Transaction {
        Transaction(id: UUID(), date: fiscalTime.addingTimeInterval(offset), kind: .expense,
                    category: "", merchant: "shop", amount: amount, cardSuffix: "", bankId: "",
                    receiptId: receiptId, splits: [], resolution: .pending, suggestions: [],
                    externalId: nil, hold: nil)
    }

    func testOneExpenseOfTheSameSumNearbyIsMatchedSilently() {
        let match = tx(-799_23, 120)
        XCTAssertEqual(ReceiptMatch.sole(for: receipt(), in: [match, tx(-50_00, 60)]), match.id)
    }

    /// One at a time, and asserted on `candidates` as well as `sole`: with both
    /// near-misses in the same list, a tolerance makes BOTH of them candidates
    /// and `sole` still returns nil — for the opposite of the intended reason.
    /// The test would keep passing with exactness gone, which is precisely the
    /// bug it exists to catch.
    func testASumThatDiffersByAKopeckIsNotAMatch() {
        for amount in [-799_22, -799_24] {
            let only = [tx(amount, 0)]
            XCTAssertTrue(ReceiptMatch.candidates(for: receipt(), in: only).isEmpty,
                          "\(amount) must not be a candidate for a 799.23 receipt")
            XCTAssertNil(ReceiptMatch.sole(for: receipt(), in: only), "\(amount)")
        }
    }

    func testIncomeAndAlreadyClaimedPurchasesAreNeverCandidates() {
        let income = tx(799_23, 0)
        let taken = tx(-799_23, 0, receiptId: UUID())
        XCTAssertTrue(ReceiptMatch.candidates(for: receipt(), in: [income, taken]).isEmpty)
    }

    func testTheWindowIsThreeHoursEitherSide() {
        let inside = tx(-799_23, ReceiptMatch.window - 60)
        let outside = tx(-799_23, ReceiptMatch.window + 60)
        XCTAssertEqual(ReceiptMatch.sole(for: receipt(), in: [inside]), inside.id)
        XCTAssertNil(ReceiptMatch.sole(for: receipt(), in: [outside]))
        let before = tx(-799_23, -(ReceiptMatch.window - 60))
        XCTAssertEqual(ReceiptMatch.sole(for: receipt(), in: [before]), before.id)
        // The backward direction, pinned against an UNBOUNDED comparison:
        // without `abs()`, every transaction earlier than the receipt matches,
        // however old, and a year-old purchase of the same amount silently
        // claims today's groceries. The in-window `before` fixture above stays
        // a candidate under that mutation, so only a far-past one catches it.
        let longBefore = tx(-799_23, -(ReceiptMatch.window + 86_400))
        XCTAssertTrue(ReceiptMatch.candidates(for: receipt(), in: [longBefore]).isEmpty,
                      "a purchase a day early must not be a candidate")
    }

    /// Two coffees of the same price in one afternoon. The app asks rather
    /// than picking, and offers the nearer one first.
    func testTwoEqualCandidatesAreReturnedNearestFirstAndNeitherIsChosen() {
        let far = tx(-799_23, 7000)
        let near = tx(-799_23, 300)
        XCTAssertNil(ReceiptMatch.sole(for: receipt(), in: [far, near]))
        XCTAssertEqual(ReceiptMatch.candidates(for: receipt(), in: [far, near]).map(\.id),
                       [near.id, far.id])
    }

    func testNothingAtAllIsAnOrdinaryAnswer() {
        XCTAssertNil(ReceiptMatch.sole(for: receipt(), in: []))
        XCTAssertTrue(ReceiptMatch.candidates(for: receipt(), in: []).isEmpty)
    }

    /// A hold may settle to a different amount later; while it reads equal it
    /// is as good a candidate as any, and `AppStore.mismatch` is what surfaces
    /// it afterwards if the bank moves the number.
    func testAHeldPurchaseIsAsMatchableAsASettledOne() {
        var held = tx(-799_23, 60)
        held.hold = true
        XCTAssertEqual(ReceiptMatch.sole(for: receipt(), in: [held]), held.id)
    }
}
