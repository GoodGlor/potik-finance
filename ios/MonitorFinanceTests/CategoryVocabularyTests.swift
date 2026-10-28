import XCTest
@testable import MonitorFinance

/// Boards #15 and #12: what a person meets on their FIRST category pick.
///
/// Forty names is not a list, it is a wall — and five of them were transfers,
/// which boards #6, #7 and #13 established are not categories at all. The seed
/// now ships nineteen: fifteen things money is spent on, plus the four income
/// categories the budget counts.
@MainActor
final class CategoryVocabularyTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func store() throws -> AppStore {
        AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(), keychain: keychain)
    }

    // MARK: the vocabulary itself

    func testTheSeedShipsNineteenCategories() throws {
        let names = try store().categories.map(\.name)
        XCTAssertEqual(names.count, 19)
        XCTAssertEqual(Set(names).count, 19, "no name may be seeded twice")
    }

    /// The names every other part of the app reaches for by constant. A trim
    /// that dropped one of these would break the budget's income base, the
    /// starter plan, or the answer #6 routes cash and jars to — quietly, since
    /// a category is only a string.
    func testEveryLoadBearingNameSurvivedTheTrim() throws {
        let seeded = try store().categories
        let names = Set(seeded.map(\.name))
        for name in BudgetMath.incomeCategories(seeded) {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertTrue(names.contains(BudgetMath.savingsCategory))
        XCTAssertTrue(names.contains(BudgetMath.cashCategory))
        for line in Budget.starter().lines {
            XCTAssertTrue(names.contains(line.category), line.category)
        }
        for name in CategoryPicker.popularCategories {
            XCTAssertTrue(names.contains(name), "«Популярні» offers a category nobody has: \(name)")
        }
    }

    /// The transfer names are gone, and gone means GONE — not merely unused.
    /// Leaving one in the list would put "who you paid" back in a vocabulary
    /// that describes what you bought, one row above the answer that handles
    /// transfers properly.
    func testNoTransferNameIsOfferedAsACategory() throws {
        for name in try store().categories.map(\.name) {
            XCTAssertFalse(name.lowercased().contains("переказ"), name)
        }
    }

    /// The demo cannot use a word the picker will not show: a row categorised
    /// «Суші» would be unreachable in Settings and unpickable in the picker,
    /// while still colouring a slice of the donut.
    func testEveryCategoryTheDemoUsesIsOneThePickerOffers() throws {
        let s = try store()
        let names = Set(s.categories.map(\.name))
        let used = Set(s.transactions.map(\.category)).subtracting([""])
        XCTAssertEqual(used.subtracting(names), [])
    }

    /// The rows that carry no category at all are exactly the own-card
    /// transfers — the app never stores one on those, so the demo must not
    /// either. Any OTHER blank would be a row the app cannot explain.
    func testOnlyTransfersCarryNoCategory() throws {
        let blank = try store().transactions.filter { $0.category.isEmpty }
        XCTAssertFalse(blank.isEmpty, "precondition: the demo has own-card transfers")
        XCTAssertTrue(blank.allSatisfy { $0.kind == .transfer })
    }

    // MARK: Ukrainian order

    /// `sorted()` compares unicode scalars, and І (U+0406) and Ї (U+0407) sit
    /// BELOW А (U+0410) — so the list opened «Інтернет», «Інші надходження»,
    /// «Автомобіль». Nobody looking alphabetically finds anything in a list
    /// that starts at І.
    func testTheListIsInUkrainianAlphabeticalOrderNotCodePointOrder() {
        let names = ["Їжа-Приклад", "Автомобіль", "Інші надходження", "Продукти", "Банк-Приклад"]
        let sorted = Category.alphabetical(names)
        XCTAssertEqual(sorted.first, "Автомобіль", "А opens a Ukrainian list — \(sorted)")
        XCTAssertLessThan(sorted.firstIndex(of: "Автомобіль")!,
                          sorted.firstIndex(of: "Інші надходження")!)
        XCTAssertLessThan(sorted.firstIndex(of: "Банк-Приклад")!,
                          sorted.firstIndex(of: "Продукти")!)
        XCTAssertNotEqual(sorted, names.sorted(), "code-point order must not be what this returns")
    }

    /// The seed run of the same thing, which is what a person actually sees.
    func testTheSeededListOpensWithА() throws {
        let shown = Category.alphabetical(try store().categories.map(\.name))
        XCTAssertEqual(shown.first, "Автомобіль")
        XCTAssertEqual(shown.count, 19)
    }

    // MARK: the own-transfer row and search

    /// Board #12: the row vanished on the first keystroke, so typing the word
    /// it is named after was the one guaranteed way never to find it.
    func testSearchingForATransferKeepsTheOwnTransferRow() {
        for query in ["", "  ", "переказ", "ПЕРЕКАЗ", "свої", "картк", "це не витрата"] {
            XCTAssertTrue(CategoryPicker.searchFindsOwnTransfer(query), "«\(query)»")
        }
    }

    /// And the other half — it is not a row that follows every search around.
    func testSearchingForSomethingElseHidesIt() {
        for query in ["прод", "кава", "zzz"] {
            XCTAssertFalse(CategoryPicker.searchFindsOwnTransfer(query), "«\(query)»")
        }
    }

    /// The pairing the search change created and would otherwise get wrong:
    /// «переказ» now keeps the own-transfer row on screen, and «Створити
    /// «переказ»» underneath it invites a person to make a category out of the
    /// one answer that must not be one — permanently, since a created category
    /// is stored.
    func testTheCreateOfferNeverSitsBesideTheOwnTransferRow() {
        let all = ["Продукти", "Розваги"]
        XCTAssertNil(CategoryPicker.offeredCreation(for: "переказ", in: all, purpose: .expense))
        XCTAssertNil(CategoryPicker.offeredCreation(for: "свої", in: all, purpose: .expense))
        // …while an ordinary unmatched search still offers it, or the guard
        // above would have taken the create button away entirely.
        XCTAssertEqual(CategoryPicker.offeredCreation(for: "Суші-Приклад", in: all,
                                                      purpose: .expense),
                       "Суші-Приклад")
        // Board #94 lifted the income refusal. It was right while income was
        // decided by matching a NAME against a hardcoded set — an invented
        // category counted on Головна and nowhere in Бюджет — and a category
        // now carries its own kind, so the one created here is `.earned` and
        // both screens agree. The own-transfer refusal above is a DIFFERENT
        // one and is untouched.
        XCTAssertEqual(CategoryPicker.offeredCreation(for: "Суші-Приклад", in: all,
                                                      purpose: .income),
                       "Суші-Приклад")
        // A plan line names a budget category and never shows the transfer row,
        // so the guard must not reach it.
        XCTAssertEqual(CategoryPicker.offeredCreation(for: "переказ", in: all, purpose: .planLine),
                       "переказ")
    }

    // MARK: «Популярні»

    /// Eight, ordered by likelihood rather than alphabetically: the list is
    /// short enough to read whole, and its job is to put the likeliest answer
    /// under the thumb.
    func testPopularIsAShortDeliberateList() {
        XCTAssertEqual(CategoryPicker.popularCategories.count, 8)
        XCTAssertEqual(CategoryPicker.popularCategories.first, "Продукти")
        XCTAssertEqual(Set(CategoryPicker.popularCategories).count, 8)
        XCTAssertNotEqual(CategoryPicker.popularCategories,
                          Category.alphabetical(CategoryPicker.popularCategories),
                          "likelihood order, not alphabetical")
    }

    /// «Популярні» is what stands in while «Нещодавні» has nothing to say, so
    /// the fresh-install state has to be exactly that: no recents, a full
    /// popular list.
    func testAFreshInstallShowsPopularBecauseThereAreNoRecents() throws {
        let s = try store()
        XCTAssertEqual(s.recentCategories, [])
        let known = Set(s.categories.map(\.name))
        XCTAssertEqual(CategoryPicker.popularCategories.filter(known.contains).count, 8)
    }
}
