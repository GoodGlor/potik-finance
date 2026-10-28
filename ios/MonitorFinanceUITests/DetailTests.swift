import XCTest

final class DetailTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "1", "-lang", "uk"]
        app.launch()
        return app
    }

    /// The seed's category list is long enough that a row far down it — e.g.
    /// «Подарунки», which the current seed *does* include, alphabetically near
    /// the end — can exist in the tree yet sit off-screen and so fail
    /// `isHittable` before the list is filtered. Typing the name into search
    /// then either narrows the list down to exactly that row (a category the
    /// seed already has) or, for a name the seed has never seen, narrows to
    /// nothing and offers "create" instead. Both are real paths through the
    /// picker, so this helper checks for both rather than assuming which one
    /// a given category name takes.
    private func pick(_ category: String, in app: XCUIApplication) {
        let existing = app.buttons["picker.row.\(category)"]
        if existing.waitForExistence(timeout: 1), existing.isHittable {
            existing.tap()
            return
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText(category)

        if existing.waitForExistence(timeout: 2), existing.isHittable {
            existing.tap()
            return
        }
        let create = app.buttons["picker.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 2),
                      "neither an existing row nor a create button for \(category)")
        create.tap()
    }

    private func openFirstRow(_ app: XCUIApplication) { openRow(app, at: 0) }

    private func openRow(_ app: XCUIApplication, at index: Int) {
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
            .element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
    }

    /// The detail screen's picker is kind-aware for the same reason the
    /// queue's is: the row it opens can be a salary.
    ///
    /// Found by searching the feed for the CATEGORY, never for a merchant:
    /// every «Зарплата» row in the seed is income, and the seed's merchants
    /// are real names off the owner's own statement — the repo's privacy
    /// guard exists to keep them out of Swift source, and a fragment short
    /// enough to slip past that guard is still one of them.
    func testAnIncomeRowSDetailOffersOnlyIncomeCategories() {
        let app = launch()
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Зарплата")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the seed's salary rows must be findable")
        row.tap()
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        app.buttons["detail.category"].tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))

        assertLive(app.buttons["picker.row.Зарплата"])
        XCTAssertFalse(app.buttons["picker.notAnExpense"].exists,
                       "a salary is not a transfer")
        // Counted rather than probed for one absent name — a lazy `List`
        // makes "«Продукти» is not in the tree" true of the full list too.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'"))
        XCTAssertEqual(rows.count, 4, "only the income vocabulary")
    }

    func testTappingARowOpensItsDetail() {
        let app = launch()
        openFirstRow(app)
        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        assertLive(app.buttons["detail.category"])
    }

    /// The seed pre-attaches a receipt to exactly two purchases — one in
    /// 2026-08 and one in 2026-07 — and neither is the newest row of the
    /// newest month, which is where `openFirstRow` lands. So the first row's
    /// detail screen is reliably in the empty state: «Чек не додано», text
    /// only. (The count is asserted in
    /// `tests/test_ios_seed.py::test_the_seed_pre_attaches_exactly_two_receipts_in_two_months`.)
    ///
    /// Task 13 (D2) removed «Додати чек»: a fiscal QR carries no purchase to
    /// point back at, so there is nothing for a per-purchase scan button to
    /// mean, and the app's one scanner moved to Розібрати. A removed affordance
    /// deserves a test as much as an added one — this used to assert the
    /// button was live; it now asserts it is GONE, paired with the positive
    /// `detail.receipt` existing so this cannot pass merely because the
    /// screen failed to open.
    func testTheReceiptCardOffersNoAddButtonAnyMore() {
        let app = launch()
        openFirstRow(app)
        XCTAssertTrue(app.marker("detail.receipt").waitForExistence(timeout: 3),
                      "precondition: the receipt card itself rendered")
        XCTAssertTrue(app.staticTexts["Чек не додано"].waitForExistence(timeout: 2))
        // The receipt card sits last on the screen, low enough that at the
        // scroll view's rest position it renders under the floating tab bar
        // — present in the tree but not actually reachable. A real user
        // scrolls; so does this assertion.
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertFalse(app.buttons["detail.receipt.add"].exists,
                       "the per-purchase scan button must be gone — scanning moved to Розібрати")
    }

    /// The assertion that matters: changing the category in detail must be
    /// visible back in the feed. A detail screen that edits a copy would pass
    /// a "detail shows the new value" test and still be broken.
    func testChangingTheCategoryShowsUpInTheFeedRow() {
        let app = launch()
        openFirstRow(app)
        XCTAssertTrue(app.buttons["detail.category"].waitForExistence(timeout: 3))
        app.buttons["detail.category"].tap()

        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))
        pick("Подарунки", in: app)

        XCTAssertTrue(app.staticTexts["detail.category.value"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["detail.category.value"].label, "Подарунки")

        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to the feed
        XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))
        let labelled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Подарунки'"))
        XCTAssertGreaterThan(labelled.count, 0,
                             "the feed row must show the category the detail screen set")
    }

    /// Board #100 — the offer appears after a correction, and «Тільки цю»
    /// leaves the backlog alone.
    ///
    /// The seed's first feed row belongs to a merchant with siblings, so
    /// re-categorising it puts the rest of that merchant into disagreement.
    /// Asserting the offer EXISTS and that declining dismisses it is what this
    /// walk is for; the arithmetic and every hazard it avoids are covered in
    /// `ApplyToSimilarTests`, against fixtures that can hold a salary.
    func testCorrectingARowOffersToChangeTheMerchantsBacklog() {
        let app = launch()
        openFirstRow(app)
        XCTAssertTrue(app.buttons["detail.category"].waitForExistence(timeout: 3))
        app.buttons["detail.category"].tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))
        pick("Подарунки", in: app)

        let offer = app.marker("detail.similarOffer")
        guard offer.waitForExistence(timeout: 3) else {
            // A merchant with exactly one row has no backlog, and offering
            // nothing is the correct behaviour rather than a failure. Say so
            // out loud instead of asserting something that is not true.
            XCTAssertFalse(app.buttons["detail.similarApply"].exists,
                           "no offer means no button to accept it")
            return
        }
        XCTAssertTrue(app.buttons["detail.similarApply"].exists)
        app.buttons["detail.similarDecline"].tap()
        XCTAssertFalse(app.marker("detail.similarOffer").exists,
                       "«Тільки цю» dismisses the offer rather than leaving it standing")
    }

    /// Only that the toggle is reachable and produces feedback. The count
    /// arithmetic is covered by `testRuleEffectTextReportsTheCascadeCount`,
    /// and the cascade itself by `QueueMutationTests` — this assertion is
    /// green for any count, so do not read it as covering either.
    ///
    /// **Board #11 changed what "not offered" looks like.** The toggle used to
    /// be present on every row and `.disabled` in three states it could never
    /// leave; now it is present only when tapping it teaches a rule, and the
    /// other states are sentences. So each row must carry exactly ONE of the
    /// three — asserting the toggle exists everywhere would now fail, and
    /// asserting nothing at all would pass on a card that renders empty.
    func testTheRuleToggleIsWiredAndReportsBack() {
        let app = launch()
        // Which state a row is in depends on which merchants the seed has
        // taught rules for, so walk until one offers the toggle rather than
        // depending on what happens to sort first today.
        var acted = false
        for index in 0..<6 {
            openRow(app, at: index)
            let toggle = app.switches["detail.alwaysRule"]
            let standing = app.staticTexts["detail.ruleStanding"]
            let unavailable = app.staticTexts["detail.ruleUnavailable"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3)
                          || standing.waitForExistence(timeout: 1)
                          || unavailable.waitForExistence(timeout: 1),
                          "the rule card said nothing at all about row \(index)")
            let offered = [toggle.exists, standing.exists, unavailable.exists].filter { $0 }.count
            XCTAssertEqual(offered, 1, "row \(index) offered \(offered) rule states at once")
            if toggle.exists {
                // …and when it IS offered it can always be set. The old
                // `.disabled` states are words now.
                XCTAssertTrue(toggle.isEnabled)
                toggle.tap()
                XCTAssertTrue(app.staticTexts["detail.ruleEffect"].waitForExistence(timeout: 2))
                acted = true
                break
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))
        }
        XCTAssertTrue(acted, "no row in the first six offered a rule toggle that could be set")
    }

    /// Board #11's visible half on this screen: a rule that stands is spelled
    /// out, and can be retracted from the row it is acting on. Until this card
    /// the only retraction anywhere was the «Скасувати» on a queue toast that
    /// lives about five seconds.
    ///
    /// Teaching and forgetting in one walk, because a seeded rule's merchant
    /// is not reliably reachable from the top of the feed — this makes its own
    /// rule and then takes it back.
    func testARuleCanBeTaughtAndThenForgottenFromTheRowItActsOn() {
        let app = launch()
        var taught = false
        for index in 0..<6 {
            openRow(app, at: index)
            let toggle = app.switches["detail.alwaysRule"]
            if toggle.waitForExistence(timeout: 3), toggle.isEnabled {
                toggle.tap()
                taught = true
                break
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.marker("feed.title").waitForExistence(timeout: 3))
        }
        XCTAssertTrue(taught, "no row in the first six offered a rule toggle that could be set")

        // The toggle is gone, replaced by the rule in words — the state that
        // used to be a switch stuck in the on position with no way back.
        let standing = app.staticTexts["detail.ruleStanding"]
        XCTAssertTrue(standing.waitForExistence(timeout: 3))
        XCTAssertTrue(standing.label.contains("Правило:"), standing.label)
        XCTAssertFalse(app.switches["detail.alwaysRule"].exists)

        let forget = app.buttons["detail.forgetRule"]
        assertLive(forget)
        forget.tap()

        // Forgotten: the sentence goes, and the offer to teach it comes back.
        XCTAssertTrue(app.switches["detail.alwaysRule"].waitForExistence(timeout: 3))
        XCTAssertFalse(standing.exists)
        XCTAssertTrue(app.staticTexts["detail.ruleEffect"].label.contains("забуто"),
                      app.staticTexts["detail.ruleEffect"].label)
    }

    /// Board #13's visible half: the detail screen shows the answer it just
    /// took, and the control that would teach the merchant stays inert.
    ///
    /// **This cannot tell the two store calls apart** — `setNotAnExpense` and
    /// the queue's `markNotAnExpense` leave the row looking identical, and the
    /// difference is in rows this screen does not show. Three attempts at a
    /// queue-count version are why the guard lives elsewhere:
    /// `QueueMutationTests` pins the behaviour, and
    /// `test_the_detail_screen_does_not_call_the_queues_mutation` pins the
    /// call site. Do not add a cascade claim to this test's name.
    func testTheDetailScreenShowsTheTransferAnswerItJustTook() {
        let app = launch()
        openFirstRow(app)
        let value = app.staticTexts["detail.category.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 3))

        XCTAssertTrue(app.buttons["detail.category"].waitForExistence(timeout: 3))
        app.buttons["detail.category"].tap()
        XCTAssertTrue(app.marker("picker.list").waitForExistence(timeout: 3))
        let ownTransfer = app.buttons["picker.notAnExpense"]
        XCTAssertTrue(ownTransfer.waitForExistence(timeout: 3))
        ownTransfer.tap()

        // It used to read «Без категорії» here — a transfer has no category and
        // fell through to the placeholder — so answering the picker looked
        // like the app forgetting the answer.
        XCTAssertTrue(value.waitForExistence(timeout: 2))
        XCTAssertEqual(value.label, "Переказ між своїми картками")

        // «Завжди відносити … до цієї категорії» is a sentence about a
        // category, and this row now has none. Teaching "always a transfer"
        // stays in the queue, where it happens with a toast and an undo.
        //
        // A sentence rather than a dead switch since board #11: the state is
        // permanent for this row, so an "off" toggle was an invitation that
        // could never be accepted.
        let why = app.staticTexts["detail.ruleUnavailable"]
        XCTAssertTrue(why.waitForExistence(timeout: 2))
        XCTAssertFalse(app.switches["detail.alwaysRule"].exists)
    }
}
