import XCTest
@testable import MonitorFinance

final class ProductGuessTests: XCTestCase {

    private let groups = [
        ProductGroup(name: "Молочні продукти", keywords: ["молоко", "сир", "масло вершкове"]),
        ProductGroup(name: "Харчові жири", keywords: ["олія", "масло соняшникове"]),
        ProductGroup(name: "Зерноборошняні товари", keywords: ["хліб"]),
        ProductGroup(name: ProductGuess.other, keywords: []),
    ]

    func testAKeywordAnywhereInTheNamePlacesIt() {
        XCTAssertEqual(ProductGuess.group(for: "Хліб житній", in: groups), "Зерноборошняні товари")
        XCTAssertEqual(ProductGuess.group(for: "Молоко 2,5% 900 мл", in: groups), "Молочні продукти")
    }

    /// The rule that lets one word belong to two groups: «масло вершкове» is
    /// dairy, «масло соняшникове» is a fat, and the longer match decides.
    /// Shortest-first iteration puts both in whichever group is listed first.
    ///
    /// This fixture alone does NOT prove longest-first ordering: neither
    /// input string contains both ambiguous keywords, so which one is
    /// checked first cannot change either answer. It stays as a readable
    /// illustration of the rule; the load-bearing proof is
    /// `testTheLongestKeywordWinsAcrossTheShippedTaxonomy` below, which uses
    /// real collisions where the shorter keyword is a literal substring of
    /// the longer one, so iteration order genuinely decides the answer.
    func testTheLongestKeywordWins() {
        XCTAssertEqual(ProductGuess.group(for: "Масло вершкове 82%", in: groups), "Молочні продукти")
        XCTAssertEqual(ProductGuess.group(for: "Масло соняшникове 1 л", in: groups), "Харчові жири")
    }

    /// `app/core/products.py` has several keywords that are themselves
    /// substrings of a longer keyword belonging to a DIFFERENT group —
    /// «вино» sits inside «виноград», «сир» inside «сироп», and so on. Any
    /// input containing the longer word also contains the shorter one, so
    /// this is the one place iteration order can actually be observed:
    /// checked shortest-first, every case below would land in the WRONG
    /// group. Run against the real seed because that is what the app
    /// actually iterates — a hand-built fixture could get the ordering
    /// right for a reason that has nothing to do with the taxonomy `GROUPS`
    /// dict shipping in the right shape.
    func testTheLongestKeywordWinsAcrossTheShippedTaxonomy() throws {
        let groups = try SeedLoader.load().productGroups
        let cases: [(name: String, expected: String, wrong: String)] = [
            ("Виноград без кісточок", "Плодоовочеві товари", "Смакові товари"),
            ("Лимонад натуральний", "Смакові товари", "Плодоовочеві товари"),
            ("Туалетна вода жіноча", "Косметика та парфумерія", "Смакові товари"),
            ("Сироп від кашлю", "Ліки", "Молочні продукти"),
            ("Рушники паперові кухонні", "Побутова хімія та гігієна", "Товари для дому"),
            ("Постільна білизна бавовна", "Товари для дому", "Одяг та взуття"),
            ("Іграшка для тварин гумова", "Товари для тварин", "Дитячі товари"),
        ]
        for c in cases {
            let placed = ProductGuess.group(for: c.name, in: groups)
            XCTAssertEqual(placed, c.expected, c.name)
            XCTAssertNotEqual(placed, c.wrong, c.name)
        }
    }

    /// Ambiguous on its own, so it must NOT be guessed — «масло» is not a
    /// keyword of either group, only its qualified forms are.
    func testABareAmbiguousWordFallsToInshe() {
        XCTAssertEqual(ProductGuess.group(for: "Масло", in: groups), ProductGuess.other)
    }

    func testAnUnknownNameFallsToInsheRatherThanTheNearestGroup() {
        XCTAssertEqual(ProductGuess.group(for: "Батарейки АА", in: groups), ProductGuess.other)
    }

    /// `MerchantKey.normalize` lowercases before `ProductGuess` ever
    /// compares, and that IS load-bearing — a receipt line arrives however
    /// the decoder capitalised it, and a mutation removing `.lowercased()`
    /// reddens the first assertion below. (An earlier version of this test
    /// asserted survival of decomposed Cyrillic instead; that assertion
    /// could never fail, because Swift's `String ==`/`.contains` already
    /// compare precomposed and canonically-decomposed Cyrillic as equal on
    /// their own, independent of `precomposedStringWithCanonicalMapping` —
    /// see task-2-report.md.)
    func testMatchingSurvivesCaseAndSurroundingWhitespace() {
        let g = [ProductGroup(name: "Молочні продукти", keywords: ["йогурт"])]
        XCTAssertEqual(ProductGuess.group(for: "ЙОГУРТ", in: g), "Молочні продукти")

        // Documentation, not a constraint, unlike the line above: `.contains`
        // is a substring test, so padding on the OUTSIDE of the whole
        // normalized string can never stop a keyword from being found
        // inside it — removing `.trimmingCharacters(...)` from
        // `MerchantKey.normalize` does not redden this (verified in
        // task-2-report.md). The trim itself is still correct to keep: it
        // is load-bearing for `MerchantKey`'s other, `==`-based callers in
        // `AppStore+Queue.swift`, where un-trimmed padding would break
        // merchant-key equality — just not for this contains()-based one.
        XCTAssertEqual(ProductGuess.group(for: "  Йогурт  \n", in: g), "Молочні продукти")

        // Also documentation, not a constraint: this assertion cannot fail
        // whether or not `MerchantKey.normalize` calls
        // `precomposedStringWithCanonicalMapping` — Swift's `String`
        // already treats precomposed and canonically-decomposed Cyrillic as
        // equal natively. Kept only to record that the behavior holds.
        let decomposed = "Йогурт".decomposedStringWithCanonicalMapping
        XCTAssertEqual(ProductGuess.group(for: decomposed, in: g), "Молочні продукти")
    }

    /// The real taxonomy, through the real seed — proves the fixtures above
    /// are not the only thing that works.
    func testTheShippedTaxonomyPlacesTheSeedsOwnGroceryLines() throws {
        let seed = try SeedLoader.load()
        XCTAssertEqual(seed.productGroups.count, 21)
        XCTAssertEqual(ProductGuess.group(for: "Хліб житній", in: seed.productGroups),
                       "Зерноборошняні товари")
        XCTAssertEqual(ProductGuess.group(for: "Бензин А-95-Євро5", in: seed.productGroups),
                       "Пальне та автотовари")
    }
}
