import XCTest

/// Drives the real app in a simulator, the way a person does.
///
/// The backend tests prove the categorizer is right; these prove the screens
/// are usable, which is a different failure mode and invisible to every other
/// test we have. The bug that prompted them: the one button that finishes
/// onboarding sat below the fold, rendering correctly and reachable by nothing
/// but a scroll nobody knew to make. That regression is now guarded by
/// `OnboardingTests` instead.
final class OnboardingAndQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank", "-lang", "uk"] + arguments
        app.launch()
        return app
    }

    /// Asserts each tab actually OPENED, by looking for content that only that
    /// tab renders — not for the tab button, which exists regardless of whether
    /// tapping it did anything.
    func testEveryTabOpensItsOwnScreen() {
        let app = launch(["-stage", "unlocked"])
        let expected: [(tab: String, marker: String)] = [
            ("Головна", "home.title"),
            ("Стрічка", "feed.title"),
            ("Бюджет", "budget.title"),
            ("Статистика", "stats.title"),
            ("Розібрати", "queue.title"),
        ]
        for (tab, marker) in expected {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.marker(marker).waitForExistence(timeout: 3),
                          "tapping \(tab) did not open the screen carrying \(marker)")
        }
    }

    // Statistics scope-switching is covered by
    // StatsAndSettingsTests.testSwitchingScopeChangesTheTotal, against the
    // live-data StatsView (week/month/year) that replaced the prototype's
    // hardcoded "13–19 серпня" / "Місяць" two-tab mock this test pinned.

    // Confirming, undoing, skipping and the "done" state over the real
    // pending queue are covered by QueueFlowTests, against the live-data
    // QueueView (store-backed, with skip/undo) that replaced this prototype's
    // two-hardcoded-item mock this test pinned.

    /// Home's tip card links to the full observations list — the computed
    /// replacement for the old mock "Що з цим робити" → AdviceView flow.
    func testTheTipsScreenIsReachableFromHome() {
        let app = launch(["-skipOnboarding"])
        app.marker("home.tips").tap()
        XCTAssertTrue(app.marker("tips.list").waitForExistence(timeout: 5))
    }

    /// Board #20, in the state that produced it: `-noDemoData` plus the stub
    /// is the real first launch — six rows arrive `.pending` with no category,
    /// and Home said «Найбільша стаття: Без категорії — 100% усіх витрат».
    ///
    /// The demo seed cannot reach this branch: every one of its expense rows
    /// carries a category, the `.pending` ones included, so its unsorted share
    /// is 0% and `testTheTipsScreenIsReachableFromHome` above is green either
    /// way. `-noDemoData` is what makes the fresh state observable at all.
    ///
    /// Asserts what Home DOES say as well as what it stopped saying — the
    /// absence alone would also pass on a Home that failed to load.
    func testAFreshlySyncedHomeDoesNotNameTheUnsortedPileAsACategory() {
        let app = launch(["-noDemoData", "-stage", "unlocked", "-tab", "0"])
        XCTAssertTrue(app.marker("home.tips").waitForExistence(timeout: 20),
                      "the tip card must still be there — with the observation the data supports")
        XCTAssertTrue(app.staticTexts["Найчастіший продавець"].exists,
                      "the merchant tip does not need a category and must survive the suppression")
        // `Derived.uncategorised` verbatim: the UI target does not link the
        // app target, so the constant cannot be imported.
        let unsorted = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Без категорії"))
        XCTAssertEqual(unsorted.count, 0,
                       "Home named the pile it has not sorted yet as the largest article")
    }

    /// Home's budget card is a button, not copy that merely looks actionable.
    /// It was static text reading "Плану ще немає" with no way to act on it;
    /// asserting the tab SELECTION as well as the screen is what makes this
    /// fail if the card ever stops being the thing that moved the user.
    func testTheBudgetTabIsReachableFromHomesBudgetCard() {
        let app = launch(["-stage", "unlocked"])
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 5))
        XCTAssertFalse(app.marker("budget.title").exists,
                       "Бюджет must not already be on screen — then the tap would prove nothing")

        XCTAssertTrue(app.buttons["home.budget.open"].waitForExistence(timeout: 3))
        assertLive(app.buttons["home.budget.open"])
        app.buttons["home.budget.open"].tap()

        XCTAssertTrue(app.marker("budget.title").waitForExistence(timeout: 3),
                      "tapping Home's budget card must open the Бюджет tab")
        XCTAssertTrue(app.tabBars.buttons["Бюджет"].isSelected,
                      "the tab bar must follow, or the user is on a screen the tabs disagree about")
    }
}
