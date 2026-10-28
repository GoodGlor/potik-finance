import XCTest
@testable import MonitorFinance

final class BudgetStoreTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func store(_ repo: Repository = MemoryRepository()) throws -> AppStore {
        AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
    }

    /// D1: a plan may name a category the store has never seen — one restored
    /// from another device, or typed into the editor — and it would otherwise
    /// be a line the picker cannot show and the report cannot match.
    ///
    /// The fixture used to be the starter plan's own «Заощадження», which the
    /// seed did not ship. Board #6 seeded it (it is now the answer for a jar
    /// top-up, not only a plan line), so the precondition that made this test
    /// mean anything stopped holding — a plan naming only seeded categories
    /// creates nothing, and the assertions below would have passed against a
    /// `setBudget` that had lost the ability entirely.
    func testSavingAPlanCreatesAnyCategoryTheLinesNameButTheStoreLacks() throws {
        let s = try store()
        let invented = "Категорія-Приклад"
        XCTAssertFalse(s.categories.contains { $0.name == invented },
                       "precondition: the seed does not ship this category")
        let before = s.categories.count

        s.setBudget(Budget(incomeBase: .fixed(50_000_00), lines: [
            .init(id: UUID(), category: "Продукти", percent: 50),
            .init(id: UUID(), category: invented, percent: 50),
        ]))

        XCTAssertTrue(s.categories.contains { $0.name == invented })
        XCTAssertEqual(s.categories.count, before + 1,
                       "only the missing one is added — «Продукти» already exists")
    }

    /// Board #6's half of the same story: the starter plan now names nothing
    /// the seed lacks, so a person who saves it gets no invented categories at
    /// all. Pinned because it is what makes «Заощадження» offerable to someone
    /// who has never opened Бюджет — a jar top-up needs an answer whether or
    /// not its owner budgets.
    func testTheStarterPlanNamesOnlyCategoriesTheSeedAlreadyShips() throws {
        let s = try store()
        let seeded = Set(s.categories.map(\.name))
        for line in Budget.starter().lines {
            XCTAssertTrue(seeded.contains(line.category), line.category)
        }
        XCTAssertTrue(seeded.contains(BudgetMath.savingsCategory))
        XCTAssertTrue(seeded.contains(BudgetMath.cashCategory))
    }

    func testSavingAPlanTwiceDoesNotDuplicateCategories() throws {
        let s = try store()
        s.setBudget(Budget.starter())
        let after = s.categories.count
        s.setBudget(Budget.starter())
        XCTAssertEqual(s.categories.count, after)
    }

    func testTheStarterPlanTotalsExactlyOneHundred() {
        XCTAssertEqual(Budget.starter().lines.reduce(0) { $0 + $1.percent }, 100)
    }

    /// Board #23. The starter told a person with no loan that «Кредит» was
    /// 30% of their money — an example that assumes a debt, on the screen
    /// whose job is to be a neutral place to start. The three lines that
    /// replaced it are ones nobody escapes.
    ///
    /// The savings line stays: it is not an assumption about the person, it
    /// is the only line in the plan that is not spent, and `Derived` needs
    /// «Заощадження» to exist for a jar top-up to have an answer at all.
    func testTheStarterPlanAssumesNoDebt() {
        let categories = Budget.starter().lines.map(\.category)
        XCTAssertEqual(categories, ["Квартплата", "Продукти", BudgetMath.savingsCategory])
        XCTAssertFalse(categories.contains("Кредит"),
                       "an example plan must not invent a loan for somebody who has none")
    }

    func testAPlanSurvivesRelaunch() throws {
        let repo = MemoryRepository()
        let s = try store(repo)
        s.setBudget(Budget(incomeBase: .fixed(49_000_00),
                           lines: [.init(id: UUID(), category: "Продукти", percent: 100)]))
        s.persistNow()

        let reloaded = try store(repo)
        XCTAssertEqual(reloaded.budget?.lines.map(\.category), ["Продукти"])
        XCTAssertEqual(reloaded.budget?.incomeBase, .fixed(49_000_00))
    }

    /// The only test in this repo that proves a mutation persists *itself*.
    /// Every other persistence test calls `persistNow()` by hand, so deleting
    /// the `persist()` call from any mutation left every one of them green —
    /// they were testing `persistNow`, not the mutation. Deliberately no
    /// `persistNow()` here: the 300 ms debounce is what must do the work.
    func testSettingABudgetPersistsWithoutAnybodyAskingItTo() async throws {
        let repo = MemoryRepository()
        let s = try store(repo)
        XCTAssertNil(repo.files["budget"], "precondition: nothing on disk yet")

        s.setBudget(Budget(incomeBase: .fixed(49_000_00),
                           lines: [.init(id: UUID(), category: "Продукти", percent: 100)]))

        XCTAssertNil(repo.files["budget"], "the write is debounced, so it cannot have happened yet")

        // Comfortably past the 300 ms debounce.
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertNotNil(repo.files["budget"],
                        "setBudget must schedule its own write — nothing else is going to")
        let reloaded = try store(repo)
        XCTAssertEqual(reloaded.budget?.incomeBase, .fixed(49_000_00))
        XCTAssertEqual(reloaded.budget?.lines.map(\.category), ["Продукти"])
    }
}
