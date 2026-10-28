import XCTest
@testable import MonitorFinance

/// Board #98 — the one answer to "which bank and which card is this row".
///
/// Four screens ask it. Before this existed, `TransactionDetailView` had its
/// own copy of the lookup and the feed had none at all, which is how a person
/// ends up reading two names for one bank without anything being obviously
/// broken.
final class BankMarkTests: XCTestCase {

    private func bank(_ id: String, _ name: String) -> Bank {
        Bank(id: id, displayName: name, status: .available, connected: true, accounts: [])
    }

    private func tx(bankId: String, cardSuffix: String) -> Transaction {
        Transaction(id: UUID(), date: Date(), kind: .expense, category: "Продукти",
                    merchant: "Крамниця-Приклад", amount: -100_00, cardSuffix: cardSuffix,
                    bankId: bankId, receiptId: nil, splits: [],
                    resolution: .user, suggestions: [])
    }

    private var banks: [Bank] {
        [bank("monobank", "monobank"), bank("privatbank", "ПриватБанк")]
    }

    func testTheMarkNamesTheBankAndTheCard() {
        XCTAssertEqual(BankMark.line(tx(bankId: "monobank", cardSuffix: "4441"), banks),
                       "monobank · 4441")
        XCTAssertEqual(BankMark.line(tx(bankId: "privatbank", cardSuffix: "2299"), banks),
                       "ПриватБанк · 2299")
    }

    /// A row with no card — an income the bank did not attribute to one —
    /// still says which bank, and does not grow a dangling separator.
    func testARowWithNoCardStillNamesItsBank() {
        let mark = BankMark.line(tx(bankId: "monobank", cardSuffix: ""), banks)
        XCTAssertEqual(mark, "monobank")
        XCTAssertFalse(mark.hasSuffix("·"), "an empty suffix must not leave its separator")
    }

    /// **The row survives its bank being disconnected.** Its transactions stay,
    /// and the id is then the only thing that says which bank they came from —
    /// so the fallback is the id rather than a friendly word that names nothing.
    func testAnUnknownBankIdIsShownRatherThanHidden() {
        XCTAssertEqual(BankMark.line(tx(bankId: "oschadbank", cardSuffix: "7777"), banks),
                       "oschadbank · 7777")
        XCTAssertEqual(BankMark.bank("oschadbank", []), "oschadbank")
    }

    /// The two spellings one physical card has, kept as the source sent them.
    ///
    /// A letter says «5*99» and a statement says «2299»; this deliberately does
    /// NOT reconcile them. Inventing a third spelling here would give the two
    /// that disagree a fourth to disagree with, and card identity is its own
    /// card.
    func testTheSuffixIsPrintedExactlyAsTheSourceSentIt() {
        XCTAssertEqual(BankMark.line(tx(bankId: "privatbank", cardSuffix: "5*99"), banks),
                       "ПриватБанк · 5*99")
        XCTAssertEqual(BankMark.line(tx(bankId: "privatbank", cardSuffix: "*2299"), banks),
                       "ПриватБанк · *2299")
    }

    /// The detail screen and the feed row now read the same function, so this
    /// is the assertion that they cannot drift apart.
    func testTheBankNameIsTheSameOneTheDetailScreenShows() {
        let row = tx(bankId: "privatbank", cardSuffix: "2299")
        XCTAssertTrue(BankMark.line(row, banks).hasPrefix(BankMark.bank(row.bankId, banks)))
    }
}
