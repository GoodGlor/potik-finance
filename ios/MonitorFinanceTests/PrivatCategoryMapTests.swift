import XCTest
@testable import MonitorFinance

/// Board #14: the «Приват» chip used to fork the taxonomy.
///
/// `acceptSuggestion` calls `addCategory` with whatever the chip carries, so
/// one tap on a statement word created a category. «Ресторани, кафе, бари»
/// landed beside the seeded «Кафе та ресторани» and one shop's history split
/// between the two — board #15 spent a whole card folding forty names down to
/// nineteen, and the chip grew them back one tap at a time.
final class PrivatCategoryMapTests: XCTestCase {

    private func seededCategories() throws -> Set<String> {
        Set(try SeedLoader.load().categories.map(\.name))
    }

    // MARK: the invariant

    /// The one that matters: a mapped chip can never create a category.
    ///
    /// Asserted against the seed the app actually ships rather than a list
    /// written out here, so a category renamed in `build_ios_seed.py` fails
    /// this instead of silently leaving a mapping pointing at a name that no
    /// longer exists.
    func testEveryMappedNameIsACategoryTheAppAlreadyHas() throws {
        let seeded = try seededCategories()
        XCTAssertFalse(seeded.isEmpty, "precondition: the seed ships categories")
        for (privat, ours) in PrivatMapper.categoryMap {
            XCTAssertTrue(seeded.contains(ours),
                          "«\(privat)» → «\(ours)», which is not a seeded category")
        }
    }

    /// …and translating twice is translating once. Rows imported before this
    /// card have «Готівка» stored where they now store «Зняття готівки», and
    /// both must reach the chip as «Готівка».
    func testTranslationIsIdempotent() throws {
        for (_, ours) in PrivatMapper.categoryMap {
            XCTAssertEqual(PrivatMapper.suggestion(for: ours), ours,
                           "«\(ours)» is a target AND a key — translating twice would move it")
        }
    }

    // MARK: the names

    func testTheNamesSeenInARealStatementAreTranslated() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "Супермаркети та продукти"), "Продукти")
        XCTAssertEqual(PrivatMapper.suggestion(for: "Ресторани, кафе, бари"), "Кафе та ресторани")
        XCTAssertEqual(PrivatMapper.suggestion(for: "Кредити"), "Кредит")
        XCTAssertEqual(PrivatMapper.suggestion(for: "Зняття готівки"), BudgetMath.cashCategory)
    }

    /// Both word orders reach the same place. One of the two is what this
    /// bank actually writes; carrying the other costs a line.
    func testBothSpellingsOfTheCafeCategoryLandTogether() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "Ресторани, кафе, бари"),
                       PrivatMapper.suggestion(for: "Кафе, бари, ресторани"))
    }

    /// A statement that capitalises differently between exports must not
    /// suddenly start creating categories.
    func testTheLookupFoldsCaseAndSurroundingSpace() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "  СУПЕРМАРКЕТИ ТА ПРОДУКТИ  "), "Продукти")
        XCTAssertEqual(PrivatMapper.suggestion(for: "супермаркети та продукти"), "Продукти")
    }

    /// The half the card asked for explicitly: an unmapped word still reaches
    /// the chip and is still created. Offering it while refusing to create it
    /// would be a button that does nothing.
    func testAnUnmappedWordIsOfferedUnchanged() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "Тварини"), "Тварини")
        XCTAssertEqual(PrivatMapper.suggestion(for: "Послуги"), "Послуги")
        XCTAssertEqual(PrivatMapper.suggestion(for: "Астрологія"), "Астрологія",
                       "a word nobody has mapped is the owner's to name")
    }

    /// …and it keeps the bank's own capitalisation when it falls through. The
    /// lookup lowercases to MATCH, not to rewrite: creating «астрологія» from
    /// «Астрологія» would put a lowercase name in a list of capitalised ones.
    func testAFallthroughKeepsTheBanksOwnCasing() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "АСТРОЛОГІЯ"), "АСТРОЛОГІЯ")
    }

    // MARK: the deviation

    /// A transfer word names a movement, not a purpose, so there is no honest
    /// one-tap answer — the card said "create it as today" and this
    /// deliberately does not. `GenericMerchant` already rules the same way on
    /// the same rows, which is why they get a card per transaction.
    func testATransferWordOffersNoChipAtAll() {
        for word in ["Перекази", "Переказ", "Переказ на чужу картку",
                     "Перекази — людям / P2P", "перекази з картки на картку"] {
            XCTAssertNil(PrivatMapper.suggestion(for: word), word)
        }
    }

    /// The prefix is a prefix, not a substring: a category that merely
    /// mentions a transfer somewhere in the middle is not one.
    func testTheTransferRuleDoesNotSwallowAWordThatOnlyContainsIt() {
        XCTAssertEqual(PrivatMapper.suggestion(for: "Комісія за переказ"), "Комісія за переказ")
    }

    func testAnEmptyOrBlankCategoryOffersNothing() {
        XCTAssertNil(PrivatMapper.suggestion(for: ""))
        XCTAssertNil(PrivatMapper.suggestion(for: "   "))
    }

    // MARK: the wiring — the table only helps if the queue reads it

    private func row(category: String, description: String,
                     amount: Int = -100_00, balance: Int = 1_000_00) -> PrivatRow {
        PrivatRow(date: Date(timeIntervalSince1970: 1_787_000_000), category: category,
                  cardSuffix: "*1111", descriptionText: description,
                  amountMinor: amount, currency: "UAH",
                  balanceMinor: balance, balanceCurrency: "UAH")
    }

    @MainActor
    private func store(_ rows: [PrivatRow]) throws -> AppStore {
        var seed = try SeedLoader.load()
        seed.transactions = rows.map { PrivatMapper.transaction($0) }
        seed.receipts = []
        seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    /// End to end, through the path the screen uses: what the card offers is
    /// the app's word, and accepting it creates nothing.
    @MainActor
    func testTheCardOffersTheAppsWordAndAcceptingItAddsNoCategory() throws {
        let s = try store([row(category: "Ресторани, кафе, бари", description: "Кафе-Приклад")])
        let before = s.categories.count
        let group = try XCTUnwrap(s.pendingGroups.first)
        XCTAssertEqual(group.suggestion, "Кафе та ресторани")

        XCTAssertEqual(s.acceptSuggestion(group), 1)
        XCTAssertEqual(s.categories.count, before,
                       "one tap must not grow the vocabulary board #15 shrank")
        XCTAssertEqual(s.transactions.first?.category, "Кафе та ресторани")
    }

    /// The bank's own word survives on the row. `CategorizationLog` reads this
    /// field as `bankSuggestion`, and a column meaning "what the bank guessed"
    /// filled with the app's word is a lie in a training corpus — which is the
    /// whole reason the translation happens at read time.
    @MainActor
    func testTheRowItselfKeepsWhatTheBankActuallyWrote() throws {
        let s = try store([row(category: "Ресторани, кафе, бари", description: "Кафе-Приклад")])
        XCTAssertEqual(s.transactions.first?.suggestions, ["Ресторани, кафе, бари"])
    }

    /// Translating at read time is what covers rows imported BEFORE this card.
    /// One is simulated here by storing the word board #6 used to write.
    @MainActor
    func testARowImportedBeforeThisCardStillGetsAWorkingChip() throws {
        var seed = try SeedLoader.load()
        var old = PrivatMapper.transaction(
            row(category: "Зняття готівки", description: "Банкомат-Приклад"))
        old.suggestions = [BudgetMath.cashCategory]      // what the old mapper stored
        seed.transactions = [old]; seed.receipts = []; seed.rules = []
        let s = AppStore(repository: MemoryRepository(), seed: seed,
                         keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertEqual(s.pendingGroups.first?.suggestion, BudgetMath.cashCategory)
    }

    /// A transfer row reaches the queue as its own card and offers no chip.
    @MainActor
    func testATransferRowGetsACardWithNoChip() throws {
        let s = try store([row(category: "Перекази", description: "Переказ-Приклад")])
        let group = try XCTUnwrap(s.pendingGroups.first)
        XCTAssertNil(group.suggestion, "a movement is not an answer")
        XCTAssertNotNil(group.date, "precondition: a transfer is a per-transaction card")
    }

    /// Two statement words meaning one category must add up rather than
    /// out-vote each other — which is why the translation runs before the
    /// tally and not after it.
    @MainActor
    func testTwoStatementWordsForOneCategoryAgreeInsteadOfCompeting() throws {
        let s = try store([
            row(category: "Ресторани, кафе, бари", description: "Кафе-Приклад", balance: 900_00),
            row(category: "Кафе, бари, ресторани", description: "Кафе-Приклад", balance: 800_00),
            row(category: "Тварини", description: "Кафе-Приклад", balance: 700_00),
        ])
        let group = try XCTUnwrap(s.pendingGroups.first)
        XCTAssertEqual(group.count, 3, "precondition: one merchant, one card")
        XCTAssertEqual(group.suggestion, "Кафе та ресторани",
                       "2 votes translated together beat 1, but only if they are counted together")
    }
}
