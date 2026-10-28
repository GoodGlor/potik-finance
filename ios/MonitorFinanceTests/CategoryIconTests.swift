import XCTest
import SwiftUI
import UIKit
@testable import MonitorFinance

/// Board #61. Each category carries its own icon, chosen from a set the app
/// offers.
///
/// Colour narrows the field to one of twenty; the icon is what actually names
/// a category — see the palette note in `CategoryWashTests`, where twenty
/// colours a colourblind reader can distinguish turn out not to exist. These
/// two cards are one design and this file is the half that carries meaning.
@MainActor
final class CategoryIconTests: XCTestCase {

    private func makeStore(_ repository: Repository = MemoryRepository(),
                           categories: [String] = []) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [],
                              categories: categories.map { Category(name: $0, tintIndex: nil) },
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: the names have to be real

    /// **The test this file exists for.** A misspelt SF Symbol does not throw,
    /// does not warn and does not crash — `Image(systemName:)` draws nothing,
    /// so the swatch renders as a bare colour and the only way to find out is
    /// to look at that exact category on a device.
    ///
    /// Asked of UIKit rather than of a list copied from a documentation page,
    /// because what matters is whether THIS deployment target resolves it.
    func testEveryOfferedIconIsARealSymbol() {
        for icon in CategoryIcon.offered {
            XCTAssertNotNil(UIImage(systemName: icon), "«\(icon)» is not a symbol; it will draw nothing")
        }
        XCTAssertNotNil(UIImage(systemName: CategoryIcon.fallback))
    }

    /// And the seed's nineteen, which are written in a Python builder that
    /// cannot ask UIKit anything.
    func testEverySeededIconIsARealSymbol() throws {
        for category in try SeedLoader.load().categories {
            let icon = try XCTUnwrap(category.icon, "\(category.name) ships without an icon")
            XCTAssertNotNil(UIImage(systemName: icon),
                            "\(category.name) ships «\(icon)», which is not a symbol")
        }
    }

    /// The offered set is browsed as a grid of alternatives. Two cells drawing
    /// the same glyph is a choice that cannot be made.
    func testTheOfferedSetHasNoDuplicates() {
        XCTAssertEqual(Set(CategoryIcon.offered).count, CategoryIcon.offered.count)
        XCTAssertEqual(CategoryIcon.offered.count, CategoryIcon.groups.reduce(0) { $0 + $1.icons.count })
    }

    // MARK: the three acceptance criteria

    /// First criterion. Not just "an icon" — a DIFFERENT one for each, or the
    /// icon carries no more information than the name already did.
    func testTheSeededCategoriesHaveSensibleAndDistinctIcons() throws {
        let seeded = try SeedLoader.load().categories
        XCTAssertEqual(seeded.count, 19)

        let icons = seeded.compactMap(\.icon)
        XCTAssertEqual(icons.count, 19, "a seeded category has no icon")
        XCTAssertEqual(Set(icons).count, 19, "two seeded categories wear the same icon")

        // A handful pinned by name, because "sensible" is the criterion and
        // only a human reading this line can check it. These are the ones a
        // person would notice immediately if they were wrong.
        let byName = Dictionary(uniqueKeysWithValues: seeded.map { ($0.name, $0.icon) })
        XCTAssertEqual(byName["Продукти"], "cart")
        XCTAssertEqual(byName["Кафе та ресторани"], "fork.knife")
        XCTAssertEqual(byName["Автомобіль"], "car")
        XCTAssertEqual(byName["Тварини"], "pawprint")
    }

    /// Every seeded icon must be reachable in the chooser too. Otherwise a
    /// person who changes «Продукти» away from the trolley cannot change it
    /// back.
    func testEverySeededIconIsAlsoOnOffer() throws {
        for category in try SeedLoader.load().categories {
            let icon = try XCTUnwrap(category.icon)
            XCTAssertTrue(CategoryIcon.offered.contains(icon),
                          "\(category.name) ships «\(icon)», which the chooser does not offer")
        }
    }

    /// Second criterion.
    func testACategoryCanBeGivenAnIconFromTheOfferedSet() {
        let store = makeStore(categories: ["Ялинка"])
        XCTAssertEqual(store.iconName(for: "Ялинка"), CategoryIcon.fallback)

        store.setIcon("gift", for: "Ялинка")
        XCTAssertEqual(store.iconName(for: "Ялинка"), "gift")
    }

    /// Third criterion, and the one that covers every category already on a
    /// phone: `icon` is nil for all of them and always will be for the ones
    /// nobody chooses for.
    func testACategoryWithNoIconStillRenders() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data(#"[{"name":"Продукти","tintIndex":0}]"#.utf8)
        let store = makeStore(repo)

        XCTAssertNil(store.categories.first?.icon, "precondition: the old file has no icon")
        let drawn = store.iconName(for: "Продукти")
        XCTAssertEqual(drawn, CategoryIcon.fallback)
        XCTAssertNotNil(UIImage(systemName: drawn), "the fallback itself must draw something")
    }

    /// A row can name a category the store does not have — an import, a
    /// restore. The feed still has to draw it.
    func testAnUnknownCategoryDrawsTheFallbackRatherThanNothing() {
        XCTAssertEqual(makeStore(categories: ["Продукти"]).iconName(for: "Категорія-Привид"),
                       CategoryIcon.fallback)
    }

    // MARK: what the store refuses

    /// **A symbol the app does not offer is refused, and this is not
    /// pedantry.** The chooser cannot produce one; a restored file, a hand
    /// edit or a build with a longer list can. An unresolvable name draws
    /// NOTHING — no error, no placeholder, a blank swatch — so the store is
    /// the last place that can say no while somebody is still watching.
    func testAnIconTheAppDoesNotOfferIsRefused() {
        let store = makeStore(categories: ["Продукти"])
        store.setIcon("bag", for: "Продукти")
        store.setIcon("definitely.not.a.symbol", for: "Продукти")
        XCTAssertEqual(store.iconName(for: "Продукти"), "bag", "the junk name was accepted")
    }

    func testSettingAnIconOnACategoryThatDoesNotExistDoesNothing() {
        let store = makeStore(categories: ["Продукти"])
        store.setIcon("gift", for: "Категорія-Привид")
        XCTAssertEqual(store.categories.count, 1)
        XCTAssertNil(store.categories.first?.icon)
    }

    // MARK: it travels with the category

    /// A rename is the same category under a different word — the icon goes
    /// with it, exactly as the colour does.
    func testRenamingCarriesTheIconAcross() {
        let store = makeStore(categories: ["Продукти"])
        store.setIcon("cart", for: "Продукти")
        store.renameCategory("Продукти", to: "Їжа")
        XCTAssertEqual(store.iconName(for: "Їжа"), "cart")
    }

    /// A merge keeps the target's, like the colour.
    func testMergingKeepsTheTargetsIcon() {
        let store = makeStore(categories: ["Продукти", "Транспорт"])
        store.setIcon("cart", for: "Продукти")
        store.setIcon("bus", for: "Транспорт")
        store.mergeCategory("Продукти", into: "Транспорт")
        XCTAssertEqual(store.iconName(for: "Транспорт"), "bus")
    }

    func testTheChoiceSurvivesARelaunch() async throws {
        let repo = MemoryRepository()
        let store = makeStore(repo, categories: ["Ялинка"])
        store.setIcon("gift", for: "Ялинка")

        // The debounce, not `persistNow()` — a test that calls that by hand is
        // testing `persistNow`.
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(makeStore(repo).iconName(for: "Ялинка"), "gift")
    }

    /// A `categories.json` from a build with icons the app no longer offers
    /// must still decode, and must not draw a blank.
    func testAStoredIconTheAppNoLongerOffersIsStillDrawn() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data("""
        [{"name":"Продукти","tintIndex":0,"icon":"cart"}]
        """.utf8)
        XCTAssertEqual(makeStore(repo).iconName(for: "Продукти"), "cart")
    }
}
