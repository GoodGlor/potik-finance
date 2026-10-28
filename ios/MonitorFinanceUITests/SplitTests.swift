import XCTest

/// Task 5: confirming a receipt's PRODUCT GROUPS from the feed — never the
/// transaction's SPENDING category, which lives in a different namespace and
/// which nothing here touches.
final class SplitTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-resetState", "-noBiometrics", "-stubMonobank", "-stage", "unlocked", "-tab", "1",
             "-lang", "uk"] + extra
        app.launch()
        return app
    }

    /// The seed's one fuel purchase carrying a receipt: 2026-08-19,
    /// transaction `551dced6…`, receipt item `dce6a3e1…` («Бензин
    /// А-95-Євро5», 800,00 ₴ — exactly the charge, so confirming it can
    /// never be refused). `uuidString` is always upper-case, regardless of
    /// the lower-case form `demo.json` stores.
    ///
    /// The transaction is named by its UUID and narrowed to by its SPENDING
    /// category, never by its seller: every merchant in `demo.json` comes
    /// off the owner's own bank statement, and the standing privacy rule —
    /// enforced by `tests/test_ios_seed.py::test_no_swift_source_names_a_merchant_from_the_seed`
    /// — is that none of them is ever written into source. This file used to
    /// breach it twice over.
    private static let fuelTxId = "551DCED6-6D40-5401-AAA6-50D42F5336A2"
    private static let fuelItemId = "DCE6A3E1-C39F-57FD-807A-2DD54242C2C5"
    private static let fuelReceiptId = "685383F4-E4EE-5C8E-ADE9-BD15ED420157"
    /// Its spending category, from the app's own frozen taxonomy — not a
    /// merchant. Narrows August 2026 from ~100 rows to 8, with this
    /// purchase second from the top.
    private static let fuelCategory = "Автомобіль"

    /// Another 2026-08 purchase in that same spending category, carrying no
    /// receipt in the seed (2026-08-17, 120,00 ₴). Attaching a receipt to
    /// this one puts TWO receipt-bearing rows in a single category-filtered
    /// feed — the fixture
    /// `testTwoExpandedReceiptsEachCarryTheirOwnConfirmButton` needs.
    private static let secondCarTxId = "1C3DEB13-0989-556B-B0C4-1B8047A6D6A1"

    /// A small purchase carrying no receipt in the seed: 2026-08-04,
    /// 200,00 ₴. Paired with the bundled cafe sample (287,01 ₴, matches no
    /// purchase in the seed by design — see `ReceiptTests`) to build the ONE
    /// fixture this task's view needs but the seed does not ship: a receipt
    /// whose items exceed its purchase. 200,00 ₴ against 287,01 ₴ of items is
    /// 87,01 ₴ over.
    ///
    /// Board #15 moved it. The fixture named «Платежі до бюджету», one of the
    /// forty seeded categories, and the trim folded that into «Послуги» — the
    /// search then found nothing, and the failure read like a broken picker
    /// rather than a stale constant.
    private static let smallTxId = "812B1E29-45A5-5871-A4EF-28E4820924C4"
    /// Its spending category, and the reason this row and not a cheaper one:
    /// both the pick list and the feed are reached by SEARCHING this text, and
    /// a category holding forty rows puts the wanted one below the fold where
    /// `isHittable` fails. «Готівка» has four rows in the whole seed, one of
    /// them in August 2026 — this one.
    private static let smallCategory = "Готівка"
    private static let refusalCopy = "Чек більший за покупку на 87,01 ₴ — не можемо розподілити"

    /// Reached by search, not by trusting the feed's default month. The
    /// default happens to already land on August 2026 — it is the newest
    /// month the seed has data in, same as both fixtures above — but a test
    /// that relied on that coincidence would be a test that reads "today" in
    /// disguise, and would start failing on its own once the seed's newest
    /// month moves. Searching narrows the current month to a handful of rows
    /// and stepping back through months while the wanted one is absent finds
    /// it regardless of where the default lands. Shared by both fixtures so
    /// the search field's own clear/retype behaviour is written once.
    ///
    /// The query is a SPENDING CATEGORY (`Derived.search` matches merchant
    /// **or** category), which is what lets this narrow the list without
    /// naming a merchant. It is not required to be unique — the row is
    /// identified by its transaction UUID, so the query only has to make the
    /// wanted row cheap to reach.
    @discardableResult
    private func openRow(_ app: XCUIApplication, txId: String, category: String) -> XCUIElement {
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        // A previous call may have left text in this same field — clear it
        // rather than typing on top of it, or the second search compounds
        // onto the first and matches nothing. Checked by the clear button's
        // OWN existence, not `field.value`: an empty `.searchable` field
        // reports its placeholder text as `value`, which reads as non-empty.
        let clear = app.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(category)

        let row = app.marker("feed.row.\(txId)")
        var found = false
        for _ in 0..<12 {
            if row.waitForExistence(timeout: 2) { found = true; break }
            let prev = app.buttons["feed.prevMonth"]
            guard prev.exists, prev.isEnabled else { break }
            prev.tap()
        }
        if !found {
            XCTAssertTrue(row.waitForExistence(timeout: 2),
                          "the purchase must be reachable from some month")
        }
        // A category query leaves several rows where a merchant query left
        // one, so the wanted row can render below the fold — present in the
        // tree, not actually tappable. Scroll only if it is not already
        // live, same "scroll if and only if needed" reasoning the rest of
        // this suite uses.
        for _ in 0..<3 where !row.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        return row
    }

    @discardableResult
    private func openFuelRow(_ app: XCUIApplication) -> XCUIElement {
        openRow(app, txId: Self.fuelTxId, category: Self.fuelCategory)
    }

    /// The feed row's own expander, `ReceiptItemsView(editable: true)`: tap
    /// its item's group, pick a different one, «Підтвердити», and the refusal
    /// text must stay absent while a positive marker — the row's own button,
    /// updated to the new pick — proves the picker sheet actually closed
    /// rather than the test merely failing to find something for an
    /// unrelated reason.
    ///
    /// Uses the real `receipt.item.group.<itemId>` /
    /// `receipt.confirm.<receiptId>` identifiers those controls carry. That
    /// was NOT always reachable this
    /// way: `FeedView`'s expansion wrapper used to carry a bare
    /// `.accessibilityIdentifier("feed.items.<uuid>")` on its `VStack`,
    /// which — the exact trap this repo has lost assertions to before —
    /// stamped that same string onto every descendant beneath it, including
    /// these two buttons, overwriting the identifiers they were given here.
    /// Fixed at the source in `FeedView.swift` (the identifier now lives on
    /// the seller `Text` leaf instead); see that file's comment for the
    /// `app.debugDescription` evidence. This test used to work around it by
    /// matching on label — deleted now that the real identifiers work.
    func testConfirmingTheFeedRowsSplitPicksADifferentGroupAndClosesTheSheet() {
        let app = launch()
        openFuelRow(app)

        let expand = app.buttons["feed.expand.\(Self.fuelTxId)"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        assertLive(expand)
        expand.tap()

        let items = app.marker("feed.items.\(Self.fuelTxId)")
        XCTAssertTrue(items.waitForExistence(timeout: 3),
                      "tapping the disclosure must expand the row in place")

        let groupButton = app.buttons["receipt.item.group.\(Self.fuelItemId)"]
        XCTAssertTrue(groupButton.waitForExistence(timeout: 3))
        assertLive(groupButton)
        XCTAssertEqual(groupButton.label, "Пальне та автотовари",
                       "precondition: the keyword guess for «Бензин А-95-Євро5»")
        groupButton.tap()

        let pickerList = app.marker("groupPicker.list")
        XCTAssertTrue(pickerList.waitForExistence(timeout: 3),
                      "precondition: the picker sheet actually opened")
        let dairy = app.buttons["groupPicker.Молочні продукти"]
        XCTAssertTrue(dairy.waitForExistence(timeout: 2))
        assertLive(dairy)
        dairy.tap()

        // Positive: the sheet closed (its list is gone) AND the row's own
        // button now shows the pick that was just made — not merely "some
        // sheet somewhere closed".
        XCTAssertTrue(groupButton.waitForExistence(timeout: 3))
        XCTAssertEqual(groupButton.label, "Молочні продукти",
                       "picking must dismiss the sheet and update the button's own label")
        XCTAssertFalse(app.marker("groupPicker.list").exists,
                       "the picker sheet must actually be gone, not merely covered")

        // The EXACT receipt-keyed identifier, not a prefix match: this
        // receipt ships in the seed, so its id is a known constant here and
        // naming it is what proves the footer really is keyed by the receipt
        // rather than merely carrying some identifier beginning with
        // `receipt.confirm.`.
        let confirm = app.buttons["receipt.confirm.\(Self.fuelReceiptId)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        assertLive(confirm)
        confirm.tap()

        // The negative half: this purchase's one item sums to exactly its
        // charge, so confirming it can never be refused.
        XCTAssertFalse(app.marker("receipt.splitRefused.\(Self.fuelReceiptId)").exists,
                       "the fuel purchase's one item cannot exceed its own charge")
        // …and its positive partner: the row is still there, still live, not
        // gone or dead — proof the screen did not simply fail to render.
        assertLive(confirm)
    }

    /// Board #184 — the picker can now CREATE a group, which it could not.
    ///
    /// **Owner:** «I can't create my own category for products in the receipt,
    /// for example, for Coca-Cola I would like to create the category Soft
    /// Water.» The unit side of this is `ProductGroupTests`; what only a UI
    /// test can prove is that the row is reachable — the offer appears when
    /// the search finds nothing, and taking it closes the sheet with the new
    /// name on the item, rather than leaving a sheet nobody can dismiss.
    ///
    /// The name is invented and is not the owner's own example, for the same
    /// reason every fixture here is: this repository is public.
    func testThePickerCanCreateAGroupThatDoesNotExistYet() {
        let app = launch()
        openFuelRow(app)

        let expand = app.buttons["feed.expand.\(Self.fuelTxId)"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        assertLive(expand)
        expand.tap()

        let groupButton = app.buttons["receipt.item.group.\(Self.fuelItemId)"]
        XCTAssertTrue(groupButton.waitForExistence(timeout: 3))
        assertLive(groupButton)
        groupButton.tap()

        XCTAssertTrue(app.marker("groupPicker.list").waitForExistence(timeout: 3),
                      "precondition: the picker sheet actually opened")
        // Nothing to create until something is typed — the offer is a
        // consequence of the search, not a permanent row.
        XCTAssertFalse(app.buttons["groupPicker.create"].exists,
                       "an empty search offers to create nothing")

        // Named by its own prompt, NOT `searchFields.firstMatch`. The feed is
        // still in the tree behind this sheet and it has a search field of its
        // own («Продавець або категорія»), which comes first — the first
        // version of this test typed the group name into the feed's filter and
        // then failed looking for a create row the picker had no reason to
        // show.
        let search = app.searchFields["Пошук товарної групи"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Мийні засоби для авто")

        let create = app.buttons["groupPicker.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 3),
                      "a name no group carries has to be offerable")
        assertLive(create)
        create.tap()

        // The sheet closed AND the item now carries the invented group —
        // not merely "some sheet somewhere closed".
        XCTAssertTrue(groupButton.waitForExistence(timeout: 3))
        XCTAssertEqual(groupButton.label, "Мийні засоби для авто",
                       "creating must pick what it created")
        XCTAssertFalse(app.marker("groupPicker.list").exists,
                       "the picker sheet must actually be gone, not merely covered")

        // …and it is offered on the way back in. Reached by SEARCHING for it
        // rather than by scrolling: a `List` is lazy, this group sits at index
        // twenty of twenty-two, and an unrendered cell is absent from the
        // accessibility tree — which the first version of this test read as
        // "the group was never created".
        groupButton.tap()
        XCTAssertTrue(app.marker("groupPicker.list").waitForExistence(timeout: 3))
        let searchAgain = app.searchFields["Пошук товарної групи"]
        XCTAssertTrue(searchAgain.waitForExistence(timeout: 3))
        searchAgain.tap()
        searchAgain.typeText("Мийні")

        let created = app.buttons["groupPicker.Мийні засоби для авто"]
        XCTAssertTrue(created.waitForExistence(timeout: 3),
                      "a created group that is not offered next time was not created")
        assertLive(created)
        // The duplicate half, free with the same keystrokes: a search that
        // finds the group must not also offer to create a second one.
        searchAgain.typeText(" засоби для авто")
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["groupPicker.create"].exists,
                       "typing the exact name of an existing group must not offer a duplicate")
    }

    /// D task 5's boundary: the DETAIL screen's receipt card reuses the same
    /// `ReceiptItemsView`, `editable` defaulting to false, so it must offer no
    /// way to touch a PRODUCT GROUP at all — that decision lives in the feed's
    /// expanded row only. The negative assertion is paired with
    /// `detail.receipt` existing, so this cannot pass merely because the
    /// screen failed to open.
    func testTheDetailReceiptCardOffersNoTappableGroup() {
        let app = launch()
        let row = openFuelRow(app)
        row.tap()

        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        // Positive partner: the receipt card itself rendered.
        XCTAssertTrue(app.marker("detail.receipt").waitForExistence(timeout: 3),
                      "precondition: the detail screen's receipt card must have opened")

        let anyGroupControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'receipt.item.group.'"))
            .firstMatch
        XCTAssertFalse(anyGroupControl.exists,
                       "the read-only detail card must not offer a product-group control")
        XCTAssertFalse(app.confirmButton().exists,
                       "…nor a confirm button — there is nothing here to confirm")
        XCTAssertFalse(app.buttons["receipt.confirm.\(Self.fuelReceiptId)"].exists,
                       "…named exactly, in case the prefix query above ever stops matching")
    }

    /// Reviewer finding: nothing exercised `.receiptExceedsPurchase` through
    /// the view. The seed's only pre-attached receipt (the fuel purchase
    /// above) sums to exactly its charge, so the refusal line and its
    /// copy were both unprovable — a regression swallowing the refusal would
    /// have stayed green through every other test here.
    ///
    /// Built the fixture the seed doesn't ship: `-seedNoPurchaseReceipt`
    /// injects a loose, already-landed receipt (287,01 ₴ of items, its sum
    /// the OLD bundled cafe sample's own — see `AppStore.live()`'s doc
    /// comment), hand-picked from Розібрати's own `.noPurchase` card onto the
    /// 97,00 ₴ purchase of 2026-08-20 (no receipt in the seed). Then expand
    /// that row in the feed (the only place «Підтвердити» exists) and
    /// confirm.
    ///
    /// Paired with `testConfirmingTheFeedRowsSplitPicksADifferentGroupAndClosesTheSheet`
    /// above: that test proves refusal stays ABSENT on a fitting receipt,
    /// this one proves it APPEARS on one that doesn't — neither can pass on
    /// its own against a view that always shows one or the other regardless
    /// of the arithmetic.
    func testConfirmingAReceiptThatExceedsThePurchaseIsRefused() {
        let app = launch(["-seedNoPurchaseReceipt"])
        attachCafeReceiptToSmallPurchase(app)

        // The nav bar's own back button, not a re-tap of the already-active
        // tab: `DetailTests.testChangingTheCategoryShowsUpInTheFeedRow` uses
        // the same call to return from a pushed detail screen to the feed
        // underneath it, in this same tab's `NavigationStack`. No need to
        // search again: `.searchable` stays active across the push and pop,
        // so the feed is still filtered down to this one row — confirmed via
        // `app.debugDescription` while writing this test, which also showed
        // WHY re-asserting `feed.month` right after the pop is the wrong
        // check here: iOS hides a searchable screen's normal toolbar (the
        // month stepper included) while search is active and swaps in its
        // own "Close" control, so `feed.month` is legitimately absent at
        // this exact point even though the feed itself is right there.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let expand = app.buttons["feed.expand.\(Self.smallTxId)"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        assertLive(expand)
        expand.tap()

        let items = app.marker("feed.items.\(Self.smallTxId)")
        XCTAssertTrue(items.waitForExistence(timeout: 3),
                      "tapping the disclosure must expand the row in place")

        // The seeded receipt's id is minted fresh by `AppStore.live()` on
        // every launch and no test can know it, so this one is reached by
        // the prefix of its receipt-keyed identifier. Only this row is expanded.
        let confirm = app.confirmButton()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        assertLive(confirm)
        confirm.tap()

        // 1: the refusal marker exists.
        let refused = app.splitRefusal()
        XCTAssertTrue(refused.waitForExistence(timeout: 3),
                      "a receipt whose items exceed the purchase must say so")
        // 2: its text names the actual difference.
        XCTAssertEqual(refused.label, Self.refusalCopy)

        // 3: the confirmation did not take effect. A second attempt refuses
        // identically rather than behaving any differently, which it would
        // if the first, refused attempt had silently written something.
        confirm.tap()
        let refusedAgain = app.splitRefusal()
        XCTAssertTrue(refusedAgain.waitForExistence(timeout: 3))
        XCTAssertEqual(refusedAgain.label, Self.refusalCopy,
                       "a second attempt must refuse identically — the first refusal must not "
                       + "have partially applied anything for this one to behave differently against")
    }

    /// Whole-branch finding: `receipt.confirm` and `receipt.splitRefused`
    /// were BARE, unlike the `receipt.item.group.<itemId>` buttons right
    /// above them in the same view. Feed rows expand independently — this
    /// test expands two — so the tree really can hold two «Підтвердити»
    /// buttons at once, and a query for a bare name resolves to whichever
    /// one it happens to list first. That is the shape of bug this repo has
    /// lost assertions to before: the test finds *a* control, taps it, and
    /// then reports on a screen it never touched.
    ///
    /// The second receipt is attached to another purchase in the SAME month
    /// and the SAME spending category as the seeded fuel one, so a single
    /// search shows both rows at once. Its own id is minted fresh at launch
    /// (`AppStore.live()`'s `-seedNoPurchaseReceipt` fixture) and cannot be
    /// named here — which is the point: the assertion is that the two
    /// identifiers DIFFER and that one of them is exactly the seeded
    /// receipt's.
    func testTwoExpandedReceiptsEachCarryTheirOwnConfirmButton() {
        let app = launch(["-seedNoPurchaseReceipt"])
        attachCafeReceipt(app, to: Self.secondCarTxId, category: Self.fuelCategory)
        // Back to the feed, still filtered to this spending category.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        for txId in [Self.fuelTxId, Self.secondCarTxId] {
            let expand = app.buttons["feed.expand.\(txId)"]
            XCTAssertTrue(expand.waitForExistence(timeout: 3),
                          "precondition: \(txId) must offer a disclosure")
            for _ in 0..<3 where !expand.isHittable { app.scrollViews.firstMatch.swipeUp() }
            assertLive(expand)
            expand.tap()
            XCTAssertTrue(app.marker("feed.items.\(txId)").waitForExistence(timeout: 3),
                          "precondition: both rows must be expanded at the same time")
        }

        let confirms = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'receipt.confirm.'"))
        XCTAssertEqual(confirms.count, 2,
                       "two expanded receipts must put two confirm buttons in the tree")
        let identifiers = Set((0..<confirms.count).map { confirms.element(boundBy: $0).identifier })
        XCTAssertEqual(identifiers.count, 2,
                       "…under two DIFFERENT identifiers — a bare name would collide")
        XCTAssertTrue(identifiers.contains("receipt.confirm.\(Self.fuelReceiptId)"),
                      "…one of which is the seeded receipt's own id: \(identifiers)")
        // Positive partner: with both on screen, the seeded one is still
        // reachable by name and still live — not merely present in a set.
        assertLive(app.buttons["receipt.confirm.\(Self.fuelReceiptId)"])
    }

    /// Drives Розібрати's own hand-pick instead of the old per-purchase «Додати
    /// чек» (D2 removed it — scanning has no purchase to reach FROM any
    /// more, so it only ever reaches TO one, from the queue).
    private func attachCafeReceiptToSmallPurchase(_ app: XCUIApplication) {
        attachCafeReceipt(app, to: Self.smallTxId, category: Self.smallCategory)
    }

    /// `-seedNoPurchaseReceipt` (passed by both callers' own `launch()`)
    /// stands in for a receipt whose items already landed — a live scan
    /// cannot reach that state in this launch shape at all:
    /// `fetchDueReceiptsIfAllowed` itself suppresses the tax cabinet fetch
    /// under `-stage unlocked`, to protect other suites' fixed fixtures, and
    /// its `fiscalSum` (287,01 ₴) is the OLD bundled cafe sample's own — see
    /// `AppStore.live()`'s doc comment on the fixture. Hand-picks it onto
    /// the given purchase (A6: `attachManually` tolerates the mismatch),
    /// then reaches that purchase's own detail screen via the feed's
    /// search, ending in the same place the old scanner-based helper did so
    /// callers can carry on unchanged.
    private func attachCafeReceipt(_ app: XCUIApplication, to txId: String, category: String) {
        app.tabBars.buttons["Розібрати"].tap()
        XCTAssertTrue(app.staticTexts["queue.progress"].waitForExistence(timeout: 5))
        let pick = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'queue.receipt.pick.'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5),
                      "precondition: the seeded fixture must render as a .noPurchase card")
        assertLive(pick)
        pick.tap()

        XCTAssertTrue(app.marker("queue.receipt.pickList").waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText(category)
        let pickRow = app.marker("queue.receipt.pickRow.\(txId)")
        XCTAssertTrue(pickRow.waitForExistence(timeout: 3))
        assertLive(pickRow)
        pickRow.tap()
        // Waited for, not read on the spot: the sheet's dismissal is
        // animated, and the card presenting it is itself about to leave
        // `receiptCards` on the very same update — same reasoning
        // `ReceiptTests` uses for its own scanner/sheet dismiss checks.
        let pickList = app.marker("queue.receipt.pickList")
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pickList)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "picking must dismiss the sheet")

        app.tabBars.buttons["Стрічка"].tap()
        let row = openRow(app, txId: txId, category: category)
        row.tap()

        XCTAssertTrue(app.marker("detail.title").waitForExistence(timeout: 3))
        XCTAssertTrue(app.marker("detail.receipt").waitForExistence(timeout: 3),
                      "precondition: the receipt card must show the newly attached receipt")
    }
}
