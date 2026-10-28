import XCTest
@testable import MonitorFinance

/// Board #99 — the feed filters by bank.
///
/// The dimension exists because the card one is not enough: three sources now
/// feed one list, and «show me ПриватБанк» is not expressible as a set of card
/// suffixes — least of all when one physical card has two spellings.
final class FeedBankFilterTests: XCTestCase {

    private func tx(_ bankId: String, _ suffix: String, category: String = "Продукти",
                    kind: TxKind = .expense) -> Transaction {
        Transaction(id: UUID(), date: Date(), kind: kind, category: category,
                    merchant: "Крамниця-Приклад", amount: -100_00, cardSuffix: suffix,
                    bankId: bankId, receiptId: nil, splits: [], resolution: .user,
                    suggestions: [])
    }

    private var rows: [Transaction] {
        [tx("monobank", "*1111"), tx("monobank", "*2222"),
         tx("privatbank", "5*99"), tx("privatbank", "*2299")]
    }

    private var banks: [Bank] {
        [Bank(id: "monobank", displayName: "monobank", status: .available,
              connected: true, accounts: []),
         Bank(id: "privatbank", displayName: "ПриватБанк", status: .statement,
              connected: true, accounts: [])]
    }

    // MARK: the dimension

    func testAnEmptyFilterStillShowsEverything() {
        XCTAssertEqual(Derived.apply(FeedFilter(), to: rows).count, 4)
    }

    func testChoosingABankKeepsOnlyItsRows() {
        var filter = FeedFilter()
        filter.banks = ["privatbank"]
        let kept = Derived.apply(filter, to: rows)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.allSatisfy { $0.bankId == "privatbank" })
    }

    /// **The reason this dimension is worth having at all.**
    ///
    /// One physical PrivatBank card arrives spelled «5*99» from a letter and
    /// «*2299» from a statement, and nothing reconciles them — so no set of
    /// card suffixes a person can tick expresses "everything from Privat"
    /// without their knowing both spellings. The bank id does, because both
    /// rows carry the same one.
    func testTheBankCatchesBothSpellingsOfOneCard() {
        var filter = FeedFilter()
        filter.banks = ["privatbank"]
        let suffixes = Set(Derived.apply(filter, to: rows).map(\.cardSuffix))
        XCTAssertEqual(suffixes, ["5*99", "*2299"])
    }

    func testTwoBanksChosenIsTheUnionAndNotTheIntersection() {
        var filter = FeedFilter()
        filter.banks = ["monobank", "privatbank"]
        XCTAssertEqual(Derived.apply(filter, to: rows).count, 4)
    }

    /// Dimensions are ANDed. A bank AND a card of that bank narrows; the same
    /// bank AND another bank's card is empty — which is exactly the state the
    /// sheet stops a person from reaching by hand.
    func testBankAndCardCompose() {
        var narrowed = FeedFilter()
        narrowed.banks = ["monobank"]
        narrowed.cards = ["*1111"]
        XCTAssertEqual(Derived.apply(narrowed, to: rows).count, 1)

        var impossible = FeedFilter()
        impossible.banks = ["privatbank"]
        impossible.cards = ["*1111"]
        XCTAssertEqual(Derived.apply(impossible, to: rows).count, 0)
    }

    func testBankComposesWithKindAndCategory() {
        let mixed = rows + [tx("privatbank", "5*99", category: "Кафе та ресторани",
                               kind: .income)]
        var filter = FeedFilter()
        filter.banks = ["privatbank"]
        filter.kinds = [.income]
        XCTAssertEqual(Derived.apply(filter, to: mixed).count, 1)
    }

    // MARK: isEmpty, which decides whether the chip bar is drawn at all

    func testABankAloneMakesTheFilterNonEmpty() {
        var filter = FeedFilter()
        filter.banks = ["monobank"]
        XCTAssertFalse(filter.isEmpty,
                       "a bank-only filter must still draw its chip and its reset")
        XCTAssertTrue(FeedFilter().isEmpty)
    }

    // MARK: chips

    func testTheBankChipShowsTheBanksNameAndNotItsId() {
        var filter = FeedFilter()
        filter.banks = ["privatbank"]
        XCTAssertEqual(filter.chips(banks, .uk), ["ПриватБанк"])
    }

    /// **The defect this card found in passing.** `TxKind.title` is copy with
    /// a translation in the catalogue since board #85; `chips` returned the
    /// Ukrainian and `FeedView` drew it through `Text(verbatim:)`, so the chip
    /// said «Витрати» beside a sheet row reading "Spending".
    func testTheKindChipFollowsTheInterfaceLanguage() {
        var filter = FeedFilter()
        filter.kinds = [.expense]
        XCTAssertEqual(filter.chips(banks, .uk), ["Витрати"])
        XCTAssertEqual(filter.chips(banks, .en), ["Spending"])
    }

    /// The other three dimensions are the person's data and are not touched by
    /// the language — asserted beside the one that is, because this is the
    /// distinction the whole chip bar rests on.
    func testTheDataChipsAreTheSameInBothLanguages() {
        var filter = FeedFilter()
        filter.categories = ["Продукти"]
        filter.cards = ["*1111"]
        filter.banks = ["privatbank"]
        XCTAssertEqual(filter.chips(banks, .uk), filter.chips(banks, .en))
        XCTAssertEqual(filter.chips(banks, .en), ["Продукти", "ПриватБанк", "*1111"])
    }
}
