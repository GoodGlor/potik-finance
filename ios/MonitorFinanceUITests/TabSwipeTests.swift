import XCTest

/// Board #63. Swipe left or right to move between the five tabs.
///
/// Half of this file is about what the gesture must NOT take: every tab is a
/// vertical `ScrollView`, the left edge is `NavigationStack`'s way back out of
/// every pushed screen in the app, and the lock keeps the tabs mounted behind
/// it. A swipe that changed tabs in any of those cases would have taken
/// something a person already relies on and given back a convenience.
final class TabSwipeTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(tab: String = "0") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", tab, "-lang", "uk"]
        app.launch()
        return app
    }

    /// Which tab the bar itself says is selected — the app's own answer, not
    /// a guess from whichever title happens to be on screen. A large
    /// navigation title collapses as its screen scrolls, so reading the title
    /// would make a scrolling test look like a tab change.
    private func selectedTab(_ app: XCUIApplication) -> String {
        let buttons = app.tabBars.buttons
        for i in 0..<buttons.count where buttons.element(boundBy: i).isSelected {
            return buttons.element(boundBy: i).label
        }
        return "none"
    }

    /// Waited for, not read straight after the drag: the change is animated,
    /// and an immediate read can still return the tab the app had before it.
    ///
    /// A hand-rolled poll rather than `expectation(for:evaluatedWith:)`, and
    /// the reason is measured: that expectation re-resolves its element query
    /// and snapshots the whole accessibility tree on every evaluation, and on
    /// these screens — 114 feed rows, 61 queue cards — three of them in one
    /// test took **914 seconds**. The same test with this loop takes ten.
    private func waitForTab(_ app: XCUIApplication, _ name: String,
                            _ message: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if selectedTab(app) == name { return }
            usleep(150_000)
        }
        XCTFail(message + " — on " + selectedTab(app), file: file, line: line)
    }

    /// A horizontal drag between two points, in fractions of the screen.
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat, y: CGFloat = 0.45) {
        app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: y))
            .press(forDuration: 0.02,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: y)))
    }

    // MARK: what it does

    /// Board #115 narrowed where this works: Стрічка and Статистика now spend
    /// the swipe on their own pages, so the walk runs over the three tabs that
    /// still own it. Both directions, from a tab with a neighbour either way.
    func testSwipingLeftAndRightWalksTheTabs() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        XCTAssertEqual(selectedTab(app), "Головна")

        drag(app, from: 0.85, to: 0.2)
        waitForTab(app, "Стрічка", "a left swipe moves one tab along")

        let budget = launch(tab: "2")
        XCTAssertTrue(budget.marker("budget.title").waitForExistence(timeout: 10))
        drag(budget, from: 0.85, to: 0.2)
        waitForTab(budget, "Статистика", "…and a left swipe from Бюджет moves along too")

        let again = launch(tab: "2")
        XCTAssertTrue(again.marker("budget.title").waitForExistence(timeout: 10))
        drag(again, from: 0.4, to: 0.95)
        waitForTab(again, "Стрічка", "a right swipe moves one tab back")
    }

    /// **Board #131 reversed board #115, and this is the assertion that flipped.**
    ///
    /// #115 made Стрічка and Статистика spend the swipe on their own content
    /// and stop changing tab. The owner used it on a phone and rejected it:
    /// «Now I can't swipe from statistics to budget or to analyze». Two tabs
    /// behaving unlike the other three reads as broken, not as a design.
    ///
    /// So all five change tab, and the content those two used to page keeps
    /// the controls it always had — the feed's chevrons and month sheet
    /// (#109), the statistics scope buttons.
    func testTheFeedAndStatisticsChangeTabLikeEveryOtherScreen() {
        // Swipe away, then swipe BACK before reading the content. A tab that
        // is not on screen may not be in the accessibility tree at all, so
        // asserting about the feed's month from Головна would be asserting
        // about an element that is simply absent.
        let feed = launch(tab: "1")
        XCTAssertTrue(feed.buttons["feed.month"].waitForExistence(timeout: 10))
        let month = feed.buttons["feed.month"].label
        drag(feed, from: 0.4, to: 0.95)
        waitForTab(feed, "Головна", "a right swipe on the feed goes back a TAB")
        drag(feed, from: 0.85, to: 0.2)
        waitForTab(feed, "Стрічка", "and forward returns")
        XCTAssertEqual(feed.buttons["feed.month"].label, month,
                       "…having moved no month on the way out or back")

        let stats = launch(tab: "3")
        XCTAssertTrue(stats.marker("stats.scope").waitForExistence(timeout: 10))
        XCTAssertTrue(stats.buttons["Місяць"].isSelected, "precondition: it opens on the month")
        drag(stats, from: 0.85, to: 0.2)
        waitForTab(stats, "Розібрати", "a left swipe from statistics moves along too")
        drag(stats, from: 0.4, to: 0.95)
        waitForTab(stats, "Статистика", "and back")
        XCTAssertTrue(stats.buttons["Місяць"].isSelected,
                      "…with the scope untouched — it belongs to the buttons now")
    }

    /// The ends do not wrap. Wrapping would put Розібрати one swipe to the
    /// left of Головна, which is the tab with the badge on it — the one place
    /// an accidental arrival costs the most.
    func testTheEndsDoNotWrapAround() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        drag(app, from: 0.4, to: 0.95)
        XCTAssertEqual(selectedTab(app), "Головна", "there is nothing to the left of the first")

        let last = launch(tab: "4")
        XCTAssertTrue(last.staticTexts["queue.progress"].waitForExistence(timeout: 10))
        drag(last, from: 0.85, to: 0.2)
        XCTAssertEqual(selectedTab(last), "Розібрати", "…or to the right of the last")
    }

    // MARK: what it must not take

    /// A vertical drag past 40pt DOES begin the gesture — that is the price of
    /// high priority — so this is the assertion that the ScrollView keeps its
    /// own pan anyway, and that a vertical drag is not read as a sideways one.
    func testAVerticalSwipeStillScrollsAndChangesNothing() {
        let app = launch(tab: "1")
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let before = rows.firstMatch.frame.midY

        app.swipeUp()

        XCTAssertNotEqual(rows.firstMatch.frame.midY, before,
                          "the list must still scroll — the gesture must not have eaten the pan")
        XCTAssertEqual(selectedTab(app), "Стрічка", "…and a vertical drag is not a tab change")
    }

    /// **Board #132, reported from a phone and reproduced here.**
    ///
    /// > «if I slowly and smoothly scroll down, everything works … but if I
    /// > make short swipes up or down, it works once or doesn't respond at all»
    ///
    /// The test above passes and misses this entirely, because `swipeUp()` is
    /// a long drag. The owner's case is a SHORT and FAST one, and speed is the
    /// variable that matters: `minimumDistance: 40` is crossed almost
    /// instantly by a flick, so the high-priority drag claims the touch before
    /// the ScrollView's pan can — then `onEnded` finds it vertical, does
    /// nothing, and the scroll that was asked for never happens.
    ///
    /// **⚠️ THIS DOES NOT REPRODUCE THE OWNER'S REPORT, and the failed attempts
    /// are recorded here so nobody spends the afternoon again.**
    ///
    /// Two versions were tried against the unfixed code and neither fired
    /// honestly:
    ///
    /// 1. «every one of three short fast flicks must scroll» — **passed**. The
    ///    simulator scrolls fine on synthesised flicks.
    /// 2. «four fast flicks must move the list as far as four slow drags of
    ///    the same length» — **failed, for the wrong reason.** A fast flick
    ///    carries inertia and legitimately scrolls further. The assertion was
    ///    wrong, not the app.
    ///
    /// XCUITest's synthesised gestures do not reproduce what a thumb does on a
    /// device, so **this bug cannot currently be caught in CI.** What survives
    /// is the weaker claim below, which is true and worth keeping: a fast
    /// flick scrolls, and does not change tab. The owner's phone is the only
    /// gate for the real thing.
    func testAShortFastFlickScrollsAndDoesNotChangeTab() {
        let app = launch(tab: "1")
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        for attempt in 1...3 {
            let before = rows.firstMatch.frame.midY
            flick(app, fromY: 0.62, toY: 0.44, velocity: .fast)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, rows.firstMatch.frame.midY == before { usleep(100_000) }
            XCTAssertNotEqual(rows.firstMatch.frame.midY, before,
                              "flick \(attempt) did not scroll — the swipe gesture ate the pan")
        }
        XCTAssertEqual(selectedTab(app), "Стрічка", "…and no flick changed tab")
    }

    /// Short and fast, which is the combination that breaks. `.fast` is the
    /// point: the same distance dragged slowly is handled correctly today.
    private func flick(_ app: XCUIApplication, fromY: CGFloat, toY: CGFloat,
                       velocity: XCUIGestureVelocity) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
            .press(forDuration: 0.01,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY)),
                   withVelocity: velocity,
                   thenHoldForDuration: 0)
    }

    /// The left edge belongs to `NavigationStack`'s interactive pop, and it is
    /// the way back out of every pushed screen in the app. Taking it for a tab
    /// change would trade a gesture people already rely on for one they have
    /// just been given.
    func testTheLeftEdgeStillPopsInsteadOfChangingTab() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.open.about"].waitForExistence(timeout: 5))

        drag(app, from: 0.005, to: 0.9)

        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 5),
                      "the edge swipe must still pop the pushed screen")
        XCTAssertEqual(selectedTab(app), "Головна", "…and must not have changed tab as well")
    }

    /// The tabs stay MOUNTED while the lock is up — that is what `hideTabs` is
    /// for — so without the guard a swipe on the lock screen would silently
    /// move the app underneath it, and the person would unlock onto a tab they
    /// never chose.
    func testASwipeBehindTheLockChangesNothing() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        app.buttons["settings.security"].tap()
        let toggle = app.switches["settings.lockImmediately"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" { toggle.tap() }

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Введіть код"].waitForExistence(timeout: 10))

        drag(app, from: 0.85, to: 0.2)
        drag(app, from: 0.85, to: 0.2)

        for d in "1111" { app.buttons["pin.key.\(d)"].tap() }
        XCTAssertTrue(app.tabBars.buttons["Головна"].waitForExistence(timeout: 5))
        XCTAssertEqual(selectedTab(app), "Головна",
                       "two swipes behind the lock must not move the app underneath it")
    }

    /// The failure that actually happened, and the reason the gesture is high
    /// priority. Nearly every screen here is full-width `Button`s, and a
    /// horizontal drag across one never leaves its bounds — so with an
    /// ordinary simultaneous gesture the button took the touch and fired as a
    /// TAP. A left swipe on Головна opened Бюджет by pressing the card it
    /// passed over, and arrived on the right tab for entirely the wrong
    /// reason.
    /// Board #115 made the swipe page a month here; board #131 gave it back to
    /// the tabs. **Neither changed what this test is for** — the subject is
    /// still "a horizontal drag across a full-width button must not press it",
    /// on the same screen made of 114 of them. Only the proof that the swipe
    /// took effect changed, from a month moving to a tab moving.
    func testASwipeAcrossAFullWidthButtonDoesNotPressIt() {
        let app = launch(tab: "1")           // the feed: 114 rows, all buttons
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // Straight across a row, at the height of the first one. Rightward,
        // towards Головна: Стрічка has a tab on either side, so either
        // direction proves it — this one keeps the drag identical to the
        // version this test was written with.
        let y = rows.firstMatch.frame.midY / app.frame.height
        drag(app, from: 0.2, to: 0.85, y: y)

        waitForTab(app, "Головна", "the swipe must take effect")
        XCTAssertFalse(app.marker("detail.title").exists,
                       "…and must not have opened the purchase it crossed")
    }

    /// Taps have to go on working, which is what `minimumDistance` buys: under
    /// 40pt the gesture never begins and the button gets its touch as before.
    func testATapStillReachesTheButtonUnderneath() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.open.about"].waitForExistence(timeout: 5),
                      "a tap must still be a tap")
    }

    /// A diagonal flick — the one the ratio exists for. `abs(dx) > 80` alone
    /// lets this through: 120pt sideways over 260pt down is a scroll that
    /// drifted, not a sideways swipe, and without the 2:1 rule it lands the
    /// person on another tab halfway through reading a list.
    func testADiagonalDragIsAScrollAndNotATabChange() {
        let app = launch(tab: "1")
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.15)))

        XCTAssertEqual(selectedTab(app), "Стрічка",
                       "a drag with more vertical than horizontal in it is a scroll")
    }

    /// The regression the one-line version caused, on a screen this card never
    /// mentions. `swipeActions` on the Правила rows is how a person forgets a
    /// rule, and a high-priority gesture on an ancestor beats it — the full UI
    /// suite reported two dead tests before the gesture moved inside each
    /// stack.
    ///
    /// It lives here rather than in `SettingsTests` because it is an assertion
    /// about the SWIPE, not about the rules screen; the two tests it broke are
    /// still there and still test what their own names say.
    func testAPushedScreensSwipeActionsStillWork() {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-lang", "uk"]
        app.launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.categories"].tap()
        let rules = app.buttons["settings.open.rules"]
        XCTAssertTrue(rules.waitForExistence(timeout: 5))
        rules.tap()

        XCTAssertTrue(app.marker("settings.rules").waitForExistence(timeout: 5))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.rules.row.'"))
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5))
        rows.element(boundBy: 0).swipeLeft()

        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'settings.rules.forget.'"))
            .firstMatch.waitForExistence(timeout: 3),
                      "the tab swipe must not eat a pushed list row's swipe action")
        XCTAssertEqual(selectedTab(app), "Головна", "…and must not have changed tab either")
    }

    /// The other half of moving the gesture inside the stacks: a swipe on a
    /// PUSHED screen is not a tab change. The one-line version allowed it, and
    /// called it a deliberate trade; it was the same bug wearing a better
    /// explanation.
    func testASwipeOnAPushedScreenChangesNothing() {
        let app = launch()
        XCTAssertTrue(app.marker("home.title").waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.open.about"].waitForExistence(timeout: 5))

        // Below the five rows, so the drag crosses empty ground. Across a row
        // it would land on that row as a tap — which is what a drag has always
        // done on a screen made of full-width buttons, and is the behaviour
        // this card deliberately does NOT change on a pushed screen.
        drag(app, from: 0.85, to: 0.2, y: 0.8)

        XCTAssertEqual(selectedTab(app), "Головна",
                       "a pushed screen belongs to its tab and must stay there")
        XCTAssertTrue(app.buttons["settings.open.about"].exists,
                      "…and must still be showing")
    }
}
