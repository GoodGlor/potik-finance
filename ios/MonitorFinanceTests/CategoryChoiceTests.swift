import XCTest
@testable import MonitorFinance

final class CategoryChoiceTests: XCTestCase {
    /// `notAnExpense` must not be expressible as a category, or a reserved
    /// string would leak into `Transaction.category` and be indistinguishable
    /// from a real one.
    func testTheTwoCasesAreDistinct() {
        XCTAssertNotEqual(CategoryChoice.category("Переказ"), .notAnExpense)
        XCTAssertEqual(CategoryChoice.category("Продукти"), .category("Продукти"))
    }
}
