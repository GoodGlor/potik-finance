import XCTest
@testable import MonitorFinance

/// Board #101 — statistics scoped to a bank, or to one card.
///
/// The statistics tab summed every bank together, so a person with a personal
/// card and a household one could not ask about either.
final class StatsSourceTests: XCTestCase {

    private func tx(_ bankId: String, _ suffix: String, amount: Int = -100_00,
                    days: Int = 0) -> Transaction {
        Transaction(id: UUID(), date: Date(timeIntervalSince1970: 1_756_800_000)
                        .addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: amount > 0 ? .income : .expense, category: "Продукти",
                    merchant: "Крамниця-Приклад", amount: amount, cardSuffix: suffix,
                    bankId: bankId, receiptId: nil, splits: [], resolution: .user,
                    suggestions: [])
    }

    private var rows: [Transaction] {
        [tx("monobank", "*1111"), tx("monobank", "*2222", days: 1),
         tx("privatbank", "5*99", days: 2), tx("privatbank", "*2299", days: 3)]
    }

    private var banks: [Bank] {
        [Bank(id: "monobank", displayName: "monobank", status: .available,
              connected: true, accounts: []),
         Bank(id: "privatbank", displayName: "ПриватБанк", status: .statement,
              connected: true, accounts: [])]
    }

    // MARK: the filter

    func testAllIsEverything() {
        XCTAssertEqual(Derived.bySource(rows, .all).count, 4)
    }

    func testABankKeepsOnlyItsRows() {
        let kept = Derived.bySource(rows, .bank("privatbank"))
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.allSatisfy { $0.bankId == "privatbank" })
    }

    func testACardKeepsOnlyThatCard() {
        let kept = Derived.bySource(rows, .card(bank: "monobank", suffix: "*1111"))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.cardSuffix, "*1111")
    }

    /// **The card scope carries its bank, and this is why.**
    ///
    /// Two banks can mask two different cards to the same digits — a known
    /// issue in this repo, where a cross-bank suffix collision already shares
    /// one feed chip. A card scope keyed on the suffix alone would sum both
    /// banks' rows into one chart, and nothing on screen could show it.
    func testTwoBanksWithTheSameSuffixDoNotBleedIntoOneCard() {
        let collided = [tx("monobank", "*9999"), tx("privatbank", "*9999", days: 1)]
        let kept = Derived.bySource(collided, .card(bank: "monobank", suffix: "*9999"))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.bankId, "monobank")
    }

    func testAnUnknownBankMatchesNothingRatherThanEverything() {
        XCTAssertEqual(Derived.bySource(rows, .bank("oschadbank")).count, 0)
    }

    // MARK: what is offered

    func testEveryBankIsOfferedBeneathAll() {
        let options = Derived.sourceOptions(rows, banks)
        XCTAssertEqual(options.first, .all)
        XCTAssertTrue(options.contains(.bank("monobank")))
        XCTAssertTrue(options.contains(.bank("privatbank")))
    }

    func testABanksCardsAreOfferedWhenItHasMoreThanOne() {
        let options = Derived.sourceOptions(rows, banks)
        XCTAssertTrue(options.contains(.card(bank: "monobank", suffix: "*1111")))
        XCTAssertTrue(options.contains(.card(bank: "privatbank", suffix: "5*99")))
    }

    /// **A level that selects the same rows as the one above it is not
    /// offered**, and this is the case that found the rule: with two banks,
    /// one of which has a single card, that card row would sum exactly what
    /// its bank row sums.
    func testABankWithOneCardOffersNoCardRow() {
        let mixed = [tx("monobank", "*1111"), tx("monobank", "*1111", days: 1),
                     tx("privatbank", "5*99", days: 2), tx("privatbank", "*2299", days: 3)]
        let options = Derived.sourceOptions(mixed, banks)
        XCTAssertFalse(options.contains(.card(bank: "monobank", suffix: "*1111")))
        XCTAssertTrue(options.contains(.card(bank: "privatbank", suffix: "5*99")),
                      "the bank that HAS two cards still offers them")
    }

    /// A row with no card contributes no card option; its bank still does.
    func testARowWithoutACardContributesNoCardOption() {
        let mixed = [tx("monobank", ""), tx("privatbank", "5*99", days: 1)]
        let options = Derived.sourceOptions(mixed, banks)
        XCTAssertEqual(options, [.all, .bank("monobank"), .bank("privatbank")])
    }

    /// **One bank is not listed, because `.all` already IS that bank.** The
    /// first version listed it, giving the menu two entries that select
    /// identical rows — found here rather than by reasoning.
    func testASingleSourceOffersOnlyAllSoTheControlCanHide() {
        XCTAssertEqual(Derived.sourceOptions([tx("monobank", "*1111")], banks), [.all])
    }

    /// One bank with several cards still offers the cards — `.all` is the bank,
    /// and the cards are a real cut beneath it.
    func testOneBankWithSeveralCardsOffersTheCardsAndNotTheBank() {
        let single = [tx("monobank", "*1111"), tx("monobank", "*2222", days: 1)]
        XCTAssertEqual(Derived.sourceOptions(single, banks),
                       [.all, .card(bank: "monobank", suffix: "*1111"),
                        .card(bank: "monobank", suffix: "*2222")])
    }

    func testNoTransactionsOffersOnlyAll() {
        XCTAssertEqual(Derived.sourceOptions([], banks), [.all])
    }

    /// Banks are ordered by the name shown, not by id, so the menu reads in
    /// the order the person sees.
    func testBanksAreOrderedByTheNameShown() {
        let options = Derived.sourceOptions(rows, banks)
        let bankRows = options.compactMap { option -> String? in
            if case .bank(let id) = option { return id }
            return nil
        }
        XCTAssertEqual(bankRows, ["monobank", "privatbank"],
                       "«monobank» sorts before «ПриватБанк» by name, Latin before Cyrillic")
    }

    // MARK: the charts actually follow it

    /// The scope reaches the numbers, not just the menu — `byCategory` is what
    /// the donut and the share list are both drawn from.
    func testTheCategoryTotalsFollowTheScope() {
        let all = Derived.byCategory(Derived.bySource(rows, .all))
        let one = Derived.byCategory(Derived.bySource(rows, .bank("monobank")))
        XCTAssertEqual(all.first?.sum, 400_00)
        XCTAssertEqual(one.first?.sum, 200_00)
    }
}
