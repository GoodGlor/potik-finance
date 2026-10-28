import XCTest
@testable import MonitorFinance

/// Board #149 — «Авто» and «Автомобіль» were the same idea under two words.
///
/// The owner: «They also issued the Auto category, I don't understand why it is
/// there. There is an Automobile, so why is Авто there?»
///
/// `PrivatMapper.categoryMap` now stops the next one being created; these are
/// about the rows that already exist. Fixing only the mapper would leave the
/// person looking at exactly the two categories they asked about.
final class CategoryFoldTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func tx(_ category: String, _ merchant: String = "Автосервіс-Вигаданий") -> Transaction {
        Transaction(id: UUID(), date: .init(timeIntervalSince1970: 1_780_000_000),
                    kind: .expense, category: category, merchant: merchant, amount: -50_000,
                    cardSuffix: "*0000", bankId: "privatbank", receiptId: nil, splits: [],
                    resolution: .user, suggestions: [])
    }

    private func store() throws -> AppStore {
        AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(), keychain: keychain)
    }

    func testRowsUnderTheDuplicateNameMoveToTheRealOne() throws {
        let s = try store()
        s.transactions = [tx("Авто"), tx("Авто"), tx("Автомобіль")]
        s.categories = [Category(name: "Авто", tintIndex: 3),
                        Category(name: "Автомобіль", tintIndex: 5)]

        s.foldDuplicateCategories()

        XCTAssertEqual(s.transactions.filter { $0.category == "Автомобіль" }.count, 3)
        XCTAssertTrue(s.transactions.allSatisfy { $0.category != "Авто" })
        XCTAssertFalse(s.categories.contains { $0.name == "Авто" },
                       "the person must be left with ONE car category")
    }

    /// **The answer is preserved, not re-decided.** This card's own rule is
    /// «do not touch a row the person already answered», and a fold is
    /// compatible with it precisely because the row keeps its meaning — only
    /// the word changes. A test that let `resolution` drift would be the
    /// difference between re-spelling an answer and destroying it.
    func testTheAnswerItselfIsUntouched() throws {
        let s = try store()
        s.transactions = [tx("Авто")]
        s.categories = [Category(name: "Авто", tintIndex: 3),
                        Category(name: "Автомобіль", tintIndex: 5)]

        s.foldDuplicateCategories()

        XCTAssertEqual(s.transactions[0].resolution, .user,
                       "a fold re-spells an answer; it does not re-decide one")
    }

    /// A rule left pointing at the old name would re-apply it to the next
    /// matching purchase, growing the duplicate back one purchase at a time.
    func testARulePointingAtTheOldNameIsMovedToo() throws {
        let s = try store()
        s.transactions = [tx("Авто")]
        s.categories = [Category(name: "Авто", tintIndex: 3),
                        Category(name: "Автомобіль", tintIndex: 5)]
        s.rules = [Rule(merchantKey: "автосервіс-вигаданий", category: "Авто", ambiguous: false)]

        s.foldDuplicateCategories()

        XCTAssertEqual(s.rules.map(\.category), ["Автомобіль"])
    }

    /// **The merge keeps the TARGET's colour**, not the source's. Board #57
    /// settled that: the surviving category is «Автомобіль», and a category
    /// that changed colour because something merged into it would be the same
    /// class of defect this card is fixing.
    func testTheSurvivingCategoryKeepsItsOwnColour() throws {
        let s = try store()
        s.transactions = [tx("Авто")]
        s.categories = [Category(name: "Авто", tintIndex: 3),
                        Category(name: "Автомобіль", tintIndex: 5)]

        s.foldDuplicateCategories()

        XCTAssertEqual(s.categories.first { $0.name == "Автомобіль" }?.tintIndex, 5)
    }

    /// Idempotent by construction rather than by a flag — every launch calls
    /// this, so a second run must be a no-op AND must not conjure the target
    /// on a device that never had the duplicate. `renameCategory` appends the
    /// target when it is missing, which is exactly how that could happen.
    func testASecondRunChangesNothingAndNeverCreatesTheTarget() throws {
        let s = try store()
        s.transactions = [tx("Продукти")]
        s.categories = [Category(name: "Продукти", tintIndex: 1)]

        s.foldDuplicateCategories()
        s.foldDuplicateCategories()

        XCTAssertEqual(s.categories.map(\.name), ["Продукти"],
                       "a device with no «Авто» must not gain «Автомобіль»")
        XCTAssertEqual(s.transactions.map(\.category), ["Продукти"])
    }

    /// The fold list is deliberately ONE pair. Nine other off-vocabulary names
    /// exist in the owner's real log and most are not duplicates — «АЗС» sits
    /// beside «Автомобіль» by their own repeated choice.
    /// Folding on our own judgement is what this card forbids.
    func testOnlyTheReportedPairIsFoldedAutomatically() {
        XCTAssertEqual(AppStore.duplicateCategoryFolds.map(\.from), ["Авто"])
        XCTAssertEqual(AppStore.duplicateCategoryFolds.map(\.into), ["Автомобіль"])
    }
}
