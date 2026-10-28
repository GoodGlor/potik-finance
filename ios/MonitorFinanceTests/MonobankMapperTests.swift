import XCTest
@testable import MonitorFinance

/// What is pinned here, and what is not:
///
/// * CORPUS-PINNED (71 synthetic rows, structural fields only): `id` derivation,
///   the epoch→Date conversion, the sign→kind rule, `amount`, `hold`.
/// * HAND-PINNED (below): `receiptId`, `balance` and `comment` appear in ZERO
///   of the 71 corpus rows, so a corpus-only suite would prove nothing about
///   them while looking exhaustive.
final class MonobankMapperTests: XCTestCase {

    private let account = MonobankAccount(
        id: "acc", type: "black", currencyCode: 980,
        balance: 0, creditLimit: 0, maskedPan: ["000000******1234"])

    private func decode(_ json: String) throws -> MonobankStatementItem {
        try JSONDecoder().decode(MonobankStatementItem.self, from: Data(json.utf8))
    }

    func testEveryCorpusRowMapsAsPythonSaysItShould() throws {
        XCTAssertEqual(MonobankMapperFixture.cases.count, 71)
        for c in MonobankMapperFixture.cases {
            let item = try decode(c.json)
            let tx = MonobankMapper.transaction(item, account: account)
            XCTAssertEqual(tx.id.uuidString.lowercased(), c.uuid.lowercased())
            XCTAssertEqual(Int(tx.date.timeIntervalSince1970), c.time)
            XCTAssertEqual(tx.amount, c.amount)
            XCTAssertEqual(tx.kind.rawValue, c.kind)
            XCTAssertEqual(tx.merchant, c.merchant)
            XCTAssertEqual(tx.hold, c.hold)
            XCTAssertEqual(tx.mcc, item.mcc, "the code the bank sent, unchanged")
            XCTAssertEqual(tx.originalMcc, item.originalMcc,
                           "and the code the NETWORK sent, also unchanged")
        }
    }

    func testTheCorpusActuallyContainsBothSignsAndAHeldRow() {
        XCTAssertTrue(MonobankMapperFixture.cases.contains { $0.kind == "income" })
        XCTAssertTrue(MonobankMapperFixture.cases.contains { $0.kind == "expense" })
        XCTAssertTrue(MonobankMapperFixture.cases.contains { $0.hold },
                      "no held row means the settlement path is untested")
    }

    /// Without this the MCC assertion in the corpus loop could be comparing
    /// `nil` to `nil` for all 71 rows and still read as exhaustive.
    func testTheCorpusActuallyCarriesMoreThanOneMCC() throws {
        let codes = Set(try MonobankMapperFixture.cases.compactMap { try decode($0.json).mcc })
        XCTAssertGreaterThan(codes.count, 1, "one code, or none, proves nothing about passthrough")
    }

    /// Board #56's whole premise, asserted rather than assumed: if the corpus
    /// held only rows where the two codes agree, carrying both would be dead
    /// weight and the loop above would pass while reading one field twice.
    ///
    /// **15 of the 71 rows are recoded, and three of those are domestic.**
    /// The card called this the cross-border case, and the first version of
    /// this test asserted that — it failed. Twelve rows are the 7829/4899
    /// subscription in EUR, but 5262→5399 and 5499→5411 are UAH, and the
    /// second of those is the pair a category actually turns on: 5499 is
    /// «miscellaneous food», 5411 is a grocery. So the field is not a foreign
    /// -currency nicety; it changes the answer on rows in the person's own
    /// currency too.
    func testTheCorpusActuallyCarriesRowsTheBankRecoded() throws {
        let items = try MonobankMapperFixture.cases.map { try decode($0.json) }
        let recoded = items.filter {
            $0.mcc != nil && $0.originalMcc != nil && $0.mcc != $0.originalMcc
        }
        XCTAssertEqual(recoded.count, 15,
                       "no divergent row means the second field is provably useless")
        XCTAssertTrue(recoded.contains { $0.currencyCode == 980 },
                      "domestic rows are recoded too — see this test's docstring")
        XCTAssertTrue(items.allSatisfy { $0.originalMcc != nil },
                      "the live API sends it on every card row; absent is the odd case")
    }

    // MARK: hand-pinned — absent from every corpus row

    func testMonobankReceiptIdIsDecodedAndDropped() throws {
        let item = try decode(#"{"id":"a","time":1,"description":"x","amount":-1,"receiptId":"mono-1"}"#)
        XCTAssertEqual(item.monoReceiptId, "mono-1")
        let tx = MonobankMapper.transaction(item, account: account)
        XCTAssertNil(tx.receiptId, "monobank's receipt reference is NOT a local Receipt id")
    }

    func testCounterNameIsDecodedAndNeverStored() throws {
        let item = try decode(#"{"id":"a","time":1,"description":"x","amount":-1,"counterName":"Реальна Людина"}"#)
        XCTAssertEqual(item.counterName, "Реальна Людина")
        let tx = MonobankMapper.transaction(item, account: account)
        let encoded = String(decoding: try SeedLoader.encoder.encode(tx), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Реальна"), "a counterparty's name must not reach storage")
    }

    func testBalanceIsDecodedAndNotStored() throws {
        let item = try decode(#"{"id":"a","time":1,"description":"x","amount":-1,"balance":50000}"#)
        XCTAssertEqual(item.balance, 50_000)
        XCTAssertEqual(MonobankMapper.transaction(item, account: account).amount, -1)
    }

    /// monobank omits `mcc` on rows that never touched a card network — a
    /// jar top-up, an incoming transfer. Absent must stay absent: a zero or a
    /// stand-in code would be indistinguishable from a real one to whatever
    /// reads this next.
    func testAnAbsentMCCStaysNil() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"a","time":1,"description":"x","amount":-1}"#), account: account)
        XCTAssertNil(tx.mcc)
    }

    /// The field only earns its keep if it survives the file. `hold` is
    /// asserted alongside it so a coder change that drops trailing optionals
    /// wholesale cannot pass by leaving both nil.
    func testMCCSurvivesTheRoundTripThroughStorage() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"a","time":1,"description":"x","amount":-1,"mcc":5411}"#),
            account: account)
        XCTAssertEqual(tx.mcc, 5411)
        let reloaded = try SeedLoader.decoder.decode(
            Transaction.self, from: SeedLoader.encoder.encode(tx))
        XCTAssertEqual(reloaded.mcc, 5411)
        XCTAssertEqual(reloaded.hold, false)
    }

    /// Every `transactions.json` already on a device was written without this
    /// key. A non-optional `mcc` would make all of them throw `keyNotFound`,
    /// and the Release fallback for a failed decode is an empty array — the
    /// person's whole history, gone with no error and no log.
    func testATransactionWrittenBeforeThisFieldStillDecodes() throws {
        let old = """
        {"id":"\(UUID().uuidString)","date":"2026-08-01T10:00:00Z","kind":"expense",\
        "category":"Продукти","merchant":"Маркет-Приклад","amount":-12000,"cardSuffix":"*1234",\
        "bankId":"monobank","splits":[],"resolution":"user","suggestions":[],\
        "externalId":"a","hold":false}
        """
        let tx = try SeedLoader.decoder.decode(Transaction.self, from: Data(old.utf8))
        XCTAssertNil(tx.mcc)
        XCTAssertEqual(tx.amount, -12_000, "the rest of the row must decode too")
    }

    /// Absent must stay absent rather than be filled in from `mcc`. Copying
    /// the rewritten code into the field that means "before the rewrite"
    /// would make the two indistinguishable exactly where they differ — and
    /// silently, since 56 of the corpus's 71 rows do agree.
    func testAnAbsentOriginalMCCStaysNilRatherThanCopyingTheBanksCode() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"a","time":1,"description":"x","amount":-1,"mcc":5411}"#),
            account: account)
        XCTAssertEqual(tx.mcc, 5411)
        XCTAssertNil(tx.originalMcc)
    }

    /// The pair that matters, end to end: the bank rewrote 4899 to 7829, both
    /// survive the mapper, and both survive the file.
    func testARecodedRowKeepsBothCodesThroughStorage() throws {
        let tx = MonobankMapper.transaction(
            try decode("""
            {"id":"a","time":1,"description":"x","amount":-24337,\
            "mcc":7829,"originalMcc":4899,"currencyCode":978}
            """),
            account: account)
        XCTAssertEqual(tx.mcc, 7829)
        XCTAssertEqual(tx.originalMcc, 4899)

        let reloaded = try SeedLoader.decoder.decode(
            Transaction.self, from: SeedLoader.encoder.encode(tx))
        XCTAssertEqual(reloaded.mcc, 7829)
        XCTAssertEqual(reloaded.originalMcc, 4899)
    }

    /// The intermediate shape, which is the one most devices are actually on:
    /// written after `mcc` shipped and before `originalMcc` did. It must
    /// decode with the older code intact rather than take the file down.
    func testARowWrittenBetweenTheTwoMCCFieldsStillDecodes() throws {
        let old = """
        {"id":"\(UUID().uuidString)","date":"2026-08-01T10:00:00Z","kind":"expense",\
        "category":"Продукти","merchant":"Маркет-Приклад","amount":-12000,"cardSuffix":"*1234",\
        "bankId":"monobank","splits":[],"resolution":"user","suggestions":[],\
        "externalId":"a","hold":false,"mcc":5411}
        """
        let tx = try SeedLoader.decoder.decode(Transaction.self, from: Data(old.utf8))
        XCTAssertEqual(tx.mcc, 5411)
        XCTAssertNil(tx.originalMcc)
    }

    func testAnAbsentHoldMeansFalseRatherThanNil() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"a","time":1,"description":"x","amount":-1}"#), account: account)
        XCTAssertEqual(tx.hold, false)
    }

    // MARK: the conversions the spec writes down

    func testCardSuffixIsAStarAndTheLastFour() {
        XCTAssertEqual(MonobankMapper.cardSuffix(account), "*1234")
    }

    func testAnAccountWithNoMaskedPanGivesAnEmptySuffix() {
        var a = account; a.maskedPan = nil
        XCTAssertEqual(MonobankMapper.cardSuffix(a), "")
        a.maskedPan = []
        XCTAssertEqual(MonobankMapper.cardSuffix(a), "")
    }

    func testOnly980MapsToACurrency() {
        XCTAssertEqual(MonobankMapper.currency(980), "UAH")
        XCTAssertNil(MonobankMapper.currency(840), "an unmapped code must refuse, not fall back")
    }

    // MARK: the defaults a new row carries

    func testAnExpenseArrivesUndecidedAndUncategorised() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"a","time":1,"description":" Продавець ","amount":-34000}"#),
            account: account)
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.category, "")
        XCTAssertEqual(tx.resolution, .pending)
        XCTAssertEqual(tx.suggestions, [])
        XCTAssertEqual(tx.splits, [])
        XCTAssertEqual(tx.merchant, "Продавець", "the description is trimmed")
        XCTAssertEqual(tx.externalId, "a")
        XCTAssertEqual(tx.bankId, "monobank")
        XCTAssertEqual(tx.cardSuffix, "*1234")
    }

    /// The failure this default exists to prevent: `BudgetMath.income(_:
    /// includeGifts: false)` counts only `earnedCategories`, so an income row
    /// with an empty category contributes ZERO and the default plan divides a
    /// 100% budget by an income of nothing.
    func testIncomeArrivesInACategoryTheBudgetActuallyCounts() throws {
        let tx = MonobankMapper.transaction(
            try decode(#"{"id":"b","time":1,"description":"Надходження","amount":250000}"#),
            account: account)
        XCTAssertEqual(tx.kind, .income)
        XCTAssertEqual(tx.category, BudgetMath.defaultIncomeCategory)
        let seeded = try SeedLoader.load().categories
        XCTAssertTrue(BudgetMath.earnedCategories(seeded).contains(BudgetMath.defaultIncomeCategory))
        XCTAssertGreaterThan(BudgetMath.income([tx], includeGifts: false, categories: seeded), 0)
    }
}
