import XCTest
@testable import MonitorFinance

/// Board #114 — the budget can be scoped to some banks.
///
/// **The model, and the alternative it beat.** One plan with a bank scope, not
/// a plan per bank. Separate plans would multiply every board #94 concept —
/// income base, category kinds, the month a plan belongs to — by the number of
/// banks, and leave somebody owning N plans that can disagree about what a
/// month's income was.
///
/// A scope is therefore a FILTER on the rows a plan is measured against, and
/// nothing else. That is what keeps the card's third box: `BudgetMath` stays
/// kind-driven, because the filter is applied to the transactions before they
/// reach it and no function in that file asks which bank a row came from.
@MainActor
final class BudgetScopeTests: XCTestCase {

    /// An ISO-stamped Kyiv-offset instant, `BudgetMathTests`' idiom, so a
    /// fixture never lands near a month boundary by accident. The merchant is
    /// invented — the privacy guard scans this target.
    private func tx(_ bank: String, _ category: String, _ amount: Int,
                    _ kind: TxKind = .expense, _ iso: String = "2026-08-05T12:00:00+03:00")
        -> Transaction {
        Transaction(id: UUID(), date: ISO8601DateFormatter().date(from: iso)!, kind: kind,
                    category: category, merchant: "Продавець-Приклад", amount: amount,
                    cardSuffix: "*0000", bankId: bank, receiptId: nil, splits: [],
                    resolution: .rule, suggestions: [])
    }

    private let august = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00+03:00")!
    private let september = ISO8601DateFormatter().date(from: "2026-09-03T10:00:00+03:00")!

    private func plan(banks: [String]?, month: MonthKey? = nil) -> Budget {
        Budget(incomeBase: .fixed(100_000),
               lines: [.init(id: UUID(), category: "Продукти", percent: 50)],
               month: month, banks: banks)
    }

    // MARK: - the filter

    /// **The defect this exists to prevent**: a plan about one bank measured
    /// against every bank's spending.
    func testAScopedPlanCountsOnlyItsOwnBanks() {
        let rows = [tx("monobank", "Продукти", -10_000),
                    tx("privatbank", "Продукти", -30_000)]
        let month = MonthKey(august)
        let all = BudgetMath.report(plan(banks: nil), txs: rows, month: month,
                                    now: august, categories: [])
        let scoped = BudgetMath.report(plan(banks: ["monobank"]), txs: rows,
                                       month: month, now: august, categories: [])
        XCTAssertEqual(all.rows.first?.actual, 40_000)
        XCTAssertEqual(scoped.rows.first?.actual, 10_000,
                       "a plan about monobank must not count PrivatBank's spending")
    }

    /// `nil` and `[]` both mean everything. An empty scope would measure a
    /// month against nothing, which reads as a broken screen rather than a
    /// choice — the editor disables saving one, and this is the belt.
    func testNoScopeAndAnEmptyScopeBothMeanEverything() {
        let rows = [tx("monobank", "Продукти", -10_000),
                    tx("privatbank", "Продукти", -30_000)]
        XCTAssertEqual(plan(banks: nil).scoped(rows).count, 2)
        XCTAssertEqual(plan(banks: []).scoped(rows).count, 2)
    }

    /// **A fixed income is a number somebody typed**, and quietly shrinking it
    /// because they later scoped the plan would change an answer they gave.
    /// Only an averaged income follows the scope.
    func testAFixedIncomeIsNotScopedButAnAveragedOneIs() {
        let income = [tx("monobank", "Зарплата", 60_000, .income, "2026-08-01T12:00:00+03:00"),
                      tx("privatbank", "Зарплата", 40_000, .income, "2026-08-01T12:00:00+03:00")]
        let now = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00+03:00")!
        // `income(_:includeGifts: false)` counts only EARNED categories, so
        // without this the averages are both zero and the assertion would
        // pass against a scope that does nothing.
        let earned = [Category(name: "Зарплата", tintIndex: 0, kind: .earned)]

        var fixed = plan(banks: ["monobank"])
        fixed.incomeBase = .fixed(100_000)
        XCTAssertEqual(BudgetMath.monthlyIncome(fixed, txs: income, now: now,
                                                categories: earned),
                       100_000, "a typed number is the number they meant")

        var averaged = plan(banks: ["monobank"])
        averaged.incomeBase = .average(months: 1, includeGifts: false)
        let scopedAverage = BudgetMath.monthlyIncome(averaged, txs: income, now: now,
                                                     categories: earned)
        var everything = averaged
        everything.banks = nil
        let wholeAverage = BudgetMath.monthlyIncome(everything, txs: income, now: now,
                                                    categories: earned)
        XCTAssertGreaterThan(wholeAverage, 0, "the fixture must produce a real average")
        XCTAssertLessThan(scopedAverage, wholeAverage,
                          "an averaged income must come from the same cards the plan counts")
    }

    /// **The loudest possible way to get a scope wrong.** `pushedOverPlan`
    /// raises the over-plan alert, so a purchase on a bank the plan is not
    /// about must not be able to trigger one.
    func testAPurchaseOutsideTheScopeCannotPushThePlanOver() {
        let rows = [tx("monobank", "Продукти", -49_000),
                    tx("privatbank", "Продукти", -49_000, .expense,
                       "2026-08-06T12:00:00+03:00")]
        let scoped = plan(banks: ["monobank"])
        let outside = rows[1]
        XCTAssertNil(BudgetMath.pushedOverPlan(outside, budget: scoped, txs: rows,
                                               now: august, categories: []),
                     "a bank the plan is not about cannot push it over")
    }

    // MARK: - when it takes effect

    /// **The owner's decision, and the reason for it**: a half-spent month has
    /// a plan somebody already made decisions against, so narrowing it now
    /// would rewrite what those decisions were measured by.
    ///
    /// It needs almost no machinery because board #62 already built it — a new
    /// plan stamped one month on, and `plan(for:)` picks whichever applies
    /// without knowing this feature exists.
    func testAScopeChangeLeavesThisMonthAlone() {
        let store = makeStore()
        store.setBudget(plan(banks: nil), now: august)

        store.setBudgetScope(["monobank"], now: august)

        XCTAssertNil(store.plan(for: MonthKey(year: 2026, month: 8))?.banks,
                     "this month keeps the plan its decisions were made against")
        XCTAssertEqual(store.plan(for: MonthKey(year: 2026, month: 9))?.banks, ["monobank"],
                       "…and the change lands next month")
    }

    /// The screen has to be able to say a change is pending, for the whole
    /// month the cost is being paid — saying it once inside a sheet somebody
    /// has closed is saying it to nobody.
    func testAPendingScopeIsReportedUntilItLands() {
        let store = makeStore()
        store.setBudget(plan(banks: nil), now: august)
        XCTAssertNil(store.pendingBudgetScope(now: august), "nothing pending yet")

        store.setBudgetScope(["monobank"], now: august)
        XCTAssertEqual(store.pendingBudgetScope(now: august), .some(["monobank"]))

        // Once September arrives the change IS the plan, so there is nothing
        // pending any more and the screen must go quiet.
        XCTAssertNil(store.pendingBudgetScope(now: september),
                     "a change that has landed is not a change that is coming")
    }

    /// A plan already on somebody's phone predates this field and decodes to
    /// "all banks" — which is exactly what it has always meant. The same
    /// argument `Budget.month` makes for its own `nil`.
    func testAPlanWrittenBeforeScopesExistedCountsEveryBank() throws {
        let json = Data(#"{"incomeBase":{"fixed":{"_0":50000}},"lines":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Budget.self, from: json)
        XCTAssertNil(decoded.banks)
        XCTAssertEqual(decoded.scoped([tx("monobank", "Продукти", -1)]).count, 1)
    }

    // MARK: - what the screen says

    /// **Named banks, never «2 банки»** — a count would make somebody open the
    /// sheet to find out which two.
    func testTheScopeLineNamesTheBanks() {
        let store = makeStore()
        // Named explicitly: a fresh store follows the DEVICE language, and the
        // simulator this suite runs on is English — so asserting a Ukrainian
        // string without saying so would be asserting the simulator's setting.
        store.setLanguage(.uk)
        XCTAssertEqual(BudgetView.scopeLabel(nil, store: store), "Усі банки")
        let named = BudgetView.scopeLabel(["monobank"], store: store)
        XCTAssertFalse(named.isEmpty)
        XCTAssertNotEqual(named, "Усі банки")
    }

    /// A scope naming a bank that is no longer connected still has to read as
    /// something. Falling back to the id keeps the line honest rather than
    /// quietly shortening it to the banks that survived.
    func testAScopeNamingAnUnknownBankStillReads() {
        let store = makeStore()
        store.setLanguage(.uk)
        XCTAssertEqual(BudgetView.scopeLabel(["bank-that-left"], store: store),
                       "bank-that-left")
    }

    private func makeStore() -> AppStore {
        var seed = try! SeedLoader.load()
        seed.transactions = []; seed.receipts = []; seed.rules = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"),
                        pinStore: PinStore(keychain: Keychain(
                            service: "ua.monitorfinance.tests.\(UUID().uuidString)")))
    }
}
