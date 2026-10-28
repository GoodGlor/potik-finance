import XCTest

final class PrivatEmailSyncTests: XCTestCase {
    @MainActor
    func testAStubLetterReachesTheFeed() {
        let app = XCUIApplication()
        // `-tab 1` = Стрічка. Home renders only aggregate totals — no
        // merchant text exists there, so asserting on tab 0 would time out
        // against a CORRECT implementation. FeedView draws
        // `Text(tx.merchant)`, which is what this query finds.
        // `-stubStatementDelay 600`: same trick as `EmptyStateTests`, and for
        // the same class of race. Without it, monobank's own stub answers in
        // 3.5 s and — once the calendar crosses roughly 2026-09-06, when a
        // fresh account's newest `.forward` row (always ~5 days behind `now`)
        // falls into the CURRENT month — `FeedView` re-defaults to that newer
        // month and filters this test's fixed-timestamp email row right back
        // out. Holding monobank's answer off for the length of the test keeps
        // the Feed pinned on whichever month the email row already put it in,
        // so the assertion never depends on today's date.
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-noDemoData", "-lang", "uk",
                               "-tab", "1",
                               "-stubMonobank", "-stubPrivatEmail",
                               "-stubStatementDelay", "600"]
        app.launch()
        // The stub's invented merchant, delivered by the email sync — typed
        // query + explicit wait, never descendants(matching: .any).
        let row = app.staticTexts["Тест-Маркет Вигадана"]
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                     "the stub letter must reach the feed through the ordinary activation trigger")
        assertLive(row)
    }
}
