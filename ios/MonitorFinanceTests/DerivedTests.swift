import XCTest
@testable import MonitorFinance

@MainActor
final class DerivedTests: XCTestCase {
    override func setUp() { super.setUp(); pinUkrainianFormatting() }


    /// Kyiv noon on the given day, so no fixture ever sits near a boundary
    /// by accident — the boundary cases are asserted deliberately below.
    private func tx(_ day: Int, _ month: Int = 8, kind: TxKind = .expense,
                    amount: Int, category: String = "Продукти",
                    merchant: String = "Гастроном-Приклад",
                    resolution: Resolution = .rule) -> Transaction {
        let date = Calendar.kyiv.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: 12))!
        return Transaction(id: UUID(), date: date, kind: kind, category: category,
                           merchant: merchant, amount: amount, cardSuffix: "*0000",
                           bankId: "monobank", receiptId: nil, splits: [],
                           resolution: resolution, suggestions: [])
    }

    // MARK: totals

    func testSpentAndIncomeAreSeparateAndPositive() {
        let totals = Derived.totals([
            tx(1, amount: -10_000),
            tx(2, amount: -5_000),
            tx(3, kind: .income, amount: 100_000, category: "Зарплата"),
        ])
        XCTAssertEqual(totals.spent, 15_000, "spent is a magnitude, not a negative sum")
        XCTAssertEqual(totals.income, 100_000)
    }

    /// The constraint the whole stage rests on: a transfer between your own
    /// cards is neither spending nor income. Both directions must be ignored.
    func testTransfersCountAsNeitherSpendingNorIncome() {
        let totals = Derived.totals([
            tx(1, amount: -10_000),
            tx(2, kind: .transfer, amount: -400_000, category: "Переказ", resolution: .transfer),
            tx(3, kind: .transfer, amount: 400_000, category: "Переказ", resolution: .transfer),
        ])
        XCTAssertEqual(totals.spent, 10_000, "an outgoing transfer must not inflate spending")
        XCTAssertEqual(totals.income, 0, "an incoming transfer must not look like salary")
    }

    func testEmptyInputGivesZeroes() {
        XCTAssertEqual(Derived.totals([]), Derived.MonthTotals(spent: 0, income: 0))
    }

    // MARK: months and month filtering

    func testMonthsAreUniqueAndAscending() {
        let months = Derived.months([tx(5, 8, amount: -1), tx(9, 6, amount: -1), tx(28, 8, amount: -1)])
        XCTAssertEqual(months.map(\.description), ["2026-06", "2026-08"])
    }

    func testInMonthUsesKyivBoundaries() {
        // 2026-04-01 00:30 Kyiv == 2026-03-31 21:30 UTC. It belongs to April.
        let boundary = Transaction(id: UUID(), date: Date(timeIntervalSince1970: 1_774_992_600),
                                   kind: .expense, category: "Продукти", merchant: "Гастроном-Приклад",
                                   amount: -1_000, cardSuffix: "*0000", bankId: "monobank",
                                   receiptId: nil, splits: [], resolution: .rule, suggestions: [])
        XCTAssertEqual(Derived.inMonth([boundary], MonthKey(year: 2026, month: 4)).count, 1)
        XCTAssertEqual(Derived.inMonth([boundary], MonthKey(year: 2026, month: 3)).count, 0)
    }

    // MARK: category breakdown

    func testByCategorySumsDescendingWithSharesOfSpendOnly() {
        let slices = Derived.byCategory([
            tx(1, amount: -60_000, category: "Продукти"),
            tx(2, amount: -30_000, category: "Пальне"),
            tx(3, amount: -10_000, category: "Продукти"),
            tx(4, kind: .income, amount: 100_000, category: "Зарплата"),
            tx(5, kind: .transfer, amount: -500_000, category: "Переказ", resolution: .transfer),
        ])
        XCTAssertEqual(slices.map(\.name), ["Продукти", "Пальне"],
                       "income and transfers are not spending categories")
        XCTAssertEqual(slices.map(\.sum), [70_000, 30_000])
        XCTAssertEqual(slices[0].share, 0.7, accuracy: 0.0001)
        XCTAssertEqual(slices[1].share, 0.3, accuracy: 0.0001)
    }

    // MARK: board #83 — the ring closes

    /// The shape of the defect: `prefix(8)` drew eight arcs and dropped the
    /// rest, leaving a visible unfilled remainder — 8.5% across the demo
    /// seed's fifteen categories. Board #57 made it read as missing data
    /// rather than styling, because the middle is occupied and each category
    /// now has its own colour.
    func testTheRingIsClosedWhenThereAreMoreCategoriesThanColours() {
        let slices = (1...15).map {
            Derived.CategorySlice(name: "К\($0)", sum: 100, share: 1.0 / 15)
        }
        let ring = Derived.ringSlices(slices)

        XCTAssertEqual(ring.count, 8, "seven categories and one everything-else arc")
        XCTAssertEqual(ring.map(\.share).reduce(0, +), 1.0, accuracy: 0.0001,
                       "the arcs must add up to a whole circle")
        XCTAssertEqual(ring.map(\.sum).reduce(0, +), 1_500,
                       "and account for every hryvnia the slices did")
    }

    /// The aggregate is the LAST arc and carries everything past the seventh,
    /// so the seven real slices keep their own colours and their own rank.
    func testTheAggregateIsTheLastArcAndHoldsTheWholeTail() {
        let slices = (1...12).map {
            Derived.CategorySlice(name: "К\($0)", sum: 1_000 - $0, share: 0.1)
        }
        let ring = Derived.ringSlices(slices)

        XCTAssertEqual(ring.prefix(7).map(\.name), slices.prefix(7).map(\.name),
                       "the seven biggest are untouched")
        XCTAssertFalse(ring.prefix(7).contains { $0.isAggregate })

        let rest = try? XCTUnwrap(ring.last)
        XCTAssertEqual(rest?.isAggregate, true)
        XCTAssertEqual(rest?.sum, slices.dropFirst(7).reduce(0) { $0 + $1.sum })
    }

    /// Eight fits, so nothing folds. Off by one here would hide a real
    /// category behind an aggregate of exactly one thing — a row saying
    /// «Решта» over a single category's figures.
    func testEightOrFewerCategoriesAreDrawnAsThemselves() {
        for count in 1...8 {
            let slices = (1...count).map {
                Derived.CategorySlice(name: "К\($0)", sum: 100, share: 1.0 / Double(count))
            }
            let ring = Derived.ringSlices(slices)
            XCTAssertEqual(ring, slices, "\(count) categories must be drawn as themselves")
            XCTAssertFalse(ring.contains { $0.isAggregate }, "\(count) needs no aggregate")
        }
    }

    /// Nine is the first count that folds, and it folds two into the tail —
    /// never one.
    func testNineCategoriesFoldTwoIntoTheTail() {
        let slices = (1...9).map {
            Derived.CategorySlice(name: "К\($0)", sum: 100, share: 1.0 / 9)
        }
        let ring = Derived.ringSlices(slices)
        XCTAssertEqual(ring.count, 8)
        XCTAssertEqual(ring.last?.sum, 200, "the eighth and ninth, together")
    }

    /// **The trap board #83 names.** The seed ships a real category called
    /// «Інше», so an aggregate wearing that name would put two different
    /// things under one label. It is «Решта» — and even if somebody renames a
    /// category to that, the two are still distinguishable, because a
    /// `ForEach` drawing two rows under one id draws one of them.
    func testTheAggregateIsNotConfusableWithARealCategory() {
        XCTAssertNotEqual(Derived.restOfTheRing, "Інше")

        let clash = (1...12).map { n in
            Derived.CategorySlice(name: n == 1 ? Derived.restOfTheRing : "К\(n)",
                                  sum: 1_000 - n, share: 0.1)
        }
        let ring = Derived.ringSlices(clash)
        XCTAssertEqual(Set(ring.map(\.id)).count, ring.count,
                       "a real «Решта» and the aggregate must not share an id")
    }

    /// **The tail is summed, never taken as `1 - head`.**
    ///
    /// Against shares that add up to 1 the two are identical to about 1e-16,
    /// so a fixture built from `byCategory`'s own output cannot tell them
    /// apart — the first version of this test could not, and the mutation
    /// survived. The property that actually matters is that `ringSlices` is
    /// total over its input rather than assuming a normalised one: it is a
    /// pure function on a list of slices, and nothing in its signature
    /// promises they are a whole.
    ///
    /// Ten slices of 5% each. Seven are drawn as themselves and three fold, so
    /// the tail is 15%; taken as leftovers it would be 65% — a sixth of the
    /// ring drawn as two thirds of it.
    func testTheTailIsSummedRatherThanAssumedToBeWhateverIsLeft() {
        let slices = (1...10).map {
            Derived.CategorySlice(name: "К\($0)", sum: 50, share: 0.05)
        }
        let ring = Derived.ringSlices(slices)
        let rest = ring.last

        XCTAssertEqual(rest?.isAggregate, true)
        XCTAssertEqual(rest?.share ?? 0, 0.15, accuracy: 1e-12,
                       "three slices of 5% — not 1 minus the seven in front of them")
        XCTAssertEqual(ring.map(\.share).reduce(0, +), 0.50, accuracy: 1e-12,
                       "a half-a-ring input stays half a ring; this function normalises nothing")
    }

    /// Equal sums must order by name, not by whatever the dictionary felt
    /// like. Without the tie-break this passes or fails at random between runs.
    /// Four equal sums, not two. `byCategory` builds its slices from a
    /// Dictionary, whose iteration order is unspecified and varies between
    /// launches — so with two categories, dropping the name tie-break still
    /// produces the expected order about half the time and the test passes by
    /// luck. Four names make luck a 1-in-24 shot.
    func testEqualSumsBreakTieByNameSoOrderIsStable() {
        let slices = Derived.byCategory([
            tx(1, amount: -50_000, category: "Пальне"),
            tx(2, amount: -50_000, category: "Автомобіль"),
            tx(3, amount: -50_000, category: "Транспорт"),
            tx(4, amount: -50_000, category: "Здоров'я"),
        ])
        XCTAssertEqual(slices.map(\.name),
                       ["Автомобіль", "Здоров'я", "Пальне", "Транспорт"])
    }

    func testByCategoryOnAllIncomeDoesNotDivideByZero() {
        let slices = Derived.byCategory([tx(1, kind: .income, amount: 100_000, category: "Зарплата")])
        XCTAssertTrue(slices.isEmpty)
    }

    // MARK: product group breakdown

    /// Builds an expense with explicit splits. `amount` is the transaction's
    /// own signed total; splits carry positive amounts, as `SplitMath.build`
    /// always produces.
    private func splitTx(_ day: Int, amount: Int, splits: [Split],
                         merchant: String = "Гастроном-Приклад") -> Transaction {
        Transaction(id: UUID(), date: Calendar.kyiv.date(from: DateComponents(
                        year: 2026, month: 8, day: day, hour: 12))!,
                    kind: .expense, category: "Продукти", merchant: merchant,
                    amount: amount, cardSuffix: "*0000", bankId: "monobank",
                    receiptId: nil, splits: splits, resolution: .rule, suggestions: [])
    }

    /// The invariant the whole switch rests on: whichever way you slice a
    /// month — by spending category or by product group — the total must be
    /// the same. Mixes a split purchase with an unsplit one so an
    /// implementation that drops unsplit rows (instead of bucketing them
    /// into `noReceipt`) is caught here rather than only in production.
    func testByProductGroupAndByCategoryReportTheSameTotal() {
        let rows = [
            splitTx(1, amount: -50_000, splits: [
                Split(id: UUID(), name: "Молоко", amount: 30_000, category: "Молочні продукти"),
                Split(id: UUID(), name: "Бензин А95", amount: 20_000, category: "Пальне та автотовари"),
            ]),
            splitTx(2, amount: -15_000, splits: []),
            tx(3, amount: -25_000, category: "Пальне"),
        ]
        let byCategoryTotal = Derived.byCategory(rows).map(\.sum).reduce(0, +)
        let byProductGroupTotal = Derived.byProductGroup(rows).map(\.sum).reduce(0, +)
        XCTAssertEqual(byCategoryTotal, 90_000)
        XCTAssertEqual(byProductGroupTotal, byCategoryTotal,
                       "splitting the month a different way must not change how much it reports")
    }

    /// With nothing split at all, every purchase's whole amount falls into
    /// the single synthetic `noReceipt` bucket — not several groups, not zero.
    func testByProductGroupWithNothingSplitIsASingleNoReceiptSliceAtFullShare() {
        let rows = [splitTx(1, amount: -30_000, splits: []),
                    splitTx(2, amount: -20_000, splits: [])]
        let slices = Derived.byProductGroup(rows)
        // `.first`, not `slices[0]`, so a mutation that empties `slices`
        // fails this assertion cleanly instead of crashing the run and
        // hiding which check actually broke.
        guard let only = slices.first else {
            return XCTFail("expected exactly one slice, got \(slices)")
        }
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(only.name, Derived.noReceipt)
        XCTAssertEqual(only.sum, 50_000)
        XCTAssertEqual(only.share, 1.0, accuracy: 0.0001)
    }

    /// `noReceipt` is compared against `Derived.noReceipt` everywhere else in
    /// this file, which constrains nothing on its own — the constant could
    /// become `""`, or collide with a real product group from the 21-group
    /// taxonomy, and every other test would stay green. Pin the literal.
    func testNoReceiptIsTheLiteralBezCheka() {
        XCTAssertEqual(Derived.noReceipt, "Без чека")
    }

    /// A split purchase contributes per line item to its own product groups;
    /// its unsplit neighbour lands whole in `noReceipt` — not dropped, not
    /// folded into the split purchase's groups.
    func testASplitTransactionContributesPerSplitAndItsUnsplitNeighbourLandsInNoReceipt() {
        let rows = [
            splitTx(1, amount: -50_000, splits: [
                Split(id: UUID(), name: "Молоко", amount: 30_000, category: "Молочні продукти"),
                Split(id: UUID(), name: "Бензин А95", amount: 20_000, category: "Пальне та автотовари"),
            ]),
            splitTx(2, amount: -12_000, splits: []),
        ]
        let slices = Derived.byProductGroup(rows)
        XCTAssertEqual(Set(slices.map(\.name)),
                       Set(["Молочні продукти", "Пальне та автотовари", Derived.noReceipt]))
        XCTAssertEqual(slices.first { $0.name == "Молочні продукти" }?.sum, 30_000)
        XCTAssertEqual(slices.first { $0.name == "Пальне та автотовари" }?.sum, 20_000)
        XCTAssertEqual(slices.first { $0.name == Derived.noReceipt }?.sum, 12_000)
    }

    /// Split rows are named by the PRODUCT (`split.name`); an unsplit row
    /// under `noReceipt` is named by the MERCHANT, since it has no product to
    /// name. Largest first. `Contribution` is `Identifiable` and backs a
    /// SwiftUI list in the next task, so this also pins the id: a split row
    /// must carry its SPLIT's id and the `noReceipt` row must carry its
    /// TRANSACTION's id — never a freshly minted UUID, which would look fine
    /// in a screenshot and break list diffing/animation in motion.
    func testContributionsNameTheProductForSplitRowsAndTheMerchantForNoReceiptRows() {
        let milkID = UUID()
        let yogurtID = UUID()
        let unsplitTxID = UUID()

        let splitRow = splitTx(1, amount: -50_000, splits: [
            Split(id: milkID, name: "Молоко", amount: 30_000, category: "Молочні продукти"),
            Split(id: yogurtID, name: "Йогурт", amount: 5_000, category: "Молочні продукти"),
        ], merchant: "Гастроном-Приклад")

        var unsplitRow = splitTx(2, amount: -12_000, splits: [], merchant: "Ринок-Приклад")
        unsplitRow.id = unsplitTxID

        let rows = [splitRow, unsplitRow]

        let dairy = Derived.contributions(rows, to: "Молочні продукти")
        XCTAssertEqual(dairy.map(\.name), ["Молоко", "Йогурт"], "largest first")
        XCTAssertEqual(dairy.map(\.amount), [30_000, 5_000])
        XCTAssertEqual(dairy.map(\.id), [milkID, yogurtID],
                       "a split row's id must be the SPLIT's id, not a fresh or borrowed one")

        let unreceipted = Derived.contributions(rows, to: Derived.noReceipt)
        XCTAssertEqual(unreceipted.map(\.name), ["Ринок-Приклад"],
                       "an unsplit row is named by its merchant, not a product")
        XCTAssertEqual(unreceipted.map(\.amount), [12_000])
        XCTAssertEqual(unreceipted.map(\.id), [unsplitTxID],
                       "a noReceipt row's id must be the TRANSACTION's id")
    }

    // MARK: day grouping

    func testDaysGroupNewestFirstAndKeepRowsWithinADay() {
        let sections = Derived.days([tx(3, amount: -1), tx(5, amount: -2), tx(5, amount: -3)])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].rows.count, 2, "the 5th has two rows")
        XCTAssertGreaterThan(sections[0].day, sections[1].day, "newest day first")
    }

    // MARK: search

    func testSearchMatchesMerchantAndCategoryCaseInsensitively() {
        let rows = [tx(1, amount: -1, category: "Продукти", merchant: "Гастроном-Приклад"),
                    tx(2, amount: -1, category: "Пальне", merchant: "АЗС-Приклад")]
        XCTAssertEqual(Derived.search(rows, "гастроном-приклад").count, 1)
        XCTAssertEqual(Derived.search(rows, "пальне").count, 1)
        XCTAssertEqual(Derived.search(rows, "азс-приклад").count, 1, "search must be case-insensitive")
        XCTAssertEqual(Derived.search(rows, "  ").count, 2, "a blank query filters nothing")
    }

    // MARK: tints — moved to CategoryTintTests by board #57
    //
    // A category's colour stopped being a function of its name and became a
    // property of the category, so the three tests that lived here (stability,
    // "the hash is djb2 and not `hashValue`", and the two known collisions)
    // are about the store now, not about `Derived`. The collision test in
    // particular asserted a defect this card removed.

    // MARK: tips

    /// The three tips are computed, not written: the prototype's three were
    /// about credit-card interest on an account this dataset does not describe.
    func testTipsDescribeTheLargestCategoryTheWorstMonthAndTheTopMerchant() {
        let rows =
            (1...5).map { tx($0, 6, amount: -100_000, category: "Автомобіль", merchant: "АЗС-Приклад") }
            + [tx(6, 6, amount: -20_000, category: "Продукти", merchant: "Гастроном-Приклад"),
               tx(7, 6, kind: .income, amount: 300_000, category: "Зарплата", merchant: "ФОП"),
               // July: spends far past its income — the "worst month" tip.
               tx(1, 7, amount: -400_000, category: "Продукти", merchant: "Гастроном-Приклад"),
               tx(2, 7, kind: .income, amount: 100_000, category: "Зарплата", merchant: "ФОП")]

        let tips = Derived.tips(rows)
        XCTAssertEqual(tips.count, 3)
        XCTAssertTrue(tips[0].body.contains("Автомобіль"), tips[0].body)
        XCTAssertTrue(tips[1].body.contains("липень") || tips[1].body.contains("Липень"), tips[1].body)
        // АЗС-Приклад appears 5 times against Гастроном-Приклад's 2 — the most FREQUENT merchant,
        // which is not the same question as the largest category above.
        XCTAssertTrue(tips[2].body.contains("АЗС-Приклад"), tips[2].body)
    }

    /// A fresh install with no data must not crash or show three empty cards.
    func testTipsOnAnEmptyLedgerAreEmpty() {
        XCTAssertTrue(Derived.tips([]).isEmpty)
    }

    /// A month that never exceeded its income must not be reported as if it had.
    func testNoOverspendMonthMeansNoOverspendTip() {
        let rows = [tx(1, 6, amount: -10_000),
                    tx(2, 6, kind: .income, amount: 500_000, category: "Зарплата")]
        XCTAssertFalse(Derived.tips(rows).contains { $0.title == "Місяць понад дохід" })
    }

    /// Spending more than nothing is not news. Without the `income > 0` guard
    /// this month is reported as the ledger's worst overspend.
    func testAMonthWithNoIncomeIsNeverReportedAsOverspending() {
        let rows = [tx(1, 6, amount: -50_000, merchant: "Гастроном-Приклад"),
                    tx(2, 6, amount: -50_000, merchant: "АЗС-Приклад")]
        XCTAssertFalse(Derived.tips(rows).contains { $0.title == "Місяць понад дохід" },
                       "a month with no income at all cannot have exceeded it")
    }

    /// One sighting is not a habit. Without the `rows.count > 1` guard, any
    /// ledger at all produces a "most frequent merchant" tip.
    func testASingleSightingIsNotAMostFrequentMerchant() {
        let rows = [tx(1, 6, amount: -10_000, category: "Продукти", merchant: "Гастроном-Приклад"),
                    tx(2, 6, amount: -10_000, category: "Пальне", merchant: "АЗС-Приклад")]
        XCTAssertFalse(Derived.tips(rows).contains { $0.title == "Найчастіший продавець" },
                       "every merchant here appears exactly once")
    }

    // MARK: tips — «Найбільша стаття» needs a sorted corpus (board #20)

    /// The largest-category tip, or nil. Read by title rather than by index:
    /// suppressing tip 1 shifts the others up, and a test indexing `tips[0]`
    /// would then assert against the merchant tip without saying so.
    private func largestCategoryTip(_ rows: [Transaction]) -> Derived.Tip? {
        Derived.tips(rows).first { $0.title == "Найбільша стаття" }
    }

    /// The first launch after a sync: every row arrives `.pending` with no
    /// category, so the tip read «Без категорії — 100% усіх витрат» — true,
    /// and mockery from something just installed.
    func testAFreshlySyncedLedgerNamesNoLargestCategory() {
        let rows = (1...6).map {
            tx($0, 6, amount: -100_00, category: "", merchant: "Тестовий продавець",
               resolution: .pending)
        }
        XCTAssertNil(largestCategoryTip(rows),
                     "nothing is sorted yet — «найбільша стаття» has no answer")
    }

    /// …and the OTHER two observations survive it. Suppressing all three would
    /// trade one useless sentence for an empty card, and Home shows only the
    /// first tip, so it would show nothing at all. A month and a merchant do
    /// not get less true because nobody has typed a category yet.
    func testAFreshlySyncedLedgerStillReportsWhatItDoesKnow() {
        let rows = (1...4).map {
            tx($0, 6, amount: -100_00, category: "", merchant: "Гастроном-Приклад",
               resolution: .pending)
        } + [tx(5, 6, kind: .income, amount: 50_00, category: "Зарплата",
                merchant: "ФОП", resolution: .pending)]

        let tips = Derived.tips(rows)
        XCTAssertEqual(tips.map(\.title), ["Місяць понад дохід", "Найчастіший продавець"])
        XCTAssertEqual(tips.first?.title, "Місяць понад дохід",
                       "Home renders tips().first — it must be a real observation, not nothing")
    }

    /// The ceiling is a share of SPEND. Pinned as a literal rather than read
    /// off the constant: a test that follows the constant cannot fail when the
    /// constant changes, which is the one thing this number needs.
    func testTheUnsortedCeilingIsFifteenPercent() {
        XCTAssertEqual(Derived.unsortedTipCeiling, 0.15, accuracy: 0.0001)
    }

    /// Exactly at the ceiling still counts as sorted enough — `>` and not
    /// `>=`. The equality is exact: 15 000 / 100 000 rounds to the same double
    /// as the literal `0.15`.
    func testAtTheUnsortedCeilingTheLargestCategoryIsStillNamed() {
        let rows = [tx(1, 6, amount: -85_000, category: "Продукти"),
                    tx(2, 6, amount: -15_000, category: "", resolution: .pending)]
        XCTAssertEqual(largestCategoryTip(rows)?.body.contains("Продукти"), true,
                       "85% of the money is sorted and «Продукти» leads it")
    }

    /// One percentage point over, and «Продукти — 84%» becomes a claim the
    /// data cannot support: the unsorted 16% could belong anywhere.
    func testOverTheUnsortedCeilingTheLargestCategoryIsWithheld() {
        let rows = [tx(1, 6, amount: -84_000, category: "Продукти"),
                    tx(2, 6, amount: -16_000, category: "", resolution: .pending)]
        XCTAssertNil(largestCategoryTip(rows),
                     "too much of the spend is unsorted for a leader to be named")
    }

    /// The second half of the rule, and it is not implied by the ceiling: with
    /// a long tail of small categories «Без категорії» can LEAD on 12% — under
    /// the ceiling — and naming the unsorted pile is never an observation
    /// about spending whatever its share.
    func testUncategorisedIsNeverNamedAsTheLargestCategory() {
        var rows = [tx(1, 6, amount: -12_000, category: "", resolution: .pending)]
        for (n, name) in ["Продукти", "Транспорт", "Кафе та ресторани", "Покупки",
                          "Медицина", "Розваги", "Послуги", "Квартплата"].enumerated() {
            rows.append(tx(n + 2, 6, amount: -11_000, category: name))
        }
        let slices = Derived.byCategory(rows)
        XCTAssertEqual(slices.first?.name, Derived.uncategorised, "precondition: it leads")
        XCTAssertLessThan(slices.first!.share, Derived.unsortedTipCeiling,
                          "precondition: and it is under the ceiling, so only the name rule can hide it")
        XCTAssertNil(largestCategoryTip(rows))
    }

    /// Rows would answer this the other way round, which is why the ceiling
    /// counts money. Twenty unsorted crumbs against one real purchase: 95% of
    /// the ROWS are unsorted and 0.2% of the money is, and the leader is known.
    func testManySmallUnsortedRowsDoNotHideTheLargestCategory() {
        let rows = (1...20).map { tx($0, 6, amount: -10, category: "", resolution: .pending) }
            + [tx(21, 6, amount: -100_000, category: "Продукти")]
        XCTAssertEqual(largestCategoryTip(rows)?.body.contains("Продукти"), true,
                       "a row-share rule would have hidden a tip the money supports")
    }

    /// And the mirror image: one unsorted purchase is a seventh of the rows
    /// and a quarter of the money, and a quarter is enough to be wrong with.
    func testOneLargeUnsortedRowHidesTheLargestCategory() {
        let rows = (1...6).map { tx($0, 6, amount: -10_000, category: "Продукти") }
            + [tx(7, 6, amount: -20_000, category: "", resolution: .pending)]
        let slices = Derived.byCategory(rows)
        XCTAssertEqual(slices.first?.name, "Продукти",
                       "precondition: the unsorted row does NOT lead — only the ceiling can hide this")
        XCTAssertNil(largestCategoryTip(rows),
                     "a row-share rule would have shown a leader the money does not support")
    }

    // MARK: filters

    func testAnEmptyFilterIsNotAFilter() {
        let rows = [tx(1, amount: -1), tx(2, kind: .income, amount: 1, category: "Зарплата")]
        XCTAssertEqual(Derived.apply(FeedFilter(), to: rows).count, 2)
    }

    /// Within one dimension the terms are OR — picking two categories means
    /// "either" — and across dimensions they are AND.
    func testWithinADimensionIsOrAndAcrossDimensionsIsAnd() {
        let rows = [
            tx(1, amount: -1, category: "Продукти", merchant: "Гастроном-Приклад"),
            tx(2, amount: -1, category: "Пальне", merchant: "АЗС-Приклад"),
            tx(3, kind: .income, amount: 1, category: "Продукти", merchant: "ФОП"),
        ]
        var filter = FeedFilter()
        filter.categories = ["Продукти", "Пальне"]
        XCTAssertEqual(Derived.apply(filter, to: rows).count, 3, "two categories means either")

        filter.kinds = [.expense]
        XCTAssertEqual(Derived.apply(filter, to: rows).count, 2,
                       "adding a kind narrows the category result, it does not widen it")
    }

    func testCardFilterMatchesTheSuffixExactly() {
        var a = tx(1, amount: -1); a.cardSuffix = "*0000"
        var b = tx(2, amount: -1); b.cardSuffix = "*0001"
        var filter = FeedFilter()
        filter.cards = ["*0001"]
        XCTAssertEqual(Derived.apply(filter, to: [a, b]).map(\.cardSuffix), ["*0001"])
    }

    /// Board #99 threaded the banks and a language through `chips`, neither
    /// defaulted: the kind chip is the one term that is COPY, and a default
    /// argument is how this call site would have gone on asserting the
    /// Ukrainian while an English reader saw it on screen too.
    func testChipsNameEveryActiveTerm() {
        var filter = FeedFilter()
        filter.categories = ["Продукти"]
        filter.kinds = [.income]
        XCTAssertTrue(filter.chips([], .uk).contains("Продукти"))
        XCTAssertTrue(filter.chips([], .uk).contains("Надходження"))
        XCTAssertEqual(FeedFilter().chips([], .uk), [])
    }

    // MARK: chart series

    func testMonthlyTotalsAreOneBarPerMonthAscendingAndSpendOnly() {
        let rows = [tx(1, 6, amount: -10_000), tx(2, 6, amount: -5_000),
                    tx(1, 7, amount: -20_000),
                    tx(2, 7, kind: .income, amount: 900_000, category: "Зарплата"),
                    tx(3, 7, kind: .transfer, amount: -700_000, category: "Переказ",
                       resolution: .transfer)]
        let bars = Derived.monthlyTotals(rows)
        XCTAssertEqual(bars.map(\.sum), [15_000, 20_000],
                       "income and transfers are not spending, and June comes before July")
    }

    /// Seven bars always, including days with nothing — a week chart that
    /// silently drops empty days misreports the shape of a week.
    func testDailyTotalsAlwaysReturnSevenBarsOldestFirst() {
        let end = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 12))!
        let bars = Derived.dailyTotals([tx(7, 8, amount: -30_000), tx(5, 8, amount: -10_000)],
                                       week: end)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.last?.sum, 30_000, "the last bar is the week's end day")
        XCTAssertEqual(bars.map(\.sum).reduce(0, +), 40_000)
        XCTAssertEqual(bars.filter { $0.sum == 0 }.count, 5)
    }

    /// FINDING: the brief's original fixture here was `tx(1, 8, ...)` (1 Aug),
    /// but 1 Aug is only 6 days before 7 Aug and is the OLDEST day *inside*
    /// the 7-day window [1 Aug … 7 Aug] — the window `dailyTotals` documents
    /// as "seven Kyiv days ending on `ending`". That fixture asserted a sum
    /// of 0 against a transaction the correct implementation legitimately
    /// includes, so it failed against a spec-compliant implementation, not a
    /// broken one. 30 July is genuinely 8 days before 7 Aug (matching this
    /// test's own comment) and falls outside the window, so it is used here.
    func testDailyTotalsExcludeDaysOutsideTheWindow() {
        let end = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 12))!
        let bars = Derived.dailyTotals([tx(30, 7, amount: -99_000)], week: end)
        XCTAssertEqual(bars.map(\.sum).reduce(0, +), 0, "30 July is eight days before 7 Aug")
    }

    // MARK: the week window

    /// The headline total and the sum of the bars must describe the SAME week.
    /// The fixture is built to catch the specific way they used to diverge: an
    /// instant-based window (anchor − 7 × 24h) reaches back into the afternoon
    /// of an eighth day that the bars never draw.
    func testTheWeekHeadlineEqualsTheSumOfItsBars() {
        func at(_ day: Int, _ hour: Int, _ amount: Int) -> Transaction {
            Transaction(id: UUID(),
                        date: Calendar.kyiv.date(from: DateComponents(
                            year: 2026, month: 8, day: day, hour: hour))!,
                        kind: .expense, category: "Продукти", merchant: "Гастроном-Приклад",
                        amount: amount, cardSuffix: "*0000", bankId: "monobank",
                        receiptId: nil, splits: [], resolution: .rule, suggestions: [])
        }
        let anchor = Calendar.kyiv.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 12))!

        // Day 3 18:00 is OUTSIDE the seven days 4–10, but inside anchor − 7×24h.
        let rows = [at(3, 18, -50_000), at(5, 9, -20_000), at(10, 20, -30_000)]

        let headline = Derived.totals(StatsView.weekRows(rows, endingAt: anchor)).spent
        let bars = Derived.dailyTotals(rows, week: anchor).map(\.sum).reduce(0, +)

        XCTAssertEqual(headline, bars,
                       "the headline and the bars must describe the same week")
        XCTAssertEqual(headline, 50_000,
                       "day 3 falls outside the seven days ending on day 10")
    }

    // MARK: - Derived.DateWindow / inWindow

    private func onDay(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(
                        year: year, month: month, day: day, hour: hour))!,
                    kind: .expense, category: "Продукти", merchant: "Гастроном-Приклад",
                    amount: -100_00, cardSuffix: "*0000", bankId: "monobank",
                    receiptId: nil, splits: [], resolution: .rule, suggestions: [])
    }

    /// The value `StatsView` hands to its drill-through, so that "what the
    /// drill lists" and "what the slice summed" are one computation rather
    /// than two that agree by inspection. Both ends of the week window are
    /// INCLUSIVE days, and the day before it is not.
    func testTheWeekWindowIsSevenWholeKyivDaysEndingOnTheAnchor() {
        let anchor = Calendar.kyiv.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 12))!
        let window = Derived.DateWindow(weekEndingAt: anchor)

        let before = onDay(2026, 8, 3, hour: 23)   // outside, by one day
        let first = onDay(2026, 8, 4, hour: 0)     // the window's first day
        let middle = onDay(2026, 8, 7)
        let last = onDay(2026, 8, 10, hour: 23)    // the anchor's own day, late
        let after = onDay(2026, 8, 11, hour: 0)    // outside, by one day

        let rows = [before, first, middle, last, after]
        XCTAssertEqual(Derived.inWindow(rows, window).map(\.id),
                       [first, middle, last].map(\.id))
        // A late hour on the anchor's own day is IN — the window is days,
        // not `anchor − 7 × 24h`, which would cut this one out.
        XCTAssertTrue(window.contains(last.date))
        XCTAssertFalse(window.contains(before.date))
        XCTAssertFalse(window.contains(after.date))
    }

    /// A month window must select exactly what `inMonth` selects, or the
    /// «Місяць» scope and its drill would answer differently from the rest
    /// of the app.
    func testTheMonthWindowSelectsExactlyWhatInMonthSelects() {
        let rows = [onDay(2026, 7, 31, hour: 23), onDay(2026, 8, 1, hour: 0),
                    onDay(2026, 8, 31, hour: 23), onDay(2026, 9, 1, hour: 0)]
        let august = MonthKey(year: 2026, month: 8)

        XCTAssertEqual(Derived.inWindow(rows, Derived.DateWindow(august)).map(\.id),
                       Derived.inMonth(rows, august).map(\.id))
        XCTAssertEqual(Derived.inWindow(rows, Derived.DateWindow(august)).count, 2,
                       "precondition: the fixture straddles both month boundaries")
    }

    /// nil is "no period filter", not "no rows" — «Рік» sends nil and means
    /// the whole dataset.
    func testANilWindowFiltersNothing() {
        let rows = [onDay(2026, 1, 4), onDay(2026, 8, 19)]
        XCTAssertEqual(Derived.inWindow(rows, nil).map(\.id), rows.map(\.id))
    }
}
