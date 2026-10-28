import XCTest
@testable import MonitorFinance

final class ReceiptScheduleTests: XCTestCase {

    private let scan = ISO8601DateFormatter().date(from: "2026-08-25T12:00:00+03:00")!

    private func pending(attempts: Int, next: Date, scannedAt: Date? = nil) -> PendingReceipt {
        PendingReceipt(receiptId: UUID(),
                       check: FiscalCheck(registerNumber: "1", documentNumber: "2",
                                          fiscalTime: scan, fiscalSum: 100, mac: nil),
                       scannedAt: scannedAt ?? scan, attempts: attempts,
                       nextAttempt: next, lastError: nil)
    }

    func testTheBackoffWidensInTheOrderTheSpecFixes() {
        // Minutes after the attempt that just failed.
        let expected: [(attempts: Int, minutes: Double)] = [
            (0, 1), (1, 5), (2, 15), (3, 60), (4, 180), (5, 180), (99, 180),
        ]
        for step in expected {
            XCTAssertEqual(ReceiptSchedule.nextAttempt(afterAttempts: step.attempts, now: scan),
                           scan.addingTimeInterval(step.minutes * 60),
                           "after \(step.attempts) attempts")
        }
    }

    func testTheFirstAttemptIsAMinuteAfterTheScan() {
        XCTAssertEqual(ReceiptSchedule.firstAttempt(after: scan), scan.addingTimeInterval(60))
    }

    /// The owner measures about an hour before a receipt is published. A
    /// schedule that gives up before then would fail on the ordinary case.
    func testTheScheduleIsStillTryingAnHourAndADayLater() {
        let elapsedOptions: [Double] = [3600.0, 6 * 3600, 24 * 3600, 47 * 3600]
        for elapsed in elapsedOptions {
            let now = scan.addingTimeInterval(elapsed)
            XCTAssertFalse(ReceiptSchedule.hasGivenUp(pending(attempts: 9, next: now), now: now),
                           "\(elapsed / 3600) h in")
        }
    }

    func testItGivesUpAtFortyEightHoursAndNotBefore() {
        let justBefore = scan.addingTimeInterval(ReceiptSchedule.giveUpAfter - 1)
        let justAfter = scan.addingTimeInterval(ReceiptSchedule.giveUpAfter + 1)
        XCTAssertFalse(ReceiptSchedule.hasGivenUp(pending(attempts: 20, next: justBefore), now: justBefore))
        XCTAssertTrue(ReceiptSchedule.hasGivenUp(pending(attempts: 20, next: justAfter), now: justAfter))
    }

    /// Final review F6: the only two things that ever drain the queue are a
    /// `scenePhase -> .active` transition and a `BGAppRefreshTask` wake, both
    /// at iOS's own discretion — so a receipt scanned and then left alone
    /// for two days on a phone iOS never woke could reach 48h having asked
    /// the tax service exactly zero times. "Given up" must mean "we asked
    /// and were refused", not merely "a long time passed".
    func testItNeverGivesUpWithoutHavingAskedAtLeastOnce() {
        let wayPast = scan.addingTimeInterval(ReceiptSchedule.giveUpAfter * 10)
        XCTAssertFalse(ReceiptSchedule.hasGivenUp(pending(attempts: 0, next: wayPast), now: wayPast),
                       "attempts == 0 means the tax service was never actually asked")
    }

    func testOnlyDueReceiptsAreDueAndTheOldestGoesFirst() {
        let a = pending(attempts: 1, next: scan.addingTimeInterval(-60))
        let b = pending(attempts: 1, next: scan.addingTimeInterval(-600))
        let notYet = pending(attempts: 1, next: scan.addingTimeInterval(600))
        let due = ReceiptSchedule.due([a, b, notYet], now: scan)
        XCTAssertEqual(due.map(\.id), [b.id, a.id], "the longest-waiting receipt is served first")
    }

    /// A receipt past its window is not due, whatever its `nextAttempt` says —
    /// otherwise a queue drains forever on documents that will never publish.
    func testAReceiptPastItsWindowIsNoLongerDue() {
        let now = scan.addingTimeInterval(ReceiptSchedule.giveUpAfter + 60)
        let stale = pending(attempts: 30, next: now.addingTimeInterval(-60))
        XCTAssertTrue(ReceiptSchedule.due([stale], now: now).isEmpty)
    }

    /// The clock MOVES. Stage 1 shipped a Critical that 410 green tests agreed
    /// with, because every injected `now` was frozen and the injected `sleep`
    /// did not advance it — so a planner and its tests shared one wrong model
    /// of time. This walks the schedule the way a real day does.
    func testWalkingTwoRealDaysProducesABoundedNumberOfAttempts() {
        var now = scan
        var p = pending(attempts: 0, next: ReceiptSchedule.firstAttempt(after: scan))
        var attempts = 0
        while !ReceiptSchedule.hasGivenUp(p, now: now) {
            now = max(now, p.nextAttempt)
            attempts += 1
            p.attempts += 1
            p.nextAttempt = ReceiptSchedule.nextAttempt(afterAttempts: p.attempts, now: now)
            // Both of these must EXIT, not merely record: this loop's only exit
            // is the schedule advancing, so a schedule that does not advance
            // hangs the suite instead of reddening it — and a timeout reads as
            // a slow machine, which is how a real defect gets waved through.
            guard p.nextAttempt > now else {
                return XCTFail("a schedule that does not advance is a spin")
            }
            guard attempts < 40 else {
                return XCTFail("the backoff stopped backing off")
            }
        }
        // 1 + 5 + 15 + 60 minutes, then three-hourly to 48 h.
        XCTAssertEqual(attempts, 20)
    }
}
