import XCTest
@testable import MonitorFinance

/// Board #104 — a queue card says which direction, which bank and which card.
///
/// The complaint was that you cannot tell an expense from an arrival at a
/// glance, nor see which card you are being asked about. Both were true: the
/// direction was a single «+» buried in a grey line, and the bank was nowhere.
@MainActor
final class QueueCardIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_800_000)

    private func tx(_ merchant: String, amount: Int = -100_00, days: Int = 0,
                    bankId: String = "monobank", suffix: String = "*1111") -> Transaction {
        Transaction(id: UUID(), date: now.addingTimeInterval(TimeInterval(-days * 86_400)),
                    kind: amount > 0 ? .income : .expense, category: "",
                    merchant: merchant, amount: amount, cardSuffix: suffix,
                    bankId: bankId, receiptId: nil, splits: [], resolution: .pending,
                    suggestions: [])
    }

    private var banks: [Bank] {
        [Bank(id: "monobank", displayName: "monobank", status: .available,
              connected: true, accounts: []),
         Bank(id: "privatbank", displayName: "ПриватБанк", status: .statement,
              connected: true, accounts: [])]
    }

    private func group(_ rows: [Transaction]) throws -> MerchantGroup {
        let groups = AppStore.groups(rows)
        return try XCTUnwrap(groups.first)
    }

    // MARK: what the group now carries

    func testAGroupRemembersItsBankAndCard() throws {
        let g = try group([tx("Крамниця-Приклад"), tx("Крамниця-Приклад", days: 1)])
        XCTAssertEqual(g.bankIds, ["monobank"])
        XCTAssertEqual(g.cardSuffixes, ["*1111"])
    }

    /// **A group is a merchant AND a kind, never a card.** The same shop paid
    /// from two cards is ONE question with one answer — and the person being
    /// asked should be able to see that it spans two.
    func testAGroupSpanningTwoCardsRemembersBoth() throws {
        let g = try group([tx("Крамниця-Приклад", suffix: "*1111"),
                           tx("Крамниця-Приклад", days: 1, suffix: "*2222")])
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.cardSuffixes, ["*1111", "*2222"])
    }

    /// Sorted and unique, so the mark does not depend on which row was read
    /// first — a group built in a different order must show the same thing.
    func testTheMarkDoesNotDependOnRowOrder() throws {
        let a = try group([tx("Крамниця-Приклад", suffix: "*2222"),
                           tx("Крамниця-Приклад", days: 1, suffix: "*1111")])
        let b = try group([tx("Крамниця-Приклад", suffix: "*1111"),
                           tx("Крамниця-Приклад", days: 1, suffix: "*2222")])
        XCTAssertEqual(a.cardSuffixes, b.cardSuffixes)
    }

    func testARowWithNoCardContributesNoSuffix() throws {
        let g = try group([tx("Крамниця-Приклад", suffix: "")])
        XCTAssertEqual(g.cardSuffixes, [])
        XCTAssertEqual(g.bankIds, ["monobank"])
    }

    // MARK: the mark

    func testOneBankOneCardNamesBoth() {
        XCTAssertEqual(BankMark.group(bankIds: ["monobank"], suffixes: ["*1111"], banks, .uk),
                       "monobank · *1111")
    }

    /// Two cards are counted, not listed: listing both would be longer, would
    /// not fit, and would suggest two questions where there is one.
    func testTwoCardsAreCountedRatherThanListed() {
        let mark = BankMark.group(bankIds: ["monobank"], suffixes: ["*1111", "*2222"], banks, .uk)
        XCTAssertEqual(mark, "monobank · 2 картки")
        XCTAssertFalse(mark.contains("*1111"))
    }

    /// The card count is copy and follows the language; the bank's name does
    /// not, because a bank's name is data.
    func testTheCardCountFollowsTheLanguageAndTheBankNameDoesNot() {
        let uk = BankMark.group(bankIds: ["monobank"], suffixes: ["*1111", "*2222"], banks, .uk)
        let en = BankMark.group(bankIds: ["monobank"], suffixes: ["*1111", "*2222"], banks, .en)
        XCTAssertNotEqual(uk, en, "«2 картки» must become «2 cards»")
        XCTAssertTrue(uk.hasPrefix("monobank"))
        XCTAssertTrue(en.hasPrefix("monobank"))
    }

    func testACardlessGroupStillNamesItsBank() {
        XCTAssertEqual(BankMark.group(bankIds: ["privatbank"], suffixes: [], banks, .uk),
                       "ПриватБанк")
    }

    /// Empty in, empty out — the view hides the line rather than drawing a
    /// separator with nothing on either side of it.
    func testAGroupWithNoBankHasNoMark() {
        XCTAssertEqual(BankMark.group(bankIds: [], suffixes: [], banks, .uk), "")
    }

    // MARK: direction

    /// **Board #9's sign convention is unchanged**, and this is the test that
    /// says so after the amount moved into its own element: «+» on an arrival,
    /// and no minus on a purchase — the magnitude is the number, and the
    /// colour now carries the direction.
    func testTheSignConventionSurvivedTheSplit() throws {
        let income = try group([tx("Роботодавець-Зразок", amount: 25_000_00)])
        let expense = try group([tx("Крамниця-Приклад")])

        XCTAssertTrue(QueueView.amountText(for: income).hasPrefix("+"))
        XCTAssertFalse(QueueView.amountText(for: expense).contains("-"))
        XCTAssertFalse(QueueView.amountText(for: expense).contains("−"))
        XCTAssertFalse(QueueView.amountText(for: expense).contains("+"))
    }

    /// The words and the money are now separable, and the words carry no money.
    func testTheCountLineNoLongerCarriesTheAmount() throws {
        let g = try group([tx("Крамниця-Приклад"), tx("Крамниця-Приклад", days: 1)])
        let words = QueueView.countText(for: g, .uk)
        XCTAssertEqual(words, "2 покупки")
        XCTAssertFalse(words.contains("₴"), "the money moved to its own element")
    }

    /// The card's second line: what it is asking about, then where from.
    func testTheCardLineCarriesTheCountAndTheProvenance() throws {
        let g = try group([tx("Крамниця-Приклад"), tx("Крамниця-Приклад", days: 1)])
        XCTAssertEqual(QueueView.provenance(for: g, banks, .uk),
                       "2 покупки · monobank · *1111")
    }

    /// A group with no bank leaves no dangling separator.
    func testAGroupWithNoBankShowsOnlyItsCount() {
        var g = MerchantGroup(key: "k", merchant: "Крамниця-Приклад", kind: .expense,
                              count: 2, total: 200_00, rowIds: [])
        g.bankIds = []; g.cardSuffixes = []
        XCTAssertEqual(QueueView.provenance(for: g, banks, .uk), "2 покупки")
    }

    /// And the two together still read as the sentence `subtitle` always
    /// produced — so nothing that reads `subtitle` changed meaning.
    func testSubtitleIsStillTheWordsAndTheMoneyTogether() throws {
        let g = try group([tx("Крамниця-Приклад"), tx("Крамниця-Приклад", days: 1)])
        XCTAssertEqual(QueueView.subtitle(for: g, .uk),
                       "\(QueueView.countText(for: g, .uk)) · \(QueueView.amountText(for: g))")
    }
}
