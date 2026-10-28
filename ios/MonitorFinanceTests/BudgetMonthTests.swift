import XCTest
@testable import MonitorFinance

/// Board #62. A plan belongs to a month, and each month it is carried over or
/// rewritten.
///
/// There used to be exactly one plan. Browsing back to March measured March
/// against whatever the person had last written — possibly in August, possibly
/// nothing like what they were actually living under at the time.
@MainActor
final class BudgetMonthTests: XCTestCase {

    private let july = MonthKey(year: 2026, month: 7)
    private let august = MonthKey(year: 2026, month: 8)
    private let september = MonthKey(year: 2026, month: 9)

    private func date(_ month: MonthKey, day: Int = 15) -> Date {
        Calendar.kyiv.date(from: DateComponents(
            year: month.year, month: month.month, day: day, hour: 12))!
    }

    private func makeStore(_ repository: Repository = MemoryRepository()) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [], categories: [],
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func plan(_ percent: Double, _ category: String = "Продукти") -> Budget {
        Budget(incomeBase: .fixed(50_000_00),
               lines: [.init(id: UUID(), category: category, percent: percent)])
    }

    // MARK: a plan knows its month

    func testAPlanIsStampedWithTheMonthItWasWrittenIn() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        XCTAssertEqual(store.budget?.month, august)
    }

    /// The migration, and the one that matters: a plan already on a phone has
    /// no month, and must go on measuring every month exactly as it did — the
    /// person has looked at those numbers and they must not move.
    func testAPlanWrittenBeforeThisFieldIsInForceForEveryMonth() throws {
        let repo = MemoryRepository()
        repo.files["budget"] = Data("""
        {"incomeBase":{"fixed":{"_0":5000000}},
         "lines":[{"id":"5D1B9E6E-0000-4000-8000-000000000001",
                   "category":"Продукти","percent":30}]}
        """.utf8)

        let store = makeStore(repo)
        XCTAssertNotNil(store.budget, "precondition: the old file still decodes")
        XCTAssertNil(store.budget?.month)
        for month in [july, august, september, MonthKey(year: 2001, month: 3)] {
            XCTAssertEqual(store.plan(for: month)?.lines.first?.percent, 30,
                           "\(month) lost the plan it has always been measured against")
        }
    }

    // MARK: which plan a month is measured against

    func testAMonthIsMeasuredAgainstThePlanItActuallyHad() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(july))
        store.setBudget(plan(50), now: date(september))

        XCTAssertEqual(store.plan(for: july)?.lines.first?.percent, 30)
        XCTAssertEqual(store.plan(for: august)?.lines.first?.percent, 30,
                       "August was lived under July's plan — nothing replaced it")
        XCTAssertEqual(store.plan(for: september)?.lines.first?.percent, 50)
    }

    /// A month that ended before the first plan falls back to that first
    /// plan. Returning nil is arguably the more honest answer and is the wrong
    /// one: the app backfills months of history, and returning nothing made
    /// the tab useful for exactly the month the plan was written in. Two UI
    /// tests said so before this comment did.
    ///
    /// It is honest anyway because the screen names the month the plan came
    /// from — `budget.planMonth` reads «План від серпень 2026».
    func testAMonthBeforeTheFirstPlanIsMeasuredAgainstTheEarliestOne() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        store.setBudget(plan(70), now: date(september))

        XCTAssertEqual(store.plan(for: july)?.lines.first?.percent, 30,
                       "the EARLIEST plan, not the newest — July is not September")
        XCTAssertEqual(store.plan(for: august)?.lines.first?.percent, 30)
    }

    /// Editing within the same month is an edit, not a new plan: the month has
    /// only ever been measured against the thing being changed, so archiving
    /// would fill history with every tap of «Змінити».
    func testEditingWithinAMonthReplacesRatherThanArchives() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august, day: 2))
        store.setBudget(plan(35), now: date(august, day: 9))
        store.setBudget(plan(40), now: date(august, day: 20))

        XCTAssertTrue(store.budgetHistory.isEmpty, "three edits of one month are one plan")
        XCTAssertEqual(store.plan(for: august)?.lines.first?.percent, 40)
    }

    func testASupersededPlanIsKeptRatherThanOverwritten() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(july))
        store.setBudget(plan(50), now: date(august))

        XCTAssertEqual(store.budgetHistory.count, 1)
        XCTAssertEqual(store.budgetHistory.first?.month, july)
        XCTAssertEqual(store.budgetHistory.first?.lines.first?.percent, 30)
    }

    // MARK: the monthly decision

    func testNoDecisionIsAskedForWithinTheMonthThePlanWasWrittenFor() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august, day: 2))
        XCTAssertFalse(store.planNeedsAMonthlyDecision(now: date(august, day: 28)))
    }

    func testTheDecisionIsOfferedOnceTheMonthHasTurned() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        XCTAssertTrue(store.planNeedsAMonthlyDecision(now: date(september, day: 1)))
    }

    func testNothingIsAskedWhenThereIsNoPlanAtAll() {
        XCTAssertFalse(makeStore().planNeedsAMonthlyDecision(now: date(september)))
    }

    /// The half that must NOT happen: until somebody chooses, the old plan is
    /// still the newest one written on or before now, so the new month goes on
    /// being measured and no screen breaks. An offer, not an interruption.
    func testTheNewMonthIsStillMeasuredWhileTheOfferIsIgnored() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        XCTAssertEqual(store.plan(for: september)?.lines.first?.percent, 30)
    }

    func testCarryingForwardRestampsTheSameSharesAndKeepsTheOldMonth() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        store.carryPlanForward(now: date(september, day: 1))

        XCTAssertEqual(store.budget?.month, september)
        XCTAssertEqual(store.budget?.lines.first?.percent, 30)
        XCTAssertFalse(store.planNeedsAMonthlyDecision(now: date(september, day: 3)),
                       "the offer must go away once it is taken")
        XCTAssertEqual(store.plan(for: august)?.lines.first?.percent, 30,
                       "August keeps its own copy, not a stamp from September")
        XCTAssertEqual(store.plan(for: august)?.month, august)
    }

    func testCarryingForwardDoesNothingWhenThereIsNothingToDecide() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august, day: 2))
        store.carryPlanForward(now: date(august, day: 20))
        XCTAssertEqual(store.budget?.month, august)
        XCTAssertTrue(store.budgetHistory.isEmpty)
    }

    /// Re-planning is the other branch, and the one that has to leave the old
    /// month alone.
    func testReplanningLeavesTheOldMonthMeasuredAsItWas() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(august))
        store.setBudget(plan(60), now: date(september, day: 1))

        XCTAssertEqual(store.plan(for: august)?.lines.first?.percent, 30)
        XCTAssertEqual(store.plan(for: september)?.lines.first?.percent, 60)
    }

    // MARK: it survives the file

    func testEveryPlanSurvivesARelaunch() async throws {
        let repo = MemoryRepository()
        let store = makeStore(repo)
        store.setBudget(plan(30), now: date(july))
        store.setBudget(plan(50), now: date(september))

        try await Task.sleep(for: .milliseconds(1_200))   // past the 300 ms debounce

        let next = makeStore(repo)
        XCTAssertEqual(next.budget?.month, september)
        XCTAssertEqual(next.budgetHistory.map(\.month), [july])
        XCTAssertEqual(next.plan(for: august)?.lines.first?.percent, 30,
                       "a history that did not survive is a past month measured wrong")
    }

    /// A device that has never written a superseded plan has no such file, and
    /// that is not a failure — it is every fresh install.
    func testAMissingHistoryFileIsAnEmptyHistoryAndNotAReportedFailure() {
        let store = makeStore()
        XCTAssertTrue(store.budgetHistory.isEmpty)
        XCTAssertEqual(store.loadFailures, [], "board #68 must not accuse a fresh install")
    }

    /// The export is the whole dataset. Carrying the current plan and dropping
    /// the earlier ones would export a file that cannot reproduce the months
    /// it contains.
    ///
    /// Decoded, not grepped. The first version searched the whole document for
    /// the superseded plan's category and passed with the history emptied,
    /// because `setBudget` also creates that category and the export carries
    /// the category list — the string was there for a different reason.
    func testTheExportCarriesEveryPlanNotJustTheCurrentOne() throws {
        struct Exported: Decodable {
            var budget: Budget?
            var budgetHistory: [Budget]
        }
        let store = makeStore()
        store.setBudget(plan(30, "Транспорт"), now: date(july))
        store.setBudget(plan(50, "Медицина"), now: date(september))

        let exported = try SeedLoader.decoder.decode(Exported.self, from: store.exportJSON())
        XCTAssertEqual(exported.budget?.lines.first?.category, "Медицина")
        XCTAssertEqual(exported.budgetHistory.count, 1,
                       "the superseded plan is part of the data, not an offcut")
        XCTAssertEqual(exported.budgetHistory.first?.lines.first?.category, "Транспорт")
        XCTAssertEqual(exported.budgetHistory.first?.month, july)
    }

    func testResettingTheAppForgetsEveryPlan() {
        let store = makeStore()
        store.setBudget(plan(30), now: date(july))
        store.setBudget(plan(50), now: date(september))
        store.resetEverything()

        XCTAssertNil(store.budget)
        XCTAssertTrue(store.budgetHistory.isEmpty)
    }
}
