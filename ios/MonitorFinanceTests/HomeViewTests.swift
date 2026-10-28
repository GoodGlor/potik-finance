import XCTest
@testable import MonitorFinance

final class HomeViewTests: XCTestCase {

    /// 1 покупка · 2–4 покупки · 5+ покупок — Ukrainian needs all three forms,
    /// and 11–14 take the last one despite ending in 1–4.
    func testPurchaseWordCoversTheUkrainianTeensException() {
        XCTAssertEqual(HomeView.purchaseWord(1, .uk), "покупка")
        XCTAssertEqual(HomeView.purchaseWord(3, .uk), "покупки")
        XCTAssertEqual(HomeView.purchaseWord(7, .uk), "покупок")
        XCTAssertEqual(HomeView.purchaseWord(11, .uk), "покупок", "11 is not 1")
        XCTAssertEqual(HomeView.purchaseWord(12, .uk), "покупок", "12 is not 2")
        XCTAssertEqual(HomeView.purchaseWord(21, .uk), "покупка")
        XCTAssertEqual(HomeView.purchaseWord(22, .uk), "покупки")
    }

    /// Board #8: the card leads with the number the badge shows — the cards —
    /// and names the purchases behind them, so Головна and the tab bar can no
    /// longer give two figures for one screen's worth of work.
    func testTheQueueLineLeadsWithCardsAndNamesThePurchasesBehindThem() {
        XCTAssertEqual(HomeView.queueLine(cards: 12, purchases: 66, .uk), "12 запитань · 66 покупок")
        XCTAssertEqual(HomeView.queueLine(cards: 4, purchases: 12, .uk), "4 запитання · 12 покупок")
        XCTAssertEqual(HomeView.queueLine(cards: 1, purchases: 20, .uk), "1 запитання · 20 покупок")
    }

    /// One card per purchase is the common shape since board #7 gave every
    /// transfer a card of its own, and «61 запитання · 61 покупка» says one
    /// thing twice.
    func testTheQueueLineDropsTheSecondNumberWhenItSaysTheSameThing() {
        XCTAssertEqual(HomeView.queueLine(cards: 61, purchases: 61, .uk), "61 запитання")
        XCTAssertEqual(HomeView.queueLine(cards: 1, purchases: 1, .uk), "1 запитання")
        // Purchases can never be FEWER than cards — a card exists because a row
        // does — but a receipt card has no pending row behind it, so the guard
        // must be `>` and not `!=`, or a lone receipt question would read
        // «1 запитання · 0 покупок».
        XCTAssertEqual(HomeView.queueLine(cards: 1, purchases: 0, .uk), "1 запитання")
    }

    /// «запитання» is its own plural for 2–4 («два запитання»), so `one` and
    /// `few` being the same string is the language, not a copy-paste.
    func testTheQuestionWordAgreesIncludingTheTeensException() {
        XCTAssertEqual(HomeView.queueLine(cards: 1, purchases: 1, .uk), "1 запитання")
        XCTAssertEqual(HomeView.queueLine(cards: 3, purchases: 3, .uk), "3 запитання")
        XCTAssertEqual(HomeView.queueLine(cards: 7, purchases: 7, .uk), "7 запитань")
        XCTAssertEqual(HomeView.queueLine(cards: 11, purchases: 11, .uk), "11 запитань", "11 is not 1")
        XCTAssertEqual(HomeView.queueLine(cards: 21, purchases: 21, .uk), "21 запитання", "…and 21 IS 1")
    }

    /// The second number is a standalone nominative label, which is why the
    /// separator is «·» and not «про»: «про» governs the accusative, so 21
    /// would need «про 21 покупку» while `purchaseWord` gives «покупка».
    func testThePurchaseHalfKeepsItsNominativeAgreement() {
        XCTAssertEqual(HomeView.queueLine(cards: 2, purchases: 21, .uk), "2 запитання · 21 покупка")
        XCTAssertEqual(HomeView.queueLine(cards: 2, purchases: 22, .uk), "2 запитання · 22 покупки")
        XCTAssertEqual(HomeView.queueLine(cards: 2, purchases: 11, .uk), "2 запитання · 11 покупок")
    }
}
