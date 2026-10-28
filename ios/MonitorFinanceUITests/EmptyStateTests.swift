import XCTest

final class EmptyStateTests: XCTestCase {
    private var app: XCUIApplication!

    /// `-stubStatementDelay 600`: every assertion below reads hittability
    /// immediately, and every empty state disappears the moment the stub's
    /// first window commits. At the stub's default 3.5 s the usable window was
    /// whatever was left after `app.launch()` returned — `launch()` returns on
    /// UI quiescence, which does not wait on a background `Task.sleep` — so a
    /// slow launch on a loaded machine ate the margin and the failure read as
    /// a view bug. None of these five need the sync to COMPLETE, only to be in
    /// flight, so the stub simply does not answer for the length of the test.
    private func launch(tab: Int) {
        app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-noDemoData",
                               "-stubMonobank", "-stage", "unlocked", "-tab", "\(tab)",
                               "-stubStatementDelay", "600", "-lang", "uk"]
        app.launch()
    }

    /// Zero must not be presented as a fact about the user's month.
    func testHomeSaysItIsLoadingRatherThanShowingZeroSpent() {
        launch(tab: 0)
        assertLive(app.staticTexts["sync.status"])
        assertLive(app.staticTexts["home.empty"])
        // `home.month.spent` is a real identifier on HomeView's month card
        // today, so this negative has a partner that proves it can exist:
        // `FeedTests` and `StatsAndSettingsTests` both assert it with data.
        XCTAssertFalse(app.staticTexts["home.month.spent"].exists,
                       "no spending figure until there is spending to report")
    }

    /// `feed.empty.noData`, not `feed.empty`: the search-found-nothing branch
    /// carries the latter and is on screen for this launch too (no rows match
    /// nothing), so querying it proved only that ONE of the two messages
    /// existed. The label is asserted as well, so the test is pinned to the
    /// words the user reads rather than to an identifier existing.
    func testTheFeedOffersAnExplanationRatherThanAnEmptyList() {
        launch(tab: 1)
        let empty = app.staticTexts["feed.empty.noData"]
        assertLive(empty)
        XCTAssertEqual(empty.label,
                       "Тут з'являться ваші покупки, щойно банк їх віддасть.")
    }

    /// Same shape as the feed above: `stats.empty` belongs to «Витрат за цей
    /// період немає», which renders for an empty app too.
    func testStatisticsSaysWhyItIsBlank() {
        launch(tab: 3)
        let empty = app.staticTexts["stats.empty.noData"]
        assertLive(empty)
        XCTAssertEqual(empty.label, "Статистика з'явиться, коли буде що рахувати.")
    }

    func testTheQueueSaysThereIsNothingYetRatherThanCongratulatingYou() {
        launch(tab: 4)
        assertLive(app.staticTexts["queue.empty.waiting"])
        // `queue.done` lives on a `Button` (a `PrimaryButton`), not a
        // `staticTexts` element — `app.marker(_:)` finds it regardless of
        // the type SwiftUI surfaced it as. `app.staticTexts["queue.done"]`
        // can never exist, so that query used to pass unconditionally.
        XCTAssertFalse(app.marker("queue.done").exists,
                       "«все розібрано» is a reward, not a description of an empty app")
    }

    /// Was `testABudgetCannotBePlannedAgainstNoIncomeYet`, and the name was
    /// the bug: board #23 found that it always could. `IncomeBaseView` has
    /// «Своя сума» and the editor works in percentages, so a person who knows
    /// their salary can write the whole plan before a purchase arrives — the
    /// tab was telling them to wait for a number they already knew.
    ///
    /// The explanation stays. It is still true that the *average* has nothing
    /// to average, and a CTA with no reason beside it is its own dead end.
    func testABudgetCanBePlannedBeforeTheFirstSyncArrives() {
        launch(tab: 2)
        assertLive(app.staticTexts["budget.empty"])
        assertLive(app.buttons["budget.create"])

        app.buttons["budget.create"].tap()
        XCTAssertTrue(app.marker("editor.title").waitForExistence(timeout: 3),
                      "«Скласти план» must open the editor, not merely exist")
        app.buttons["editor.income"].tap()
        XCTAssertTrue(app.marker("income.title").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Своя сума"].exists,
                      "«Своя сума» is the way past an average with nothing to average")
    }
}
