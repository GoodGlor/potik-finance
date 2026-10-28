import XCTest
@testable import MonitorFinance

/// Board #115, narrowed by board #131 — **the feed's months.**
///
/// #115 gave the swipe to the months and the statistics scope; #131 gave the
/// swipe back to the tabs after the owner used it on a phone. `steppedMonth`
/// survives because the feed's **chevrons** still call it; `steppedScope` did
/// not, because nothing called it once the scope swipe was gone, and its tests
/// went with it. A green test over a function the app never reaches proves
/// nothing and costs a reader time.
///
/// The *feel* of a gesture is not assertable in XCTest and needs a device. The
/// *effect* of one step is, and this is it.
@MainActor
final class SwipePagingTests: XCTestCase {

    private let months = [MonthKey(year: 2026, month: 3),
                          MonthKey(year: 2026, month: 5),
                          MonthKey(year: 2026, month: 8)]

    // MARK: the feed's months

    func testOneStepForwardIsTheNextMonthThatHasData() {
        XCTAssertEqual(FeedView.steppedMonth(months, from: months[0], by: 1), months[1],
                       "March steps to May — April has no rows and is not a stop")
    }

    func testOneStepBackIsThePreviousMonthThatHasData() {
        XCTAssertEqual(FeedView.steppedMonth(months, from: months[2], by: -1), months[1])
    }

    /// **The ends do not wrap**, the same rule board #63 gave the tabs. A wrap
    /// would put January one flick to the left of the newest month, which is
    /// the last place somebody swiping back through their history wants to be.
    func testTheOldestMonthHasNothingBeforeIt() {
        XCTAssertNil(FeedView.steppedMonth(months, from: months[0], by: -1))
    }

    func testTheNewestMonthHasNothingAfterIt() {
        XCTAssertNil(FeedView.steppedMonth(months, from: months[2], by: 1))
    }

    /// A month that is not in the list — a stale selection, or the calendar
    /// month on a dataset that ends in the past — steps nowhere rather than to
    /// an arbitrary index. Swiping then does nothing, which is visible; landing
    /// somewhere unrelated would not be.
    func testAMonthOutsideTheListStepsNowhere() {
        XCTAssertNil(FeedView.steppedMonth(months, from: MonthKey(year: 2025, month: 1), by: 1))
    }

    func testNoMonthsAtAllStepsNowhere() {
        XCTAssertNil(FeedView.steppedMonth([], from: months[0], by: 1))
    }

    /// The chevrons are now the ONLY caller of `steppedMonth`, which is why
    /// these tests still earn their place. If the chevrons ever go, so does
    /// this file.
    func testTheChevronsAreWhatStillStepsMonths() {
        XCTAssertEqual(FeedView.steppedMonth(months, from: months[1], by: 1), months[2],
                       "forward is LATER — the same direction the right chevron points")
    }
}
