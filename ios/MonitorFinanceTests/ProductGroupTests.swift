import XCTest
@testable import MonitorFinance

/// Board #184 — a person can invent a product group.
///
/// **Owner:** «I can't create my own category for products in the receipt, for
/// example, for Coca-Cola I would like to create the category Soft Water.»
///
/// They could not, and it was not merely a missing button: `productGroups` was
/// an immutable `let` assigned once from the seed, so the store had nowhere to
/// put an answer even if the picker had asked for one. `product-groups.jsonl`
/// had never carried a single row, because nobody could make one.
///
/// A product group is «what was bought»; a spending category is «where the
/// money went». They stay separate namespaces on purpose — one list of both
/// would offer «Комуналка» as an answer to what is in a shopping bag — so this
/// is deliberately not `addCategory` with a flag.
@MainActor
final class ProductGroupTests: XCTestCase {

    /// The seed as shipped, so «Інше» and the twenty real groups are present.
    /// Invented transaction data only; this repository is public.
    private func makeStore(_ repository: Repository = MemoryRepository()) throws -> AppStore {
        var seed = try SeedLoader.load()
        seed.transactions = []
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: creating one

    /// The owner's sentence, executed.
    func testAPersonCanInventAGroup() throws {
        let store = try makeStore()
        XCTAssertFalse(store.productGroups.contains { $0.name == "Солодка вода" })

        XCTAssertEqual(store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л"),
                       "Солодка вода")
        XCTAssertTrue(store.productGroups.contains { $0.name == "Солодка вода" },
                      "the group the person asked for has to be in the list they pick from")
    }

    /// `ProductGroupPicker.matches` never re-sorts, precisely so the store's
    /// own order survives to the screen — and the store's order puts «Інше»
    /// last, because it is the answer that means "none of the above". Appending
    /// a custom group would have buried it mid-list on every phone that has one.
    func testIncheStaysLastAfterAGroupIsAdded() throws {
        let store = try makeStore()
        XCTAssertEqual(store.productGroups.last?.name, ProductGuess.other,
                       "the precondition this test is about")

        store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")
        store.addProductGroup("Заморожені продукти", from: "Пельмені домашні")

        XCTAssertEqual(store.productGroups.last?.name, ProductGuess.other)
        // …and the two additions really are in the list, so the assertion
        // above is not passing because nothing was added.
        XCTAssertEqual(store.productGroups.count, 23)
    }

    /// Trimmed and case-insensitive, across the seed AND the person's own —
    /// «ліки» must not become a second «Ліки», and a duplicate of a custom
    /// group is the same mistake one step later.
    func testADuplicateFoldsRatherThanAddingTwice() throws {
        let store = try makeStore()
        let before = store.productGroups.count

        XCTAssertEqual(store.addProductGroup("  ліки  "), "Ліки",
                       "folded onto the seeded group, and reports ITS name")
        XCTAssertEqual(store.productGroups.count, before, "nothing was added")

        store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")
        XCTAssertEqual(store.addProductGroup("СОЛОДКА ВОДА"), "Солодка вода")
        XCTAssertEqual(store.productGroups.count, before + 1,
                       "the custom group is not duplicated either")
    }

    func testAnEmptyNameIsRefused() throws {
        let store = try makeStore()
        let before = store.productGroups.count
        XCTAssertNil(store.addProductGroup("   "))
        XCTAssertNil(store.addProductGroup(""))
        XCTAssertEqual(store.productGroups.count, before)
    }

    // MARK: the guesser can reach it

    /// The half that makes this a feature rather than a name the person picks
    /// by hand forever. The group learns the first word of the line it was
    /// created from, so the NEXT bottle places itself.
    func testAGroupCreatedFromAnItemIsReachableByTheGuesser() throws {
        let store = try makeStore()
        XCTAssertEqual(ProductGuess.group(for: "Coca-Cola 1 л", in: store.productGroups),
                       ProductGuess.other, "the precondition: nothing places it today")

        store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")

        // A DIFFERENT bottle — the point is the keyword generalises past the
        // exact line that taught it, which storing the whole item name would
        // not have done.
        XCTAssertEqual(ProductGuess.group(for: "Coca-Cola 1 л", in: store.productGroups),
                       "Солодка вода")
        XCTAssertEqual(ProductGuess.group(for: "coca-cola zero 0,33", in: store.productGroups),
                       "Солодка вода")
    }

    /// The collision guard. Creating a group from «Вода Моршинська» would take
    /// `вода` from the group that already owns it — and `ProductGuess` sorts
    /// candidates by keyword LENGTH, so two identical keywords are a tie that
    /// Swift's unstable sort can break either way from one run to the next.
    /// The group is still created; it is simply not guessable.
    func testAKeywordAnotherGroupAlreadyOwnsIsNotStolen() throws {
        let store = try makeStore()
        let owner = ProductGuess.group(for: "Вода Моршинська", in: store.productGroups)
        XCTAssertNotEqual(owner, ProductGuess.other,
                          "the precondition: some seeded group already claims «вода»")

        XCTAssertEqual(store.addProductGroup("Питна вода", from: "Вода Моршинська"), "Питна вода")

        XCTAssertTrue(store.productGroups.contains { $0.name == "Питна вода" },
                      "the group is created regardless — only the keyword is refused")
        XCTAssertEqual(store.customProductGroups.first { $0.name == "Питна вода" }?.keywords, [],
                       "and it carries no keyword rather than a stolen one")
        XCTAssertEqual(ProductGuess.group(for: "Вода Моршинська", in: store.productGroups), owner,
                       "the group that owned «вода» still owns it")
    }

    /// A line with no word to take is not a reason to refuse the group.
    func testAGroupCreatedFromNothingStillExists() throws {
        let store = try makeStore()
        XCTAssertEqual(store.addProductGroup("Порожня група"), "Порожня група")
        XCTAssertEqual(store.customProductGroups.last?.keywords, [])
    }

    // MARK: it survives a relaunch

    func testACustomGroupSurvivesARelaunch() throws {
        let repository = MemoryRepository()
        let first = try makeStore(repository)
        first.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")
        first.persistNow()

        let second = try makeStore(repository)
        XCTAssertTrue(second.productGroups.contains { $0.name == "Солодка вода" },
                      "a group that does not survive a relaunch was never created")
        XCTAssertEqual(second.customProductGroups.first?.keywords, ["coca-cola"],
                       "its keyword survives too, or the guess is lost on the next launch")
        XCTAssertEqual(second.productGroups.last?.name, ProductGuess.other,
                       "…and «Інше» is still last on the way back in")
    }

    /// **The file holds the person's additions and NOTHING else.**
    ///
    /// Persisting the composed taxonomy would have been one line shorter and
    /// would have frozen it: `reference.json` is regenerated from
    /// `app/core/products.py`, and a saved copy shadowing it means a later
    /// build's new keywords never reach a phone that has one custom group on
    /// it. Nothing on screen would say so — the guesser would simply keep
    /// getting older.
    func testTheSeededTaxonomyIsNeverWrittenToDisk() throws {
        let repository = MemoryRepository()
        let store = try makeStore(repository)
        store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")
        store.persistNow()

        let saved = try XCTUnwrap(repository.load("productGroups", as: [ProductGroup].self))
        XCTAssertEqual(saved.map(\.name), ["Солодка вода"],
                       "twenty-one seeded groups have no business in this file")
    }

    /// A phone that upgrades into this build has no such file, and must get
    /// the seed rather than an empty picker.
    func testAStoreWithNoSuchFileStillHasTheWholeTaxonomy() throws {
        let store = try makeStore()
        XCTAssertEqual(store.customProductGroups, [])
        XCTAssertEqual(store.productGroups.count, 21)
        XCTAssertEqual(store.productGroups.last?.name, ProductGuess.other)
    }

    // MARK: what a reset does to it

    /// Decided on the card rather than discovered. A group the person invented
    /// is their own work, like a rule or a category they added, and every one
    /// of those is destroyed by a reset. The mailbox is the single exception,
    /// for a reason nothing else shares: an address cannot be asked for again,
    /// and a product group takes one tap to recreate.
    func testAResetDestroysCustomGroups() throws {
        let repository = MemoryRepository()
        let store = try makeStore(repository)
        store.addProductGroup("Солодка вода", from: "Coca-Cola 0,5 л")
        XCTAssertEqual(store.customProductGroups.count, 1)

        store.resetEverything()

        XCTAssertEqual(store.customProductGroups, [], "the person's own groups go")
        XCTAssertEqual(store.productGroups.count, 21, "…and the seeded taxonomy comes back")
        XCTAssertEqual(store.productGroups.last?.name, ProductGuess.other)

        // On disk too, not just in memory — a reset that leaves the file
        // behind is a reset the next launch undoes.
        let saved = try repository.load("productGroups", as: [ProductGroup].self)
        XCTAssertEqual(saved ?? [], [])
    }

    // MARK: the first word rule

    /// The rule the keyword comes from, exercised directly because the seeded
    /// keywords are single words and a multi-word one would never match.
    func testFirstWordTakesTheLeadingTokenLowercased() {
        XCTAssertEqual(AppStore.firstWord(of: "Coca-Cola 0,5 л"), "coca-cola")
        XCTAssertEqual(AppStore.firstWord(of: "  Молоко Яготинське 2,6%  "), "молоко")
        XCTAssertEqual(AppStore.firstWord(of: "Хліб"), "хліб")
        XCTAssertNil(AppStore.firstWord(of: "   "))
        XCTAssertNil(AppStore.firstWord(of: ""))
    }
}
