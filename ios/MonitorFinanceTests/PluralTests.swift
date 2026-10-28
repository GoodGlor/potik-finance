import XCTest
@testable import MonitorFinance

final class PluralTests: XCTestCase {

    /// 11 and 21 are the pair that catches a naive `n % 10` rule: 11 takes
    /// «покупок» (the teens exception) while 21 takes «покупка» (it is 1).
    func testPurchasesPrependsTheCountToTheCorrectUkrainianForm() {
        XCTAssertEqual(Plural.purchases(1, .uk), "1 покупка")
        XCTAssertEqual(Plural.purchases(2, .uk), "2 покупки")
        XCTAssertEqual(Plural.purchases(5, .uk), "5 покупок")
        XCTAssertEqual(Plural.purchases(11, .uk), "11 покупок", "11 is not 1")
        XCTAssertEqual(Plural.purchases(21, .uk), "21 покупка", "…and 21 IS 1")
    }

    /// Board #182. «Ви розібрали 1 покупка» shipped on the done screen: the
    /// verb governs the accusative and the helper above is the nominative.
    ///
    /// The counts here are chosen to include 1 and 21 deliberately. **Only the
    /// singular form differs between the two cases** — an inanimate noun's
    /// accusative plural copies its nominative — so a test written with 2 and
    /// 5 passes against the WRONG helper, which is exactly how this reached a
    /// phone. 21 matters for the same reason 11 does in the test above: it
    /// takes the singular form, so it is the second place the bug appeared.
    func testPurchasesAccusativeDiffersFromTheNominativeAtTheSingular() {
        XCTAssertEqual(Plural.purchasesAccusative(1, .uk), "1 покупку")
        XCTAssertEqual(Plural.purchasesAccusative(2, .uk), "2 покупки")
        XCTAssertEqual(Plural.purchasesAccusative(5, .uk), "5 покупок")
        XCTAssertEqual(Plural.purchasesAccusative(11, .uk), "11 покупок", "11 is not 1")
        XCTAssertEqual(Plural.purchasesAccusative(21, .uk), "21 покупку", "…and 21 IS 1")

        // The claim the two counts above rest on, asserted rather than
        // assumed: every form but the singular is shared, so a future edit
        // that "simplifies" one helper into the other has to fail here.
        for n in [1, 21, 101] {
            XCTAssertNotEqual(Plural.purchasesAccusative(n, .uk), Plural.purchases(n, .uk),
                              "\(n) takes the singular, where the two cases part")
        }
        for n in [0, 2, 5, 11, 22, 25] {
            XCTAssertEqual(Plural.purchasesAccusative(n, .uk), Plural.purchases(n, .uk),
                           "\(n) is the same word in both cases")
        }

        // English does not decline, so the accusative helper must not invent a
        // difference the language has not got.
        for n in [1, 2, 5, 21] {
            XCTAssertEqual(Plural.purchasesAccusative(n, .en), Plural.purchases(n, .en))
        }
    }

    /// The elder sibling of the helper above, which had no test of its own —
    /// «N операцію … пропущено» on the import summary, from the same rule.
    func testOperationsAccusativePrependsTheCountToTheCorrectUkrainianForm() {
        XCTAssertEqual(Plural.operationsAccusative(1, .uk), "1 операцію")
        XCTAssertEqual(Plural.operationsAccusative(2, .uk), "2 операції")
        XCTAssertEqual(Plural.operationsAccusative(5, .uk), "5 операцій")
        XCTAssertEqual(Plural.operationsAccusative(11, .uk), "11 операцій", "11 is not 1")
        XCTAssertEqual(Plural.operationsAccusative(21, .uk), "21 операцію", "…and 21 IS 1")
    }

    /// The notification title used to run `.capitalized` over an already
    /// finished phrase, so a lock screen read «3 Покупки». Ukrainian does not
    /// capitalise the noun there.
    func testTheNewPurchasesNotificationTitleIsNotCapitalised() {
        XCTAssertEqual(Notifications.newPurchasesTitle(1, .uk), "Нова покупка")
        XCTAssertEqual(Notifications.newPurchasesTitle(3, .uk), "3 покупки")
        XCTAssertEqual(Notifications.newPurchasesTitle(5, .uk), "5 покупок")
    }

    /// Board #25. Налаштування → Категорії ended every row with a bare
    /// number, and on a fresh install most of them are 0 — so the form this
    /// screen shows most often is the one a naive rule gets wrong last.
    func testOperationsPrependsTheCountToTheCorrectUkrainianForm() {
        XCTAssertEqual(Plural.operations(0, .uk), "0 операцій", "the commonest row on a fresh install")
        XCTAssertEqual(Plural.operations(1, .uk), "1 операція")
        XCTAssertEqual(Plural.operations(2, .uk), "2 операції")
        XCTAssertEqual(Plural.operations(5, .uk), "5 операцій")
        XCTAssertEqual(Plural.operations(11, .uk), "11 операцій", "11 is not 1")
        XCTAssertEqual(Plural.operations(21, .uk), "21 операція", "…and 21 IS 1")
    }

    func testMinutesPrependsTheCountToTheCorrectUkrainianForm() {
        XCTAssertEqual(Plural.minutes(1, .uk), "1 хвилина")
        XCTAssertEqual(Plural.minutes(2, .uk), "2 хвилини")
        XCTAssertEqual(Plural.minutes(5, .uk), "5 хвилин")
        XCTAssertEqual(Plural.minutes(11, .uk), "11 хвилин", "11 is not 1")
        XCTAssertEqual(Plural.minutes(21, .uk), "21 хвилина", "…and 21 IS 1")
    }
}
