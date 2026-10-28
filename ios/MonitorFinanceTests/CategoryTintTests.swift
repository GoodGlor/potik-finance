import XCTest
import SwiftUI
import UIKit
@testable import MonitorFinance

/// Board #57. A category's colour is a property of the category, not a hash of
/// its name.
///
/// Before this, `Theme.tint(for:)` hashed nineteen seeded names into twelve
/// washes, so «Покупки» and «Послуги» were one colour on the feed, in the
/// picker, in Налаштування — everywhere except Статистика, which board #24 had
/// already moved onto rank colours for exactly this reason. Colour was
/// decoration that looked like information.
///
/// `CategoryWashTests` holds the palette itself; this file holds who gets what
/// out of it.
@MainActor
final class CategoryTintTests: XCTestCase {

    private func makeStore(_ repository: Repository = MemoryRepository(),
                           categories: [String] = []) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [],
                              categories: categories.map { Category(name: $0, tintIndex: nil) },
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: the two acceptance criteria

    /// The card's first criterion, against the real seed rather than a
    /// fixture: the nineteen categories a person actually gets must be
    /// nineteen colours.
    func testNoTwoSeededCategoriesShareAColour() throws {
        let seed = try SeedLoader.load()
        let store = AppStore(repository: MemoryRepository(), seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))

        let indexes = store.categories.map { store.tintIndex(for: $0.name) }
        XCTAssertEqual(indexes.count, 19)
        XCTAssertEqual(Set(indexes).count, indexes.count,
                       "two seeded categories still land on one wash")
    }

    /// The pair the card named, and the one `StatsColourTests` used to assert
    /// as a precondition. It is now the assertion in the other direction.
    func testTheTwoCategoriesTheCardNamedAreNoLongerOneColour() throws {
        let seed = try SeedLoader.load()
        let store = AppStore(repository: MemoryRepository(), seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        XCTAssertNotEqual(store.tintIndex(for: "Покупки"), store.tintIndex(for: "Послуги"))
    }

    /// The second criterion. There is one function and four screens call it,
    /// so "the same on every screen" is a claim about there being one answer
    /// — which is what this asserts, repeatedly and from a cold store.
    func testACategoryKeepsOneColourAcrossEveryLookup() {
        let store = makeStore(categories: ["Продукти", "Транспорт"])
        let first = store.tintIndex(for: "Продукти")
        for _ in 0..<10 {
            XCTAssertEqual(store.tintIndex(for: "Продукти"), first)
        }
        XCTAssertNotEqual(store.tintIndex(for: "Транспорт"), first)
    }

    // MARK: allocation

    /// Alphabetical, and this is the test that says so. File order differs
    /// between a fresh install, a restore and a device that has renamed
    /// something; allocating in arrival order would give three devices holding
    /// the same categories three different colour maps.
    func testAllocationFollowsAlphabeticalOrderAndNotFileOrder() {
        let names = ["Транспорт", "Автомобіль", "Продукти"]
        let forwards = makeStore(categories: names)
        let backwards = makeStore(categories: names.reversed())
        for name in names {
            XCTAssertEqual(forwards.tintIndex(for: name), backwards.tintIndex(for: name),
                           "\(name) got a different colour from a different file order")
        }
        // Ukrainian alphabetical: Автомобіль, Продукти, Транспорт.
        XCTAssertEqual(forwards.tintIndex(for: "Автомобіль"), 0)
        XCTAssertEqual(forwards.tintIndex(for: "Продукти"), 1)
        XCTAssertEqual(forwards.tintIndex(for: "Транспорт"), 2)
    }

    func testANewCategoryTakesTheLowestFreeWash() {
        let store = makeStore(categories: ["Автомобіль", "Продукти"])
        store.addCategory("Ялинка", kind: .spending)
        XCTAssertEqual(store.tintIndex(for: "Ялинка"), 2)
    }

    /// A merge frees a wash, and the next category takes it. Otherwise a
    /// person who tidies their categories exhausts the palette while holding
    /// three of them.
    func testAFreedWashIsHandedOutAgain() {
        let store = makeStore(categories: ["Автомобіль", "Продукти", "Транспорт"])
        XCTAssertEqual(store.tintIndex(for: "Продукти"), 1)
        store.mergeCategory("Продукти", into: "Транспорт")
        store.addCategory("Ялинка", kind: .spending)
        XCTAssertEqual(store.tintIndex(for: "Ялинка"), 1, "wash 1 went free and should be reused")
    }

    /// **Deleting does NOT free a wash, and that is deliberate.** The store
    /// expresses a delete as a rename onto «Інше» — one code path, so the two
    /// cannot disagree about what happens to the rules — and a rename carries
    /// the colour. So when «Інше» does not already exist, it is created
    /// wearing the deleted category's colour, and the rows that just moved
    /// there do not change colour under the person who moved them.
    ///
    /// Where «Інше» already exists it keeps its own, exactly like any merge.
    func testDeletingHandsTheColourToTheCategoryTheRowsMoveTo() {
        let store = makeStore(categories: ["Автомобіль", "Продукти", "Транспорт"])
        let before = store.tintIndex(for: "Продукти")
        store.deleteCategory("Продукти")
        XCTAssertEqual(store.tintIndex(for: "Інше"), before)

        let existing = makeStore(categories: ["Інше", "Продукти"])
        let kept = existing.tintIndex(for: "Інше")
        existing.deleteCategory("Продукти")
        XCTAssertEqual(existing.tintIndex(for: "Інше"), kept)
    }

    /// Twenty-one categories into twenty washes: one pair must share, and the
    /// most that can be asked is that the sharing be spread rather than piled
    /// onto wash 0.
    func testPastTheTwentiethTheLeastUsedWashIsReused() {
        let store = makeStore()
        for i in 0..<21 { store.addCategory("К\(String(format: "%02d", i))", kind: .spending) }
        var counts = [Int](repeating: 0, count: Theme.washes.count)
        for category in store.categories { counts[store.tintIndex(for: category.name)] += 1 }
        XCTAssertEqual(counts.reduce(0, +), 21)
        XCTAssertEqual(counts.max(), 2, "the 21st should double up once, not pile on")
        XCTAssertEqual(counts.filter { $0 == 2 }.count, 1)
    }

    // MARK: migration

    /// The migration that runs on every phone in existence: `tintIndex` has
    /// been in the model since the beginning and nothing ever wrote it.
    func testACategoryFileWrittenBeforeThisFieldGetsColoursOnLoad() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data("""
        [{"name":"Продукти"},{"name":"Транспорт"},{"name":"Автомобіль"}]
        """.utf8)

        let store = makeStore(repo)
        XCTAssertEqual(store.categories.count, 3, "precondition: the old file still decodes")
        for category in store.categories {
            XCTAssertNotNil(category.tintIndex, "\(category.name) was left without a colour")
        }
        XCTAssertEqual(Set(store.categories.compactMap(\.tintIndex)).count, 3)
    }

    /// And it is written down, not recomputed each launch — because it will
    /// not stay the same if it is. Add a category alphabetically BEFORE the
    /// others and a recomputed allocation shuffles everything after it.
    func testTheColoursSurviveARelaunchUnchanged() async throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data(#"[{"name":"Продукти"},{"name":"Транспорт"}]"#.utf8)

        let first = makeStore(repo)
        let before = first.categories.map { ($0.name, first.tintIndex(for: $0.name)) }
        first.addCategory("Автомобіль", kind: .spending)   // sorts first, and must NOT take wash 0

        // `addCategory` schedules the debounced `persist()`. Awaiting it
        // rather than reaching for `persistNow()` is the point: a test that
        // calls `persistNow` by hand is testing `persistNow`.
        try await Task.sleep(for: .milliseconds(1_200))

        let next = makeStore(repo)
        for (name, index) in before {
            XCTAssertEqual(next.tintIndex(for: name), index,
                           "\(name) changed colour because a new category sorted above it")
        }
        XCTAssertEqual(next.tintIndex(for: "Автомобіль"), 2)
    }

    /// The migration writes straight through rather than via `persist()`.
    /// A 300 ms debounce means a launch-then-force-quit comes back to a
    /// different set of colours, which is the defect one layer down.
    func testTheMigrationIsOnDiskBeforeTheDebounceCouldHaveFired() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data(#"[{"name":"Продукти"},{"name":"Транспорт"}]"#.utf8)

        let store = makeStore(repo)
        XCTAssertEqual(store.categories.count, 2)

        // No sleep, no persistNow: whatever is on disk now is what a force
        // quit would leave behind.
        let written = try XCTUnwrap(repo.files["categories"])
        // Qualified: bare `Category` here resolves against `os.Category` too,
        // and the type checker gives up rather than picking one.
        let saved = try SeedLoader.decoder.decode([MonitorFinance.Category].self, from: written)
        XCTAssertEqual(Set(saved.compactMap { $0.tintIndex }).count, 2,
                       "the colours were only in memory")
    }

    /// A file that already has colours must not be rewritten on every launch.
    func testAnAlreadyColouredFileIsLeftAlone() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data("""
        [{"name":"Продукти","tintIndex":7},{"name":"Транспорт","tintIndex":3}]
        """.utf8)
        let before = repo.files["categories"]

        let store = makeStore(repo)
        XCTAssertEqual(store.tintIndex(for: "Продукти"), 7)
        XCTAssertEqual(store.tintIndex(for: "Транспорт"), 3)
        XCTAssertEqual(repo.files["categories"], before, "nothing changed; nothing should be written")
    }

    /// Half-coloured is the shape a partial restore or a merge of two files
    /// produces: the ones with a colour keep it, and only the gaps are filled.
    func testOnlyTheCategoriesWithoutAColourAreGivenOne() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data("""
        [{"name":"Продукти","tintIndex":0},{"name":"Транспорт"}]
        """.utf8)

        let store = makeStore(repo)
        XCTAssertEqual(store.tintIndex(for: "Продукти"), 0)
        XCTAssertEqual(store.tintIndex(for: "Транспорт"), 1)
    }

    // MARK: renaming, merging, resetting

    /// A rename is the same category under a different word. A category that
    /// changed colour because it was renamed is this card's own defect in
    /// miniature.
    ///
    /// **The fixture has a GAP in it, and that is the whole test.** The first
    /// version used two freshly allocated categories, so the colour being
    /// carried and the colour a fresh allocation would hand out were the same
    /// number — deleting the carry entirely left it green. Wash 7 with only
    /// wash 0 otherwise taken is a state where the two answers cannot
    /// coincide: carrying gives 7, reallocating gives 1.
    func testRenamingCarriesTheColourAcross() {
        let repo = MemoryRepository()
        repo.files["categories"] = Data("""
        [{"name":"Автомобіль","tintIndex":0},{"name":"Продукти","tintIndex":7}]
        """.utf8)
        let store = makeStore(repo)
        XCTAssertEqual(store.tintIndex(for: "Продукти"), 7, "precondition: the gap is there")

        store.renameCategory("Продукти", to: "Їжа")
        XCTAssertEqual(store.tintIndex(for: "Їжа"), 7,
                       "renaming reallocated instead of carrying the colour")
    }

    /// A merge is not a rename: the surviving category is the target, and it
    /// keeps its own colour rather than adopting the one being absorbed.
    func testMergingKeepsTheTargetsColour() {
        let store = makeStore(categories: ["Автомобіль", "Продукти", "Транспорт"])
        let target = store.tintIndex(for: "Транспорт")
        store.mergeCategory("Продукти", into: "Транспорт")
        XCTAssertEqual(store.tintIndex(for: "Транспорт"), target)
        XCTAssertNil(store.categories.first(where: { $0.name == "Продукти" }))
    }

    /// A plan may name a category the store has never seen — the starter plan
    /// names «Заощадження», which the seed does not ship.
    ///
    /// **Asserts the stored field, not the rendered colour.** Checking that
    /// the three colours differ passed over a version that allocated nothing
    /// at all: an unallocated category falls through to the name hash, and
    /// three hashes are usually three different numbers. The fallback exists
    /// for a category the store does not have, and it will happily paper over
    /// one the store does.
    func testACategoryCreatedByAPlanGetsAColourToo() {
        let store = makeStore(categories: ["Автомобіль"])
        store.setBudget(Budget(incomeBase: .fixed(50_000_00),
                               lines: [.init(id: UUID(), category: "Заощадження", percent: 10),
                                       .init(id: UUID(), category: "Продукти", percent: 30)]))

        for name in ["Заощадження", "Продукти"] {
            let created = store.categories.first { $0.name == name }
            XCTAssertNotNil(created?.tintIndex, "\(name) was created without a colour")
        }
        XCTAssertEqual(Set(store.categories.compactMap { $0.tintIndex }).count, 3)
    }

    /// A reset restores the seed, and the seed ships no colours — `init` is
    /// where they are normally handed out and a reset does not run one.
    func testResettingHandsOutColoursAgain() throws {
        let store = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
        store.resetEverything()
        XCTAssertFalse(store.categories.isEmpty)
        for category in store.categories {
            XCTAssertNotNil(category.tintIndex, "\(category.name) came back from a reset colourless")
        }
        XCTAssertEqual(Set(store.categories.compactMap(\.tintIndex)).count, store.categories.count)
    }

    // MARK: a name the store does not know

    /// A row can name a category that no longer exists — an import, a restore,
    /// a file edited by hand. The feed still has to draw it.
    func testAnUnknownCategoryGetsAStableColourRatherThanACrash() {
        let store = makeStore(categories: ["Продукти"])
        let first = store.tintIndex(for: "Категорія-Привид")
        XCTAssertEqual(store.tintIndex(for: "Категорія-Привид"), first)
        XCTAssertTrue((0..<Theme.washes.count).contains(first))
    }

    /// A stored index from a build with a longer palette must fold in, not
    /// index out of bounds.
    func testAnOutOfRangeStoredIndexIsFoldedIntoThePalette() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = Data(#"[{"name":"Продукти","tintIndex":97}]"#.utf8)
        let store = makeStore(repo)
        XCTAssertEqual(store.tintIndex(for: "Продукти"), 97 % Theme.washes.count)
    }
}

// MARK: the pixel

/// Board #57, and the gap a mutation found: every test above measures the
/// store, and hardcoding `Theme.wash(0)` inside `CategorySwatch` left all of
/// them green. The store can be perfectly right about a colour no screen
/// draws.
///
/// `ImageRenderer` closes the loop by rendering the real view with the real
/// store in its environment and reading the pixel back — the whole chain from
/// a category name to what a person actually sees. It is the only test in this
/// app that asserts on a rendered pixel, which is a cost worth paying exactly
/// once, at the single point where four screens now converge.
@MainActor
final class CategorySwatchPixelTests: XCTestCase {

    private func makeStore(_ categories: [String]) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [],
                              categories: categories.map { Category(name: $0, tintIndex: nil) },
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    /// The whole rendered swatch, RGBA row-major, at 1× so a point in the
    /// grid is a point in the layout.
    ///
    /// 48pt rather than the settings list's 24: board #61 draws the icon at
    /// half the tile, and at 24pt the glyph and the margin around it are a
    /// handful of pixels each. Doubling costs nothing and leaves both regions
    /// big enough to sample without arithmetic that has to be exactly right.
    private func render(_ category: String, _ store: AppStore,
                        size: CGFloat = 48) throws -> (side: Int, rgba: [UInt8]) {
        let renderer = ImageRenderer(
            content: CategorySwatch(category, size: size, cornerRadius: 12)
                .environment(store))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "the swatch rendered to nothing")
        let cg = try XCTUnwrap(image.cgImage)

        let side = cg.width
        XCTAssertEqual(cg.height, side, "the swatch is not square")
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return (side, rgba)
    }

    private func pixel(_ shot: (side: Int, rgba: [UInt8]),
                       atFraction fx: Double, _ fy: Double) -> (Double, Double, Double) {
        let x = min(shot.side - 1, Int(Double(shot.side) * fx))
        let y = min(shot.side - 1, Int(Double(shot.side) * fy))
        let i = (y * shot.side + x) * 4
        return (Double(shot.rgba[i]) / 255,
                Double(shot.rgba[i + 1]) / 255,
                Double(shot.rgba[i + 2]) / 255)
    }

    /// A point on the WASH, deliberately off-centre.
    ///
    /// **The centre is where board #61 puts the icon**, and this test predates
    /// it: sampling the middle worked only because the fallback `tag` glyph
    /// happens to be hollow there. That is a coincidence, not a fixture, and
    /// the day somebody changed the fallback to a filled symbol this test
    /// would have failed for a reason that has nothing to do with colour.
    /// 15% in at mid-height is inside the rounded rect and well outside a
    /// half-width centred glyph.
    private func washPixel(_ category: String, _ store: AppStore) throws -> (Double, Double, Double) {
        pixel(try render(category, store), atFraction: 0.15, 0.5)
    }

    private func expected(_ index: Int) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Theme.wash(index))
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func assertClose(_ got: (Double, Double, Double), _ want: (Double, Double, Double),
                             _ message: String, line: UInt = #line) {
        let d = ((got.0 - want.0) * (got.0 - want.0)
               + (got.1 - want.1) * (got.1 - want.1)
               + (got.2 - want.2) * (got.2 - want.2)).squareRoot()
        // Generous: the point is to tell one wash from another, and the
        // nearest two are 0.19 apart. Rendering rounds to 8 bits per channel.
        XCTAssertLessThan(d, 0.05, message, line: line)
    }

    /// Two categories, two different pixels, each the wash the store allocated.
    func testTheSwatchDrawsTheColourTheStoreAllocated() throws {
        let store = makeStore(["Автомобіль", "Продукти"])
        assertClose(try washPixel("Автомобіль", store), expected(0),
                    "the swatch is not drawing Автомобіль's own wash")
        assertClose(try washPixel("Продукти", store), expected(1),
                    "the swatch is not drawing Продукти's own wash")
    }

    /// The same name, two stores that allocated it differently — so a swatch
    /// that ignores the store and hashes the name cannot pass.
    func testTheSwatchFollowsTheStoreAndNotTheName() throws {
        let first = makeStore(["Автомобіль", "Продукти"])
        let second = makeStore(["Продукти"])
        XCTAssertEqual(first.tintIndex(for: "Продукти"), 1)
        XCTAssertEqual(second.tintIndex(for: "Продукти"), 0)

        assertClose(try washPixel("Продукти", first), expected(1), "followed the name")
        assertClose(try washPixel("Продукти", second), expected(0), "followed the name")
    }
}

// MARK: the icon's pixels (board #61)

/// The same lesson as `CategorySwatchPixelTests`, one card later, and it had to
/// be learned twice: **making `CategorySwatch` draw no icon at all left every
/// board #61 test green.** They all measure the store — what icon it holds,
/// what it refuses — and the store can be perfectly right about an icon no
/// screen draws.
///
/// Asserting a *shape* is not something a test can sensibly do, so these assert
/// the two things that distinguish "an icon is there" from "an icon is not":
/// dark pixels exist on the wash, and two different icons render differently.
@MainActor
final class CategorySwatchIconPixelTests: XCTestCase {

    private func makeStore(_ categories: [String]) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [],
                              categories: categories.map { Category(name: $0, tintIndex: nil) },
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func render(_ category: String, _ store: AppStore,
                        _ scheme: ColorScheme = .light) throws -> [UInt8] {
        let renderer = ImageRenderer(
            content: CategorySwatch(category, size: 48, cornerRadius: 12)
                .environment(store)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let cg = try XCTUnwrap(try XCTUnwrap(renderer.uiImage).cgImage)
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return rgba
    }

    /// How much of the tile is drawn in something much darker than any wash.
    ///
    /// Every wash clears 4.5:1 against `Theme.swatchInk` and none is darker
    /// than the band `CategoryWashTests` pins, so "dark" here can only be the
    /// ink. A threshold, not an exact colour: the glyph is antialiased and its
    /// edge pixels are blends.
    private func inkFraction(_ rgba: [UInt8]) -> Double {
        var ink = 0, opaque = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            guard rgba[i + 3] > 200 else { continue }
            opaque += 1
            let luma = 0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1])
                     + 0.0722 * Double(rgba[i + 2])
            if luma < 90 { ink += 1 }
        }
        return opaque == 0 ? 0 : Double(ink) / Double(opaque)
    }

    /// An icon is actually drawn, in ink, on the wash.
    func testAnIconIsDrawnOnTheSwatch() throws {
        let store = makeStore(["Продукти"])
        store.setIcon("cart", for: "Продукти")
        let covered = inkFraction(try render("Продукти", store))
        XCTAssertGreaterThan(covered, 0.02, "no ink on the swatch — the icon is not being drawn")
        // And it is an icon rather than a flood fill over the colour.
        XCTAssertLessThan(covered, 0.45, "the icon has swallowed the swatch")
    }

    /// Two categories with different icons render differently. Drawing one
    /// fixed glyph everywhere, or none, fails this.
    func testTwoIconsRenderDifferently() throws {
        let store = makeStore(["Продукти", "Транспорт"])
        store.setIcon("cart", for: "Продукти")
        store.setIcon("airplane", for: "Транспорт")

        let a = try render("Продукти", store)
        let b = try render("Транспорт", store)
        XCTAssertEqual(a.count, b.count)
        let differing = zip(a, b).filter { $0 != $1 }.count
        XCTAssertGreaterThan(differing, a.count / 100,
                             "two different icons produced near-identical swatches")
    }

    /// Changing the icon changes what is drawn — the chooser's whole point.
    func testChangingTheIconChangesTheRendering() throws {
        let store = makeStore(["Продукти"])
        store.setIcon("cart", for: "Продукти")
        let before = try render("Продукти", store)
        store.setIcon("gift", for: "Продукти")
        let after = try render("Продукти", store)
        XCTAssertNotEqual(before, after)
    }

    // MARK: the dark scheme

    /// **The swatch must render IDENTICALLY in both schemes, byte for byte.**
    ///
    /// That is a stronger statement than "it has enough contrast", and it is
    /// the one the design actually makes: board #58 chose a single set of
    /// washes for both appearances, so what is drawn on them is a fixed dark
    /// ink rather than `Theme.ink`. Both colours are fixed, therefore the
    /// whole swatch is — and any drift back towards a scheme-following colour
    /// changes these bytes.
    ///
    /// The failure this catches is invisible in every light-mode screenshot:
    /// `Theme.ink` inverts to near-white, and a near-white icon on a pale wash
    /// is not a dark-mode icon, it is a missing one.
    func testTheSwatchRendersTheSameInLightAndDark() throws {
        // **The control, and it is not optional.** If `ImageRenderer` ignored
        // the `colorScheme` environment, both renders below would be identical
        // for the wrong reason and this test would pass over anything. So
        // first render something that IS scheme-dependent — `Theme.card`, one
        // of board #58's dynamic colours — and require that it differs.
        XCTAssertNotEqual(try renderControl(.light), try renderControl(.dark),
                          "ImageRenderer is not honouring the colour scheme, so "
                          + "the comparison below proves nothing")

        let store = makeStore(["Продукти"])
        store.setIcon("cart", for: "Продукти")
        XCTAssertEqual(try render("Продукти", store, .light),
                       try render("Продукти", store, .dark),
                       "the swatch follows the colour scheme; on dark the icon disappears")
    }

    /// A plain fill in a colour that DOES follow the scheme. Only ever used to
    /// prove the test above can fail.
    private func renderControl(_ scheme: ColorScheme) throws -> [UInt8] {
        let renderer = ImageRenderer(
            content: Rectangle().fill(Theme.card).frame(width: 8, height: 8)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let cg = try XCTUnwrap(try XCTUnwrap(renderer.uiImage).cgImage)
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return rgba
    }

    /// And it is still ink on dark — measured, not inferred from the equality
    /// above, so that a swatch which rendered blank in BOTH schemes could not
    /// pass by being consistently wrong.
    func testTheIconIsStillDrawnInTheDarkScheme() throws {
        let store = makeStore(["Продукти"])
        store.setIcon("cart", for: "Продукти")
        let covered = inkFraction(try render("Продукти", store, .dark))
        XCTAssertGreaterThan(covered, 0.02, "no ink on the swatch in the dark scheme")
        XCTAssertLessThan(covered, 0.45)
    }

    /// The fallback too — the state every category on every phone is in until
    /// somebody chooses.
    func testTheFallbackIconIsDrawnInTheDarkSchemeToo() throws {
        let store = makeStore(["Ялинка"])
        XCTAssertNil(store.categories.first?.icon)
        XCTAssertGreaterThan(inkFraction(try render("Ялинка", store, .dark)), 0.02,
                             "a category with no icon rendered blank on dark")
    }

    /// A category with no icon draws the fallback, which is a real symbol and
    /// therefore real ink — not a bare colour.
    func testACategoryWithNoIconStillDrawsSomething() throws {
        let store = makeStore(["Ялинка"])
        XCTAssertNil(store.categories.first?.icon)
        XCTAssertGreaterThan(inkFraction(try render("Ялинка", store)), 0.02,
                             "a category with no icon rendered as a bare colour")
    }
}
