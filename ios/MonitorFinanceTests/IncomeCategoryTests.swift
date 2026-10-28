import XCTest
@testable import MonitorFinance

/// The income vocabulary the kind-aware picker offers, and the two ways it
/// can silently stop being true: a name that no longer ships in the seed, and
/// a name the budget's income base does not recognise.
final class IncomeCategoryTests: XCTestCase {

    private func seedCategories() throws -> [String] {
        try SeedLoader.load().categories.map(\.name)
    }

    /// The categories themselves, which is what `BudgetMath` now asks for.
    /// A second helper rather than a changed one: four tests below read the
    /// names, and this card is about what a category SAYS, not what it is
    /// called.
    private func seeded() throws -> [MonitorFinance.Category] {
        try SeedLoader.load().categories
    }

    /// The picker writes these strings straight onto a `Transaction`, and
    /// `Theme.tint`, Статистика and Бюджет all key on the name. One typo
    /// here creates a category that exists on rows and in no list.
    func testEveryIncomeCategoryIsARealSeedCategory() throws {
        let shipped = Set(try seedCategories())
        for name in BudgetMath.incomeCategories(try seeded()) {
            XCTAssertTrue(shipped.contains(name), "«\(name)» is offered but not shipped")
        }
    }

    /// The relationship that makes the picker safe: every category it offers
    /// for income is either counted as earnings or knowingly excluded from
    /// them. What must never happen is an income row landing on a name
    /// `BudgetMath` has never heard of — that is the split between Головна
    /// and Бюджет this whole change exists to close.
    func testTheEarnedCategoriesAreAllOffered() throws {
        let categories = try seeded()
        for name in BudgetMath.earnedCategories(categories) {
            XCTAssertTrue(BudgetMath.incomeCategories(categories).contains(name),
                          "«\(name)» counts as income but cannot be chosen")
        }
    }

    /// «Подарунки» is the one offered name that is NOT earned, and that is the
    /// point of it: a birthday transfer is money in, and a plan built on it
    /// would be a plan built on next year's birthday.
    func testGiftsAreOfferedButNotCountedAsEarnings() throws {
        let categories = try seeded()
        XCTAssertTrue(BudgetMath.incomeCategories(categories).contains("Подарунки"))
        XCTAssertFalse(BudgetMath.earnedCategories(categories).contains("Подарунки"))
    }

    /// The default a synced income row arrives with must be one of the rows
    /// the user is then shown — otherwise the picker opens with the current
    /// answer missing from its own list.
    func testTheMapperSDefaultIsOneOfTheOfferedCategories() throws {
        let categories = try seeded()
        XCTAssertTrue(BudgetMath.incomeCategories(categories)
            .contains(BudgetMath.defaultIncomeCategory))
        // …and EARNED, not merely offered: a default outside the earned set
        // makes every synced income row worth zero to the budget, and the
        // default plan then divides by nothing.
        XCTAssertTrue(BudgetMath.earnedCategories(categories)
            .contains(BudgetMath.defaultIncomeCategory))
    }

    /// Order is part of the design — most common first, not alphabetical —
    /// and `all` returns this array verbatim rather than sorting it.
    func testTheOrderIsTheOneThePickerShows() throws {
        XCTAssertEqual(BudgetMath.incomeCategories(try seeded()),
                       ["Зарплата", "Стипендія", "Подарунки", "Інші надходження"])
    }

    /// Search inside the income list still works on the income list only —
    /// `matching` is shared with the spending picker, so this pins that
    /// nothing from the full category list leaks in through the query.
    func testSearchingTheIncomeListCannotSurfaceASpendingCategory() throws {
        let offered = BudgetMath.incomeCategories(try seeded())
        XCTAssertEqual(CategoryPicker.matching("Прод", in: offered), [])
        XCTAssertEqual(CategoryPicker.matching("зарп", in: offered), ["Зарплата"])
    }

    // MARK: what board #94 changed

    /// The card's whole point. Before it, income was decided by matching a
    /// NAME against a hardcoded set, so «Фріланс» counted as income on Головна
    /// (which reads the sign) and as nothing at all in Бюджет (which reads the
    /// category) — the very split `.income` was introduced to close.
    func testAUserMadeEarnedCategoryCountsTowardThePlan() {
        let categories = [MonitorFinance.Category(name: "Фріланс", kind: .earned),
                          MonitorFinance.Category(name: "Продукти", kind: .spending)]
        XCTAssertTrue(BudgetMath.earnedCategories(categories).contains("Фріланс"))
        let row = Transaction(id: UUID(),
                              date: ISO8601DateFormatter().date(from: "2026-07-10T12:00:00+03:00")!,
                              kind: .income, category: "Фріланс", merchant: "Фріланс",
                              amount: 10_000_00, cardSuffix: "*0000", bankId: "monobank",
                              receiptId: nil, splits: [], resolution: .user, suggestions: [])
        XCTAssertEqual(BudgetMath.income([row], includeGifts: false, categories: categories),
                       10_000_00)
    }

    /// Renaming «Зарплата» is one tap in Налаштування → Категорії, and it used
    /// to drop a person's salary out of their own income base with nothing on
    /// screen to say so. The kind travels with the category, so it cannot.
    func testRenamingAnEarnedCategoryKeepsItEarned() {
        let categories = [MonitorFinance.Category(name: "Основна робота", kind: .earned)]
        XCTAssertTrue(BudgetMath.earnedCategories(categories).contains("Основна робота"))
    }

    /// A category the app has never seen sorts after the canonical head, not
    /// into it: the seeded four are a vocabulary people learn by position.
    func testAnAddedIncomeCategoryComesAfterTheCanonicalOnes() throws {
        let categories = try seeded() + [MonitorFinance.Category(name: "Фріланс", kind: .earned)]
        XCTAssertEqual(BudgetMath.incomeCategories(categories),
                       ["Зарплата", "Стипендія", "Подарунки", "Інші надходження", "Фріланс"])
    }

    /// A spending category is never offered for income, however it is named.
    func testASpendingCategoryIsNeverOfferedForIncome() {
        let categories = [MonitorFinance.Category(name: "Зарплатний проєкт", kind: .spending)]
        XCTAssertEqual(BudgetMath.incomeCategories(categories), [])
        XCTAssertEqual(BudgetMath.earnedCategories(categories), [])
    }

    /// The refusal existed because a category created here could not be
    /// income. That reason is gone, and a refusal outliving its reason is a
    /// dead end: the person searches «Фріланс», finds nothing, and the picker
    /// says nothing about why it will not help.
    func testTheIncomePickerNowOffersToCreate() {
        XCTAssertEqual(CategoryPicker.offeredCreation(for: "Фріланс", in: ["Зарплата"],
                                                      purpose: .income),
                       "Фріланс")
    }

    /// The OTHER refusal is a different one and stays: «переказ» must never
    /// become a category, and the app would remember it forever. Asserted
    /// here so lifting one is never mistaken for lifting both.
    func testTheOwnTransferRefusalIsUntouched() {
        XCTAssertNil(CategoryPicker.offeredCreation(for: "переказ", in: [],
                                                    purpose: .expense))
    }
}
