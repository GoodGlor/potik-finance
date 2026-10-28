import XCTest
@testable import MonitorFinance

final class SplitMathTests: XCTestCase {

    /// Deliberately unrelated to any product group name below, so an
    /// assertion that a split's category `!=` this one is a real check, not
    /// a coincidence of the fixture.
    private let groups = [
        ProductGroup(name: "Молочні продукти", keywords: ["молоко", "сир"]),
        ProductGroup(name: "Пальне та автотовари", keywords: ["бензин"]),
        ProductGroup(name: ProductGuess.other, keywords: []),
    ]

    private func tx(amount: Int, category: String = "Автомобіль") -> Transaction {
        Transaction(id: UUID(), date: Date(), kind: .expense, category: category,
                    merchant: "Крамниця", amount: amount, cardSuffix: "*0000",
                    bankId: "monobank", receiptId: nil, splits: [], resolution: .rule,
                    suggestions: [])
    }

    /// `fiscalSum` is set to an obviously wrong value in every test unless a
    /// test is specifically about it, so an implementation that reads
    /// `receipt.fiscalSum` instead of summing the items would be caught
    /// rather than accidentally pass.
    private func receipt(items: [Receipt.Item], fiscalSum: Int = -1) -> Receipt {
        Receipt(id: UUID(), scannedAt: Date(), registerNumber: "3000000001",
                documentNumber: "1000000001", fiscalTime: Date(), fiscalSum: fiscalSum,
                sellerName: "Крамниця", items: items)
    }

    private func item(_ name: String, sum: Int, category: String? = nil) -> Receipt.Item {
        Receipt.Item(id: UUID(), name: name, qty: 1, price: sum, sum: sum, category: category)
    }

    // MARK: - 1: no category on the item takes the guessed PRODUCT GROUP,
    // never the transaction's SPENDING category — the namespace boundary.

    func testAnItemWithNoCategoryTakesTheGuessedGroupNotTheSpendingCategory() {
        let t = tx(amount: -450_00, category: "Автомобіль")
        let r = receipt(items: [item("Бензин А-95", sum: 450_00)])

        guard case .ok(let splits) = SplitMath.build(t, r, groups: groups) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].category, "Пальне та автотовари")
        // The load-bearing half: a mutation that reaches for tx.category
        // instead of the guess would still pass the line above by accident
        // if the two ever collided. They must not.
        XCTAssertNotEqual(splits[0].category, t.category)
    }

    // MARK: - 2: an item's own category overrides the guess.

    func testAnItemWithACategoryKeepsItOverridingTheGuess() {
        let t = tx(amount: -450_00)
        // "Бензин А-95" would guess "Пальне та автотовари" by keyword; the
        // receipt's own category must win instead.
        let r = receipt(items: [item("Бензин А-95", sum: 450_00, category: "Акційні товари")])

        guard case .ok(let splits) = SplitMath.build(t, r, groups: groups) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].category, "Акційні товари")
    }

    // MARK: - 3: splits always sum to abs(tx.amount).

    func testSplitsSumToTheAbsoluteChargedAmount() {
        let t = tx(amount: -730_00)
        let r = receipt(items: [
            item("Молоко", sum: 45_00),
            item("Сир", sum: 180_00),
        ])

        guard case .ok(let splits) = SplitMath.build(t, r, groups: groups) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(splits.reduce(0) { $0 + $1.amount }, abs(t.amount))
    }

    // MARK: - 4: item sum under the charge grows exactly one remainder split.

    func testAnUnderItemisedReceiptGrowsARemainderSplitInInshe() {
        let t = tx(amount: -500_00)
        let r = receipt(items: [item("Молоко", sum: 300_00)])

        guard case .ok(let splits) = SplitMath.build(t, r, groups: groups) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(splits.count, 2)
        let remainder = splits.last!
        XCTAssertEqual(remainder.name, SplitMath.remainderName)
        XCTAssertEqual(remainder.category, ProductGuess.other)
        XCTAssertEqual(remainder.amount, 200_00)
    }

    // MARK: - 5: an exact receipt grows no remainder line at all.

    func testAnExactlyItemisedReceiptGrowsNoRemainderLine() {
        let t = tx(amount: -300_00)
        let r = receipt(items: [item("Молоко", sum: 300_00)])

        guard case .ok(let splits) = SplitMath.build(t, r, groups: groups) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(splits.count, 1)
        XCTAssertFalse(splits.contains { $0.name == SplitMath.remainderName })
    }

    // MARK: - 6: itemised sum over the charge refuses; one kopeck less succeeds.

    func testAnOverItemisedReceiptRefusesButOneKopeckLessSucceeds() {
        let t = tx(amount: -300_00)

        let over = receipt(items: [item("Молоко", sum: 300_01)])
        guard case .receiptExceedsPurchase(let by) = SplitMath.build(t, over, groups: groups) else {
            return XCTFail("expected .receiptExceedsPurchase")
        }
        XCTAssertEqual(by, 1)

        // One kopeck UNDER the charge, not an exact match — an implementation
        // that only accepts `itemised == charge` (refusing any mismatch,
        // under or over) would wrongly refuse this too. Without this half, a
        // build that always refuses would still pass the assertion above.
        let oneKopeckLess = receipt(items: [item("Молоко", sum: 299_99)])
        guard case .ok = SplitMath.build(t, oneKopeckLess, groups: groups) else {
            return XCTFail("expected .ok one kopeck under the refused sum")
        }
    }

    // MARK: - 7: an item-less receipt yields no splits — nothing to detail.

    func testAnItemLessReceiptReturnsOkEmpty() {
        let t = tx(amount: -300_00)
        let r = receipt(items: [], fiscalSum: 300_00)

        XCTAssertEqual(SplitMath.build(t, r, groups: groups), .ok([]))
    }
}
