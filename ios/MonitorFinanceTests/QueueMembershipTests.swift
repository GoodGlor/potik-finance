import XCTest
@testable import MonitorFinance

@MainActor
final class QueueMembershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func tx(_ merchant: String, _ amount: Int, days: Int = 0,
                    resolution: Resolution = .pending,
                    suggestions: [String] = [],
                    bankId: String = "monobank") -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: amount > 0 ? .income : .expense,
                    category: amount > 0 ? BudgetMath.defaultIncomeCategory : "",
                    merchant: merchant, amount: amount, cardSuffix: "*1111",
                    bankId: bankId, receiptId: nil, splits: [],
                    resolution: resolution, suggestions: suggestions,
                    externalId: UUID().uuidString, hold: false)
    }

    /// A row shaped like the ones `PrivatMapper` produces — the ONLY kind that
    /// earns the «Приват: …» chip.
    private func privatTx(_ merchant: String, _ amount: Int,
                          suggestions: [String] = []) -> Transaction {
        tx(merchant, amount, suggestions: suggestions, bankId: PrivatMapper.bankId)
    }

    private func store(_ rows: [Transaction]) -> AppStore {
        var seed = try! SeedLoader.load()
        seed.transactions = rows; seed.receipts = []; seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    func testRowsAreGroupedByMerchantCaseInsensitively() {
        let s = store([tx("Крамниця-Приклад", -100_00), tx("крамниця-приклад ", -200_00), tx("Маркет-Приклад", -50_00)])
        XCTAssertEqual(s.pendingGroups.count, 2)
        XCTAssertEqual(s.pendingGroups[0].key, MerchantKey.normalize("Крамниця-Приклад"))
        XCTAssertEqual(s.pendingGroups[0].count, 2)
        XCTAssertEqual(s.pendingGroups[0].total, 300_00)
    }

    /// "Biggest first" means by money, which is what a person means when they
    /// look at their own spending. Ordering by COUNT would put a daily coffee
    /// above a rent payment.
    func testGroupsAreOrderedByMoneyNotByCount() {
        let s = store([tx("Кава", -30_00), tx("Кава", -30_00), tx("Кава", -30_00),
                       tx("Оренда", -900_00)])
        XCTAssertEqual(s.pendingGroups.map(\.merchant), ["Оренда", "Кава"])
    }

    func testTheKeyBreaksTiesSoTheOrderIsStableAcrossLaunches() {
        let s = store([tx("Б", -100_00), tx("А", -100_00)])
        XCTAssertEqual(s.pendingGroups.map(\.merchant), ["А", "Б"])
    }

    func testOnlyPendingRowsAreAskedAbout() {
        let s = store([tx("Крамниця-Приклад", -100_00), tx("Маркет-Приклад", -100_00, resolution: .user)])
        XCTAssertEqual(s.pendingGroups.map(\.merchant), ["Крамниця-Приклад"])
    }

    func testIncomeAndExpenseAreSeparateGroupsEvenForOneMerchant() {
        let s = store([tx("Робота", 2_500_00), tx("Робота", -100_00)])
        XCTAssertEqual(s.pendingGroups.count, 2)
        XCTAssertEqual(Set(s.pendingGroups.map(\.kind)), [.income, .expense])
        // Board #55's second collision, which the card did not name: two
        // cards, one `key`. The view keyed its accessibility identifier on
        // `key`, so «Робота» named both of them.
        XCTAssertEqual(Set(s.pendingGroups.map(\.key)).count, 1, "same merchant")
        XCTAssertEqual(Set(s.pendingGroups.map(\.id)).count, 2, "…and still two cards")
    }

    /// Board #55. `id` is what the queue's accessibility identifier is built
    /// from, so a duplicate is a card no test can name. Asserted over the
    /// shapes that produce more than one card for a merchant, together:
    /// thirty-five rows of a generic merchant, and one merchant that both
    /// paid and charged.
    ///
    /// The merchant is invented rather than the seed's own: it only has to
    /// match `GenericMerchant`, and a real one may not be written into source.
    func testEveryGroupsIdentityIsItsOwn() {
        XCTAssertTrue(GenericMerchant.matches("Переказ-Приклад"), "precondition")
        var rows = (0..<35).map { tx("Переказ-Приклад", -(100_00 + $0)) }
        rows += [tx("Робота", 2_500_00), tx("Робота", -100_00)]
        rows += [tx("Крамниця-Приклад", -50_00), tx("Крамниця-Приклад", -60_00)]
        let groups = AppStore.groups(rows)

        XCTAssertEqual(groups.count, 35 + 2 + 1, "the shapes this test claims to cover")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count,
                       "two cards sharing an id share an accessibility identifier")
        XCTAssertLessThan(Set(groups.map(\.key)).count, groups.count,
                          "…and the keys DO collide, which is why `id` had to be used")
    }

    /// The whole point of the redesign: no date window. A backfilled year is
    /// answerable, not buried behind an arbitrary line.
    func testAnOldPurchaseIsStillAskedAbout() {
        let s = store([tx("Крамниця-Приклад", -100_00, days: 300)])
        XCTAssertEqual(s.pendingGroups.count, 1)
        XCTAssertEqual(s.queuedGroups.count, 1)
    }

    func testTheCapCountsGroupsAndKeepsTheBiggest() {
        let rows = (0..<40).map { tx("Магазин \($0)", -(1000 - $0) * 100) }
        let s = store(rows)
        XCTAssertEqual(s.pendingGroups.count, 40)
        XCTAssertEqual(s.queuedGroups.count, AppStore.queueCap)
        XCTAssertEqual(s.queuedGroups.first?.merchant, "Магазин 0")
        XCTAssertFalse(s.queuedGroups.contains { $0.merchant == "Магазин 39" })
    }

    /// The coverage line is computed, never written. A hardcoded 69% would be
    /// wrong for everyone but the owner.
    func testCoverageIsTheShownMoneyOverAllOfIt() {
        let s = store([tx("А", -900_00), tx("Б", -100_00)])
        XCTAssertEqual(s.coverageShare, 1.0, accuracy: 0.0001)
        let many = store((0..<40).map { tx("М\($0)", -100_00) })
        XCTAssertEqual(many.coverageShare, 30.0 / 40.0, accuracy: 0.0001)
    }

    func testCoverageIsZeroRatherThanNaNWhenThereIsNothingToAskAbout() {
        XCTAssertEqual(store([]).coverageShare, 0)
    }

    func testConfirmingAGroupResolvesEveryRowInItAtOnce() {
        let s = store([tx("Крамниця-Приклад", -100_00), tx("Крамниця-Приклад", -200_00), tx("Маркет-Приклад", -50_00)])
        let group = s.pendingGroups.first { $0.merchant == "Крамниця-Приклад" }!
        XCTAssertEqual(s.confirmGroup(group, as: .category("Продукти")), 2)
        XCTAssertEqual(s.transactions.filter { $0.category == "Продукти" }.count, 2)
        XCTAssertEqual(s.pendingGroups.map(\.merchant), ["Маркет-Приклад"])
    }

    func testConfirmingAGroupAsNotAnExpenseTypesThemAllAsTransfers() {
        let s = store([tx("Крамниця-Приклад", -500_00), tx("крамниця-приклад", -300_00)])
        let group = s.pendingGroups[0]
        XCTAssertEqual(s.confirmGroup(group, as: .notAnExpense), 2)
        XCTAssertTrue(s.transactions.allSatisfy { $0.kind == .transfer })
        XCTAssertTrue(s.pendingGroups.isEmpty)
    }

    func testTheUncategorisedLabelIsPinnedOnce() {
        XCTAssertEqual(Derived.uncategorised, "Без категорії")
        let s = store([tx("Крамниця-Приклад", -100_00)])
        XCTAssertEqual(Derived.byCategory(s.transactions).first?.name, Derived.uncategorised)
    }

    // MARK: suggestion chip

    func testGroupSuggestionIsTheDominantPrivatCategory() {
        let s = store([privatTx("Крамниця-Хвіст", -100_00, suggestions: ["Тварини"]),
                       privatTx("Крамниця-Хвіст", -100_00, suggestions: ["Тварини"]),
                       privatTx("Крамниця-Хвіст", -100_00, suggestions: ["Ветаптека"])])
        XCTAssertEqual(s.pendingGroups.first?.suggestion, "Тварини")
    }

    func testAMonobankGroupHasNoSuggestion() {
        let s = store([tx("Маркет-Приклад", -100_00)])
        XCTAssertNil(s.pendingGroups.first?.suggestion)
    }

    /// The chip is labelled «Приват: …», so a row from any OTHER bank must
    /// never produce one — however the row got its `suggestions`.
    ///
    /// This is not hypothetical. The bundled seed ships 66 monobank rows
    /// carrying a legacy three-category `suggestions` array, and the chip's
    /// first version tallied every row regardless of bank: a fresh install
    /// showed «Приват: Продукти» on monobank purchases, all green, until the
    /// queue was looked at on a simulator. The old test above only proved
    /// that an EMPTY suggestions array yields no chip, which is why it
    /// stayed green throughout.
    func testAMonobankRowsOwnSuggestionsNeverEarnThePrivatChip() {
        let s = store([tx("Маркет-Приклад", -100_00, suggestions: ["Продукти", "Комуналка"]),
                       tx("Маркет-Приклад", -200_00, suggestions: ["Продукти"])])
        XCTAssertNil(s.pendingGroups.first?.suggestion,
                     "«Приват: …» must not appear on a monobank row that happens to carry suggestions")
    }

    /// The seed itself, not a hand-built row: whatever ships in the app must
    /// not light up the chip before the user has imported anything.
    func testTheBundledSeedProducesNoPrivatChip() throws {
        let seed = try SeedLoader.load()
        let carriers = seed.transactions.filter { !$0.suggestions.isEmpty }
        XCTAssertFalse(carriers.isEmpty,
                       "precondition: the seed must still carry suggestion-bearing rows, "
                       + "otherwise this test proves nothing")
        XCTAssertTrue(carriers.allSatisfy { $0.bankId != PrivatMapper.bankId },
                      "precondition: none of them are Privat rows")
        XCTAssertTrue(AppStore.groups(seed.transactions).allSatisfy { $0.suggestion == nil },
                      "the shipped seed must not render a PrivatBank chip on anyone's queue")
    }

    /// A tied tally must pick the same winner regardless of how the rows
    /// happened to be inserted — a dictionary's iteration order is not
    /// stable across launches, and this codebase already had to fix exactly
    /// that bug once for group ordering itself.
    ///
    /// Two tied keys catch an INVERTED comparator every run, but catch an
    /// ABSENT one (a bare `max(by:)` with no tie-break at all, which keeps
    /// whichever key it happens to encounter first) only about half the
    /// time — a dictionary of two keys iterates in one of two orders, and an
    /// absent tie-break passes whenever iteration happens to put the
    /// alphabetically-smallest key first anyway. Six tied categories drop
    /// that false-pass rate to roughly 1/6: only one of the six iteration
    /// orders that happens to start with the smallest key would slip past a
    /// tie-break that was never applied.
    func testATiedTallyBreaksDeterministicallyByCategoryName() {
        let names = ["Дельта", "Альфа", "Епсилон", "Гамма", "Бета", "Дзета"]
        let s = store(names.map { privatTx("Крамниця-Приклад", -100_00, suggestions: [$0]) })
        XCTAssertEqual(s.pendingGroups.first?.suggestion, "Альфа")
    }

    func testAcceptSuggestionConfirmsAndCreatesTheCategory() {
        let s = store([privatTx("Крамниця-Хвіст", -100_00, suggestions: ["Ветаптека"]),
                       privatTx("Крамниця-Хвіст", -200_00, suggestions: ["Ветаптека"])])
        let group = s.pendingGroups[0]
        let changed = s.acceptSuggestion(group)
        XCTAssertEqual(changed, 2)
        XCTAssertTrue(s.categories.contains { $0.name == "Ветаптека" },
                      "a Privat category the user never had must exist after accepting it")
        XCTAssertTrue(s.transactions.allSatisfy { $0.resolution != .pending })
        XCTAssertEqual(s.rules.first { $0.merchantKey == MerchantKey.normalize("Крамниця-Хвіст") }?.category,
                       "Ветаптека", "accepting teaches the same rule the picker does")
    }
}
