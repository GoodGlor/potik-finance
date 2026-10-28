import XCTest

/// Board #114 — the budget can be scoped to some banks.
///
/// `BudgetScopeTests` in the unit target holds the model and the timing. This
/// holds the half a unit test cannot reach: **the cost is on the screen**.
///
/// A scope change takes effect next month, which is a real cost — for the rest
/// of this month the budget goes on counting banks the person has just decided
/// it should not. Saying that once inside a sheet they have closed is saying it
/// to nobody, so it is asserted in both places it must appear.
final class BudgetScopeTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func budgetTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-lang", "uk", "-stubMonobank",
                               // `-plan`: the scope lives on the card that
                               // reports a plan, so without one there is no
                               // screen to test.
                               "-plan", "-tab", "2"]
        app.launch()
        return app
    }

    /// The scope is always on screen, including «Усі банки».
    ///
    /// A line that only appeared once narrowed would make the ordinary case
    /// silent, and somebody would have to remember whether they had ever set
    /// one — on the card that already tells them which MONTH the plan is for,
    /// which is the other half of "what am I looking at".
    @MainActor
    func testTheBudgetSaysWhichBanksItCounts() {
        let app = budgetTab()
        let scope = app.buttons["budget.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 20),
                      "the plan must say which banks it is about")
        XCTAssertEqual(scope.label, "Усі банки")
        assertLive(scope)
    }

    /// **The cost, before the tap and then for the whole month it is paid.**
    @MainActor
    func testChangingTheScopeSaysWhenItLandsAndKeepsSayingIt() {
        let app = budgetTab()
        let scope = app.buttons["budget.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 20))
        scope.tap()

        // Before the tap: the sheet states the cost rather than reporting it
        // afterwards.
        XCTAssertTrue(app.staticTexts["scope.effective.title"].waitForExistence(timeout: 5))
        let cost = app.staticTexts["scope.effective.cost"]
        XCTAssertTrue(cost.exists)
        XCTAssertTrue(cost.label.contains("До кінця цього місяця"),
                      "the sheet must say this month is unchanged: \(cost.label)")

        // «Усі банки» is selected, so tapping a bank narrows to exactly it —
        // not "everything except", which is what pre-selecting them all would
        // have meant.
        let mono = app.buttons["scope.choice.monobank"]
        XCTAssertTrue(mono.exists, "a connected bank must be offerable as a scope")
        mono.tap()
        app.buttons["scope.save"].tap()

        // After: the budget card names the new scope AND when it starts, and
        // this month's own line is unchanged.
        let pending = app.staticTexts["budget.scope.pending"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5),
                      "a pending change must stay visible for the month it costs")
        XCTAssertEqual(app.buttons["budget.scope"].label, "Усі банки",
                       "this month keeps the plan its decisions were made against")
    }

    /// An empty scope would measure a month against nothing, which reads as a
    /// broken screen rather than a choice. «Усі банки» is how you mean
    /// everything.
    @MainActor
    func testAnEmptyScopeCannotBeSaved() {
        let app = budgetTab()
        let scope = app.buttons["budget.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 20))
        scope.tap()

        let mono = app.buttons["scope.choice.monobank"]
        XCTAssertTrue(mono.waitForExistence(timeout: 5))
        mono.tap()   // now: only monobank
        mono.tap()   // now: nothing at all
        XCTAssertFalse(app.buttons["scope.save"].isEnabled,
                       "a plan about no banks is not a choice somebody meant")
    }
}
