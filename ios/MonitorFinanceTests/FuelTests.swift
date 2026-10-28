import XCTest
@testable import MonitorFinance

final class FuelTests: XCTestCase {

    // MARK: - FuelGrade.parse

    /// Every grade the brief lists, each read out of a realistic line —
    /// including one where the grade sits inside a longer name rather than
    /// being the whole string.
    func testEveryListedGradeParsesIncludingInsideALongerName() {
        let cases: [(name: String, expected: String)] = [
            ("Бензин А-92", "А-92"),
            ("Бензин А-95", "А-95"),
            ("Бензин А-98", "А-98"),
            ("Бензин А-100", "А-100"),
            ("Дизельне паливо ДП", "ДП"),
            ("Дизельне паливо ДТ", "ДТ"),
            ("Газ скраплений", "ГАЗ"),
            ("Паливо LPG", "LPG"),
            ("Бензин автомобільний А-95-Євро5-Е10", "А-95"),
        ]
        for c in cases {
            XCTAssertEqual(FuelGrade.parse(c.name), c.expected, c.name)
        }
    }

    /// `А-100`'s digits begin the same way a hypothetical shorter `А-10`
    /// would, so a shortest-first (or unsorted) token scan risks stopping
    /// at the wrong length. Longest-match-first, the rule `ProductGuess`
    /// already relies on, must read the whole `100`.
    func testLongestGradeWinsAndA100IsNeverReadAsA10() {
        XCTAssertEqual(FuelGrade.parse("Бензин А-100"), "А-100")
        XCTAssertNotEqual(FuelGrade.parse("Бензин А-100"), "А-10")
    }

    /// A line that is not fuel at all — no grade token appears anywhere —
    /// must fall to nil, not to whichever grade happens to be checked first.
    func testANonFuelNameReturnsNil() {
        XCTAssertNil(FuelGrade.parse("Кава американо"))
        XCTAssertNil(FuelGrade.parse("Вода 0,33 л"))
    }

    /// The false positive that motivated whole-token matching: the seed's
    /// own corner-shop receipt carries a bottle of STILL water named
    /// `«Вода негазована 0,5 л»` — and `негазована` contains `газ` as a raw
    /// substring (the irony being that the word means the opposite of
    /// carbonated). Loaded from the real seed rather than typed into a
    /// fixture, because it is the exact string that ships, and a
    /// hand-typed fixture could quietly drift away from it and stop
    /// proving anything.
    func testStillWaterFromTheSeedDoesNotParseAsAGrade() throws {
        let seed = try SeedLoader.load()
        let waterItems = seed.receipts.flatMap(\.items).filter { $0.name == "Вода негазована 0,5 л" }
        guard !waterItems.isEmpty else {
            return XCTFail("expected the seed to still ship «Вода негазована 0,5 л» — this test needs that exact line")
        }
        for water in waterItems {
            XCTAssertNil(FuelGrade.parse(water.name))
        }
    }

    /// Every fixture above puts the grade at the END or in the MIDDLE of the
    /// name, so nothing proved the leading `\b` in `\bтокен\b` actually
    /// matches at position 0. It does — `\b` sits between a word character
    /// and a non-word character OR a string boundary — but "it does" was an
    /// unproven claim, and a pattern that required a real character before
    /// the token (`.\bтокен\b`, an easy mistake when hardening a matcher)
    /// would have passed every other test in this file.
    ///
    /// Receipt lines really do start with the grade: `А-95 Євро5, 10 л` is
    /// how plenty of Ukrainian stations print the pump line.
    func testAGradeAtTheVeryStartOfTheNameStillParses() {
        XCTAssertEqual(FuelGrade.parse("А-95 Євро5, 10 л"), "А-95")
        XCTAssertEqual(FuelGrade.parse("ДП Євро5"), "ДП")
        XCTAssertEqual(FuelGrade.parse("LPG пропан-бутан"), "LPG")
        // The whole string being nothing but the grade is the same boundary
        // question at both ends at once.
        XCTAssertEqual(FuelGrade.parse("А-100"), "А-100")
    }

    /// `ДП` and `ДТ` are the same shape of risk as `газ`/`негазована` —
    /// two letters that also spell the start of an ordinary word — they
    /// just have not landed on a seed line. `ДТП` (a road accident) and
    /// `ДПС` (the old traffic-police abbreviation) are real, unremarkable
    /// Ukrainian words that happen to start with a grade's letters.
    func testDPAndDTInsideOrdinaryWordsDoNotMatch() {
        XCTAssertNil(FuelGrade.parse("Довідка про ДТП"))
        XCTAssertNil(FuelGrade.parse("Патруль ДПС"))
    }

    // MARK: - fixtures

    private func tx(date: Date, receiptId: UUID?, amount: Int = -1) -> Transaction {
        Transaction(id: UUID(), date: date, kind: .expense, category: "Автомобіль",
                    merchant: "АЗС-Приклад", amount: amount, cardSuffix: "*0000",
                    bankId: "monobank", receiptId: receiptId, splits: [], resolution: .rule,
                    suggestions: [])
    }

    private func receipt(id: UUID = UUID(), seller: String = "АЗС «Приклад»",
                         fiscalTime: Date, items: [Receipt.Item]) -> Receipt {
        Receipt(id: id, scannedAt: fiscalTime, registerNumber: "3000000001",
                documentNumber: "1000000001", fiscalTime: fiscalTime, fiscalSum: items.reduce(0) { $0 + $1.sum },
                sellerName: seller, items: items)
    }

    private func item(_ name: String, qty: Double, price: Int, sum: Int) -> Receipt.Item {
        Receipt.Item(id: UUID(), name: name, qty: qty, price: price, sum: sum, category: nil)
    }

    // MARK: - Derived.fillUps

    /// Reads litres from `qty`, ₴/l from `price`, total from `sum`, station
    /// from the receipt's `displaySeller`, and grade from `FuelGrade.parse` —
    /// and takes its DATE from the transaction, not the receipt's
    /// `fiscalTime`: the transaction is what every other screen sorts and
    /// filters by, so a receipt scanned on a different day from the pump
    /// visit must not jump the log to the scan date.
    ///
    /// The receipt also carries a non-fuel line (water) alongside the fuel
    /// one, so an implementation that emits every item — rather than only
    /// the ones `FuelGrade.parse`s — is caught here.
    func testFillUpsReadsFieldsFromTheRightPlacesAndSkipsNonFuelLines() {
        let fiscalTime = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 8))!
        let txDate = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 11, minute: 3))!

        let r = receipt(seller: "АЗС «Приклад»", fiscalTime: fiscalTime, items: [
            item("Вода 0,33 л", qty: 1, price: 2500, sum: 2500),
            item("Бензин А-95-Євро5", qty: 12.4, price: 7450, sum: 92380),
        ])
        let t = tx(date: txDate, receiptId: r.id)

        let fills = Derived.fillUps([t], receipts: [r])

        guard fills.count == 1 else {
            return XCTFail("expected exactly one fill-up (the water line must be skipped), got \(fills.count)")
        }
        let fill = fills[0]
        XCTAssertEqual(fill.grade, "А-95")
        XCTAssertEqual(fill.litres, 12.4, "litres come from qty")
        XCTAssertEqual(fill.pricePerLitre, 7450, "price per litre comes from price")
        XCTAssertEqual(fill.total, 92380, "total comes from sum")
        XCTAssertEqual(fill.station, "АЗС «Приклад»", "station comes from the receipt's displaySeller")
        XCTAssertEqual(fill.date, txDate, "date comes from the TRANSACTION, not the receipt's fiscalTime")
        XCTAssertNotEqual(fill.date, fiscalTime)
    }

    /// A receipt that is not attached to any transaction — a scanner sample
    /// the owner never matched to a card charge — contributes no fill-up: it
    /// has no transaction to take a date from.
    func testAnUnattachedReceiptContributesNoFillUp() {
        let fiscalTime = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 8))!
        let r = receipt(fiscalTime: fiscalTime, items: [
            item("Бензин А-95-Євро5", qty: 12.4, price: 7450, sum: 92380),
        ])
        // No transaction points at `r`.
        let other = tx(date: fiscalTime, receiptId: nil)

        XCTAssertEqual(Derived.fillUps([other], receipts: [r]), [])
    }

    /// The unit-level `testStillWaterFromTheSeedDoesNotParseAsAGrade` proves
    /// `FuelGrade.parse` alone; this proves the same thing one layer up,
    /// through `fillUps` — a different function that could, in principle,
    /// filter differently (or not at all) even with a correct `parse`
    /// underneath it. This repo has been bitten before by proving one layer
    /// and assuming the other agrees.
    func testFillUpsSkipsTheSeedsStillWaterReceiptEvenWhenAttachedToATransaction() throws {
        let seed = try SeedLoader.load()
        guard let corner = seed.receipts.first(where: {
            $0.items.contains { $0.name == "Вода негазована 0,5 л" }
        }) else {
            return XCTFail("expected the seed to still ship the corner-shop water receipt")
        }
        // Attach it to a transaction so `fillUps` actually visits its items —
        // in the real seed this receipt is unattached, which would already
        // exclude it for the unrelated reason task 8's other test covers.
        let t = tx(date: Date(), receiptId: corner.id)

        XCTAssertEqual(Derived.fillUps([t], receipts: [corner]), [],
                       "still water (and the snack bar beside it) must not become a fill-up")
    }

    /// `fillUps` indexes `receipts` by id. It used to do so with
    /// `Dictionary(uniqueKeysWithValues:)`, which does not "prefer one" on a
    /// duplicate key — it TRAPS, taking the whole app down. Nothing in the
    /// shipped store can produce two receipts under one id (`attach` removes
    /// any same-id record before appending), but `Derived` is the pure
    /// arithmetic every screen reads without checking its input, and a crash
    /// is a worse answer to a malformed store than an arbitrary pick.
    ///
    /// Reaching this line at all is the assertion: under the old spelling
    /// this test does not fail, it kills the test process.
    func testFillUpsSurvivesTwoReceiptsSharingOneId() {
        let day = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 11))!
        let shared = UUID()
        let first = receipt(id: shared, fiscalTime: day, items: [
            item("Бензин А-95-Євро5", qty: 10, price: 8000, sum: 80000),
        ])
        let second = receipt(id: shared, fiscalTime: day, items: [
            item("Бензин А-92", qty: 5, price: 7000, sum: 35000),
        ])
        let t = tx(date: day, receiptId: shared)

        let fills = Derived.fillUps([t], receipts: [first, second])

        XCTAssertEqual(fills.count, 1, "one transaction, one receipt id, one fill-up")
        XCTAssertEqual(fills.first?.grade, "А-95", "first one wins, deterministically")
        XCTAssertEqual(fills.first?.total, 80000)
    }

    // MARK: - Derived.fuelSummary

    /// `averagePerLitre` is WEIGHTED — total ₴ ÷ total litres — not the mean
    /// of the two per-litre prices. A 5-litre top-up and a 45-litre fill do
    /// not carry equal weight, so the fixture below uses fills of different
    /// SIZES and different PRICES: with equal litres the weighted and
    /// unweighted answers are identical and the test would prove nothing.
    func testFuelSummaryAveragesByWeightOfLitresNotByMeanOfPrices() {
        let day = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))!
        let fills = [
            Derived.FillUp(id: UUID(), date: day, station: "АЗС «Приклад»",
                           grade: "А-95", litres: 5, pricePerLitre: 8000, total: 40000),
            Derived.FillUp(id: UUID(), date: day, station: "АЗС «Приклад»",
                           grade: "А-95", litres: 45, pricePerLitre: 7000, total: 315000),
        ]

        let summary = Derived.fuelSummary(fills)

        let unweightedMean = fills.map(\.pricePerLitre).reduce(0, +) / fills.count
        XCTAssertEqual(unweightedMean, 7500, "sanity check on the fixture's own arithmetic")

        XCTAssertEqual(summary?.litres, 50)
        XCTAssertEqual(summary?.total, 355000)
        XCTAssertEqual(summary?.averagePerLitre, 7100,
                       "weighted: 355000 ÷ 50 litres, not the mean of 8000 and 7000")
        XCTAssertNotEqual(summary?.averagePerLitre, unweightedMean,
                          "an unweighted mean would give 7500 — this fixture must tell the two apart")
    }

    /// nil for an empty list, so the caller can hide the whole card instead
    /// of rendering one with a zero litre count and a zero average in it.
    func testFuelSummaryIsNilForAnEmptyList() {
        XCTAssertNil(Derived.fuelSummary([]))
    }

    /// Every other fixture in this file divides EXACTLY (355000 ÷ 50, 80000 ÷
    /// 10), so `(…).rounded()` and a plain truncating `Int(…)` give the same
    /// answer everywhere and the doc comment's promise of "rounded" was
    /// untested. 200,00 ₴ over 3 litres is 66,6666… ₴/л: rounding says 66,67
    /// and truncation says 66,66. One kopeck, but it is the difference
    /// between the card stating the average and the card understating it,
    /// every time the litres are not a round divisor — which, at a pump, is
    /// nearly always.
    func testAveragePerLitreRoundsRatherThanTruncates() {
        let day = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))!
        let fills = [
            Derived.FillUp(id: UUID(), date: day, station: "АЗС «Приклад»",
                           grade: "А-95", litres: 3, pricePerLitre: 6667, total: 200_00),
        ]

        let summary = Derived.fuelSummary(fills)

        XCTAssertEqual(summary?.litres, 3)
        XCTAssertEqual(summary?.total, 200_00)
        XCTAssertEqual(summary?.averagePerLitre, 66_67,
                       "200,00 ₴ ÷ 3 л = 66,6666… — rounded up to 66,67")
        XCTAssertNotEqual(summary?.averagePerLitre, 66_66,
                          "truncation would give 66,66; this fixture exists to tell the two apart")
    }

    // MARK: - against the seed

    /// The seed's own fuel purchase: 10,00 л at 80,00 ₴/л on a transaction
    /// dated 2026-08-19, pre-attached via receiptId. The seed also ships a
    /// second fuel receipt (12,40 л at 74,50 ₴/л, a scanner sample) that no
    /// transaction points at, so it must not appear here.
    func testAgainstTheSeededFillUp() throws {
        let seed = try SeedLoader.load()
        let fills = Derived.fillUps(seed.transactions, receipts: seed.receipts)

        XCTAssertEqual(fills.count, 1, "only the attached receipt is a fill-up")
        let fill = try XCTUnwrap(fills.first)
        XCTAssertEqual(fill.grade, "А-95")
        XCTAssertEqual(fill.litres, 10.0)
        XCTAssertEqual(fill.pricePerLitre, 8000)
        XCTAssertEqual(fill.total, 80000)
    }
}
