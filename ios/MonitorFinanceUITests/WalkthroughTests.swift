import XCTest

/// Board #107 — the guide that is operated rather than read.
///
/// Board #60's guide was four pages a person swiped through and closed. The
/// owner asked for interaction, and the shape chosen from the card's three is
/// coach-marks over the real screens: **each step ends when they press the
/// real tab**, so by the end they have not been told where the three screens
/// are, they have been to them.
///
/// That is exactly what a UI test can prove and a unit test cannot — the
/// advance comes from the tab bar, which does not exist outside the app.
final class WalkthroughTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// **`-showGuide` is not optional here, and finding that out is half the
    /// card.** The walkthrough reuses board #60's gate so that every other
    /// suite goes on suppressing it with the `-noGuide` they already pass —
    /// but `-skipOnboarding` stamps that same gate too, because it means
    /// "pretend the first run happened" and a first-launch tour is part of a
    /// first run. Omitting `-noGuide` is therefore not enough; the first
    /// version of this suite did exactly that and met no walkthrough at all.
    private func firstLaunch(_ lang: String = "uk") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-showGuide", "-lang", lang, "-stubMonobank"]
        return app
    }

    private func tab(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[label]
    }

    /// **The card's three flows, walked by pressing the real tabs.**
    @MainActor
    func testTheWalkthroughIsFinishedByUsingTheApp() {
        let app = firstLaunch()
        app.launch()

        // The opening card is the one step with a button, because there is
        // nothing to point at until the tour has said what it is.
        XCTAssertTrue(app.otherElements["walkthrough.step.0"].waitForExistence(timeout: 15),
                      "a first launch must meet the walkthrough")
        app.buttons["walkthrough.next"].tap()

        // Flow one: sort the queue. The card asks, and the TAB BAR finishes
        // the step — there is deliberately no «Далі» to press past it with.
        XCTAssertTrue(app.otherElements["walkthrough.step.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["walkthrough.next"].exists,
                       "a coach-mark step must have no way past it except doing the thing")
        tab("Розібрати", in: app).tap()

        // Flow two: the budget.
        XCTAssertTrue(app.otherElements["walkthrough.step.2"].waitForExistence(timeout: 5),
                      "pressing Розібрати must be what advances the tour")
        tab("Бюджет", in: app).tap()

        // Flow three: where banks live.
        XCTAssertTrue(app.otherElements["walkthrough.step.3"].waitForExistence(timeout: 5))
        tab("Головна", in: app).tap()

        XCTAssertTrue(app.otherElements["walkthrough.step.4"].waitForExistence(timeout: 5))
        app.buttons["walkthrough.next"].tap()
        XCTAssertFalse(app.otherElements["walkthrough.step.4"].waitForExistence(timeout: 2),
                       "«Зрозуміло» ends the tour")
    }

    /// The card's second box. A tour that came back would be worse than none.
    ///
    /// **No `-resetState` on the second launch**, which is the point: the
    /// stamp has to survive in the settings file, not in memory.
    @MainActor
    func testTheWalkthroughNeverComesBack() {
        let app = firstLaunch()
        app.launch()
        XCTAssertTrue(app.otherElements["walkthrough.step.0"].waitForExistence(timeout: 15))
        app.buttons["walkthrough.close"].tap()

        let again = XCUIApplication()
        // No `-resetState` AND no `-showGuide`: the second launch must find
        // the stamp in the settings file on its own.
        again.launchArguments = ["-skipOnboarding", "-noBiometrics", "-lang", "uk",
                                 "-stubMonobank"]
        again.launch()
        XCTAssertTrue(again.tabBars.buttons["Головна"].waitForExistence(timeout: 15))
        XCTAssertFalse(again.otherElements["walkthrough.step.0"].exists,
                       "a closed tour must not come back on the next launch")
    }

    /// **Both languages from day one** — the card asks for it by name, and PR
    /// #93's lesson is why: copy assembled in code arrives as a runtime
    /// `String` and takes `Text`'s verbatim overload, so it ships Ukrainian to
    /// an English reader while the buttons around it are translated.
    ///
    /// The walkthrough's steps are built in code exactly like `GuideView`'s
    /// pages, which is where that bug was found.
    @MainActor
    func testTheWalkthroughSpeaksEnglishToAnEnglishPhone() {
        let app = firstLaunch("en")
        app.launch()
        let body = app.staticTexts["walkthrough.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        XCTAssertTrue(body.label.contains("A short tour"),
                      "the opening card is still Ukrainian on an English phone: \(body.label)")

        app.buttons["walkthrough.next"].tap()
        XCTAssertTrue(app.otherElements["walkthrough.step.1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["walkthrough.body"].label.contains("Press “Sort”"),
                      "…and so is the step that names a tab")
    }
}
