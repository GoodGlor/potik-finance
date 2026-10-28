import XCTest
@testable import MonitorFinance

final class CategoryEditTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func tx(_ day: Int, _ category: String, _ merchant: String = "Гастроном-Приклад",
                    resolution: Resolution = .rule) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!,
                    kind: .expense, category: category, merchant: merchant, amount: -10_000,
                    cardSuffix: "*0000", bankId: "monobank", receiptId: nil, splits: [],
                    resolution: resolution, suggestions: [])
    }

    private func store(_ txs: [Transaction], categories: [String]) throws -> AppStore {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(), keychain: keychain)
        s.transactions = txs
        s.categories = categories.map { Category(name: $0, tintIndex: nil) }
        s.rules = []
        return s
    }

    func testRecentCategoriesAreTheLastFiveDistinctNewestFirst() throws {
        // The repeat ("Д" on days 7 and 5) sits INSIDE the newest five, so the
        // dedup guard is what stops it appearing twice. An earlier fixture put
        // the repeat at the oldest row, where the loop had already broken at
        // five and the guard was never reached — it constrained nothing.
        let s = try store([tx(1, "А", resolution: .user), tx(2, "Б", resolution: .user),
                           tx(3, "В", resolution: .user), tx(4, "Г", resolution: .user),
                           tx(5, "Д", resolution: .user), tx(6, "Е", resolution: .user),
                           tx(7, "Д", resolution: .user)],
                          categories: ["А", "Б", "В", "Г", "Д", "Е"])

        XCTAssertEqual(s.recentCategories, ["Д", "Е", "Г", "В", "Б"],
                       "newest first, deduplicated, capped at five")
        XCTAssertEqual(Set(s.recentCategories).count, s.recentCategories.count,
                       "no category may appear twice")
    }

    /// Board #12. «Нещодавні» means "what YOU reach for", and it used to be
    /// filled by rows nobody had looked at — on a fresh install it offered five
    /// categories off the demo's newest rows, «Інші надходження» among them,
    /// which is not a thing anyone picks for a purchase.
    ///
    /// `.rule` is excluded as well as `.pattern`: a rule descends from a real
    /// answer, but the row it settled was never shown to anybody, and one
    /// answered merchant should not crowd out four categories chosen by hand.
    func testRecentCategoriesCountOnlyWhatThePersonChose() throws {
        let s = try store([tx(1, "А", resolution: .rule), tx(2, "Б", resolution: .pattern),
                           tx(3, "В", resolution: .pending), tx(4, "Г", resolution: .skipped)],
                          categories: ["А", "Б", "В", "Г", "Д"])
        XCTAssertEqual(s.recentCategories, [], "nobody has picked anything yet")

        s.transactions.append(tx(5, "Д", resolution: .user))
        XCTAssertEqual(s.recentCategories, ["Д"], "one tap, one recent")
    }

    /// And the seed's own half, which is what the card actually complained
    /// about: a phone whose owner has just installed the app offers nothing
    /// under «Нещодавні», so the picker shows «Популярні» instead.
    func testAFreshInstallHasNoRecentsAtAll() throws {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: keychain)
        XCTAssertEqual(s.recentCategories, [],
                       "the demo may show a filled-in app; it may not put words in its owner's mouth")
    }

    func testAddCategoryIsIdempotent() throws {
        let s = try store([], categories: ["Продукти"])
        s.addCategory("Продукти", kind: .spending)
        s.addCategory("Нова", kind: .spending)
        XCTAssertEqual(s.categories.map(\.name).sorted(), ["Нова", "Продукти"])
    }

    func testAddCategoryTrimsAndIgnoresBlanks() throws {
        let s = try store([], categories: [])
        s.addCategory("  Подарунки  ", kind: .spending)
        s.addCategory("   ", kind: .spending)
        XCTAssertEqual(s.categories.map(\.name), ["Подарунки"])
    }

    // MARK: the create-vs-duplicate rule

    func testCreateIsOfferedOnlyWhenNothingMatches() {
        let all = ["Продукти", "Комуналка"]
        XCTAssertEqual(CategoryPicker.creatableName(for: "Подарунки", in: all), "Подарунки",
                       "nothing matches, so creating is the only way forward")
        XCTAssertNil(CategoryPicker.creatableName(for: "Прод", in: all),
                     "«Продукти» is visible one row above — offering «Прод» splits its history")
        XCTAssertNil(CategoryPicker.creatableName(for: "продукти", in: all),
                     "an exact match differing only in case is still a match")
        XCTAssertNil(CategoryPicker.creatableName(for: "   ", in: all),
                     "a blank query is not a name")
    }

    func testCreateTrimsBeforeOffering() {
        XCTAssertEqual(CategoryPicker.creatableName(for: "  Подарунки  ", in: ["Продукти"]),
                       "Подарунки")
    }

    func testMatchingIsSubstringAndCaseInsensitiveAndBlankIsNoFilter() {
        let all = ["Продукти", "Комуналка"]
        XCTAssertEqual(CategoryPicker.matching("кому", in: all), ["Комуналка"])
        XCTAssertEqual(CategoryPicker.matching("КОМУ", in: all), ["Комуналка"])
        XCTAssertEqual(CategoryPicker.matching("  ", in: all), all)
    }

    func testRenameMovesEveryRowAndTheRuleWithIt() throws {
        let s = try store([tx(1, "Продукти"), tx(2, "Пальне")], categories: ["Продукти", "Пальне"])
        s.rules = [Rule(merchantKey: "сільпо", category: "Продукти", ambiguous: false)]
        s.renameCategory("Продукти", to: "Їжа")

        XCTAssertEqual(s.transactions.filter { $0.category == "Їжа" }.count, 1)
        XCTAssertFalse(s.categories.contains { $0.name == "Продукти" })
        XCTAssertTrue(s.categories.contains { $0.name == "Їжа" })
        XCTAssertEqual(s.rules.first?.category, "Їжа",
                       "a rule pointing at the old name would silently re-categorise rows later")
    }

    func testRenameOntoAnExistingNameMergesInsteadOfDuplicating() throws {
        let s = try store([tx(1, "Продукти"), tx(2, "Їжа")], categories: ["Продукти", "Їжа"])
        s.renameCategory("Продукти", to: "Їжа")
        XCTAssertEqual(s.categories.map(\.name), ["Їжа"], "no duplicate category may survive")
        XCTAssertEqual(s.transactions.filter { $0.category == "Їжа" }.count, 2)
    }

    func testMergeMovesRowsAndDropsTheSource() throws {
        let s = try store([tx(1, "Кафе"), tx(2, "Ресторани"), tx(3, "Пальне")],
                          categories: ["Кафе", "Ресторани", "Пальне"])
        s.mergeCategory("Ресторани", into: "Кафе")
        XCTAssertEqual(s.transactions.filter { $0.category == "Кафе" }.count, 2)
        XCTAssertFalse(s.categories.contains { $0.name == "Ресторани" })
    }

    func testDeleteReassignsItsRowsToInshe() throws {
        let s = try store([tx(1, "Дивне"), tx(2, "Пальне")], categories: ["Дивне", "Пальне"])
        s.deleteCategory("Дивне")
        XCTAssertEqual(s.transactions.filter { $0.category == "Інше" }.count, 1,
                       "rows are never left pointing at a category that no longer exists")
        XCTAssertTrue(s.categories.contains { $0.name == "Інше" },
                      "the fallback category must exist after it is used")
        XCTAssertFalse(s.categories.contains { $0.name == "Дивне" })
    }

    func testExportContainsTransactionsAndNoSecrets() throws {
        let s = try store([tx(1, "Продукти")], categories: ["Продукти"])
        try s.keychain.setString("super-secret-token", for: "token.monobank")
        let text = String(decoding: try s.exportJSON(), as: UTF8.self)

        XCTAssertTrue(text.contains("Продукти"))
        XCTAssertTrue(text.contains("transactions"))
        XCTAssertFalse(text.contains("super-secret-token"),
                       "an export the user can mail themselves must never carry a bank token")
    }

    /// The only irreversible action in the app. A reset that half-works —
    /// storage gone but still "onboarded", or a PIN that survives — is worse
    /// than one that fails outright, because the next launch looks fine.
    func testResetEverythingReturnsTheStoreToAFreshInstall() throws {
        let s = try store([tx(1, "Дивне")], categories: ["Дивне"])
        try s.setPin("4321")
        s.settings.onboarded = true
        s.isUnlocked = true
        s.rules = [Rule(merchantKey: "сільпо", category: "Дивне", ambiguous: false)]
        s.persistNow()

        s.resetEverything()

        XCTAssertFalse(s.settings.onboarded, "a reset app must onboard again")
        XCTAssertFalse(s.isUnlocked, "a reset app must be locked")
        XCTAssertFalse(s.isPinSet, "the PIN must not survive a reset")
        XCTAssertEqual(s.transactions.count, 62, "the seed is reloaded, not left empty")
        XCTAssertEqual(s.categories.count, 19)
        XCTAssertNil(s.budget)
        XCTAssertFalse(s.rules.contains { $0.merchantKey == "сільпо" },
                       "the user's own rules go with everything else")
    }

    /// `keychain.wipe()` already removes the PIN itself, so this covers the
    /// part only `pinStore.clear()` does: the lockout counters live in
    /// UserDefaults, and a reset that leaves them hands the user a fresh app
    /// that is still refusing a PIN nobody has set.
    func testResetClearsTheLockoutState() throws {
        // A private defaults suite — PinStore's default is UserDefaults.standard,
        // and a test that writes lockout counters there leaks into every other
        // test in the process.
        let suiteName = "ua.monitorfinance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pin = PinStore(keychain: keychain, defaults: defaults)
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: keychain, pinStore: pin)
        try s.setPin("4321")
        for _ in 0..<PinStore.maxFailures { _ = s.verifyPin("0000") }
        XCTAssertNotNil(s.pinStore.lockedUntil, "five wrong attempts must lock the keypad")

        s.resetEverything()

        XCTAssertNil(s.pinStore.lockedUntil,
                     "a reset app must not still be serving a lockout")
        XCTAssertEqual(s.pinStore.failedAttempts, 0)
    }

    /// Board #94. What an income row creates must BE income — a spending
    /// category made from an income row is the split the picker used to
    /// refuse creation to avoid.
    func testACategoryCreatedForIncomeIsEarned() throws {
        let s = try store([], categories: [])
        s.addCategory("Фріланс", kind: .earned)
        XCTAssertEqual(s.categories.first { $0.name == "Фріланс" }?.kind, .earned)
        XCTAssertTrue(BudgetMath.earnedCategories(s.categories).contains("Фріланс"))
    }

    /// Changing a kind re-bases EVERY month, not only the ones after it — the
    /// warning on the sheet says so, and this is the behaviour it warns about.
    /// Asserted through `BudgetMath.income` rather than through the field
    /// alone: a setter that stored the kind and left the budget reading the
    /// old answer would pass a field check.
    func testChangingAKindRebasesMonthsAlreadyPast() throws {
        let july = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00+03:00")!
        let row = Transaction(id: UUID(), date: july, kind: .income, category: "Фріланс",
                              merchant: "Фріланс", amount: 10_000_00, cardSuffix: "*0000",
                              bankId: "monobank", receiptId: nil, splits: [],
                              resolution: .user, suggestions: [])
        let s = try store([row], categories: ["Фріланс"])
        // A category made before the field resolves through the legacy table,
        // so it starts as spending and the month counts no earnings at all.
        XCTAssertEqual(BudgetMath.income([row], includeGifts: false, categories: s.categories), 0)

        s.setCategoryKind("Фріланс", .earned)
        XCTAssertEqual(s.categories.first { $0.name == "Фріланс" }?.kind, .earned)
        XCTAssertEqual(BudgetMath.income([row], includeGifts: false, categories: s.categories),
                       10_000_00, "July is already past, and it re-bases too")
    }

    /// A kind is a fact about the CATEGORY, not about the rows in it.
    func testChangingAKindTouchesNoTransaction() throws {
        let july = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00+03:00")!
        let row = Transaction(id: UUID(), date: july, kind: .income, category: "Фріланс",
                              merchant: "Фріланс", amount: 10_000_00, cardSuffix: "*0000",
                              bankId: "monobank", receiptId: nil, splits: [],
                              resolution: .user, suggestions: [])
        let s = try store([row], categories: ["Фріланс"])
        let before = s.transactions
        s.setCategoryKind("Фріланс", .earned)
        XCTAssertEqual(s.transactions, before)
    }

    /// The invariant board #94 made reachable for the first time. Every mapper
    /// lands income it has not been told about in `defaultIncomeCategory`, and
    /// `BudgetMath` requires it to be earned — so making it spending would
    /// have every synced income row count on Головна (which reads the sign)
    /// and contribute nothing in Бюджет (which reads the category), while the
    /// income picker stopped offering the very category those rows are in.
    func testTheDefaultIncomeCategoryCannotBeMadeSpending() throws {
        let name = BudgetMath.defaultIncomeCategory
        let s = try store([], categories: [name])
        s.setCategoryKind(name, .earned)
        XCTAssertEqual(s.categories.first { $0.name == name }?.kind, .earned)

        s.setCategoryKind(name, .spending)
        XCTAssertEqual(s.categories.first { $0.name == name }?.kind, .earned,
                       "the refusal is the store's, not only the screen's")
        s.setCategoryKind(name, .unearned)
        XCTAssertEqual(s.categories.first { $0.name == name }?.kind, .earned,
                       "a gift is income, but the plan still has to be built on this one")

        // …and no OTHER category is caught by the guard.
        s.addCategory("Фріланс", kind: .earned)
        s.setCategoryKind("Фріланс", .spending)
        XCTAssertEqual(s.categories.first { $0.name == "Фріланс" }?.kind, .spending)
    }
}
