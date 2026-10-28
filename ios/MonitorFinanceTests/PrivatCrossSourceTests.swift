import XCTest
@testable import MonitorFinance

/// The matcher that decides whether a statement row and a notification letter
/// describe the same purchase. Every case here is a shape the two real sources
/// actually produce — see `PrivatCrossSource`'s own note on why their identity
/// keys can never simply be compared.
final class PrivatCrossSourceTests: XCTestCase {

    func testSuffixesAgreeOnLastTwoDigits() {
        XCTAssertTrue(PrivatCrossSource.sameCard("*2299", "5*99"))
        XCTAssertFalse(PrivatCrossSource.sameCard("*1111", "5*99"))
        // An empty suffix (interest rows) cannot claim agreement.
        XCTAssertFalse(PrivatCrossSource.sameCard("", "5*99"))
    }

    /// A single digit is not two digits' worth of evidence, and «*9» vs «5*99»
    /// agreeing would let one card's row swallow another's.
    func testASingleDigitIsNotEnoughToClaimAgreement() {
        XCTAssertFalse(PrivatCrossSource.sameCard("*9", "5*99"))
        XCTAssertFalse(PrivatCrossSource.sameCard("5*99", "*9"))
    }

    func testABalancelessRowNeverMatches() {
        XCTAssertNil(PrivatCrossSource.key(amountMinor: -100, balanceAfterMinor: nil))
    }

    /// The whole point of the pair: the two sources disagree about the suffix,
    /// the merchant and the second, and agree about these two numbers.
    func testTheSameAmountAndBalanceProduceTheSameKey() {
        XCTAssertEqual(PrivatCrossSource.key(amountMinor: -12_550, balanceAfterMinor: 903_450),
                       PrivatCrossSource.key(amountMinor: -12_550, balanceAfterMinor: 903_450))
        XCTAssertNotEqual(PrivatCrossSource.key(amountMinor: -12_550, balanceAfterMinor: 903_450),
                          PrivatCrossSource.key(amountMinor: -12_550, balanceAfterMinor: 903_451))
        // Sign is part of the key: a refund of the same size is not the purchase.
        XCTAssertNotEqual(PrivatCrossSource.key(amountMinor: -12_550, balanceAfterMinor: 903_450),
                          PrivatCrossSource.key(amountMinor: 12_550, balanceAfterMinor: 903_450))
    }

    /// The separator has to survive a negative amount — «-1|2» and «-1|2» are
    /// fine, but a key built by concatenation alone would let (-12, 550) and
    /// (-125, 50) collide.
    func testTwoDifferentPairsCannotShareAKey() {
        XCTAssertNotEqual(PrivatCrossSource.key(amountMinor: -12, balanceAfterMinor: 550),
                          PrivatCrossSource.key(amountMinor: -125, balanceAfterMinor: 50))
    }

    func testAuthorisationAndSettlementUpToThirtySixHoursApartStillMatch() {
        let letter = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertTrue(PrivatCrossSource.matches(
            date: letter.addingTimeInterval(36 * 3600), suffix: "*2299",
            candidateDate: letter, candidateSuffix: "5*99"))
        // …and the drift runs both ways: the statement may be read first.
        XCTAssertTrue(PrivatCrossSource.matches(
            date: letter.addingTimeInterval(-36 * 3600), suffix: "*2299",
            candidateDate: letter, candidateSuffix: "5*99"))
    }

    func testBeyondTheWindowIsADifferentPurchase() {
        let letter = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertFalse(PrivatCrossSource.matches(
            date: letter.addingTimeInterval(36 * 3600 + 1), suffix: "*2299",
            candidateDate: letter, candidateSuffix: "5*99"))
    }

    /// Two cards can hold the same balance after a same-sized purchase — a
    /// standing order paid from both, say. The card guard is what keeps that
    /// from merging one person's two rows into one.
    func testTheSameMomentOnAnotherCardIsNotAMatch() {
        let letter = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertFalse(PrivatCrossSource.matches(
            date: letter, suffix: "*1111",
            candidateDate: letter, candidateSuffix: "5*99"))
    }
}
