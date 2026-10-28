import XCTest

/// Board #128 — the two labels that reached English readers in Ukrainian.
///
/// `Derived.categoryLabel` returned «Переказ між своїми картками» and «Без
/// категорії» as plain `String`s, and two screens drew them through `Text`.
/// **Both English translations were in the catalogue the whole time** and
/// neither was ever read.
///
/// `DetailTextTests` proves the function translates. **This proves the SCREEN
/// asks it to** — the half a unit test cannot reach, and the half that was
/// actually broken: the function was innocent until this card, the call sites
/// never passed a language because there was none to pass.
///
/// The first UI test in this project to launch in English. That absence is
/// most of why the defect lived so long.
final class CategoryLabelLanguageTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launchEnglish(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank",
                               "-stage", "unlocked", "-tab", tab, "-lang", "en"]
        app.launch()
        return app
    }

    /// A feed row's accessibility label carries its subtitle, which is where
    /// `categoryLabel` is drawn: «Transfer between your own cards · 15:50».
    ///
    /// **May 2026, not the month the feed opens on, and the seed is why.** All
    /// 36 empty-category rows in `demo.json` are TRANSFERS, and not one is in
    /// August — so the newest month shows this placeholder never, and «Без
    /// категорії» never appears in the demo feed at all. A first version of
    /// this test looked for «No category» on the opening screen and failed
    /// against the FIXED app, which would have read as the fix not working.
    /// The seed decides what a UI test can prove.
    func testAnEnglishPhoneReadsTheTransferPlaceholderInEnglish() {
        let app = launchEnglish(tab: "1")
        XCTAssertTrue(app.buttons["feed.month"].waitForExistence(timeout: 15))
        app.buttons["feed.month"].tap()
        let may = app.buttons["feed.month.2026-05"]
        XCTAssertTrue(may.waitForExistence(timeout: 5), "the month sheet must list May 2026")
        may.tap()

        let english = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Transfer between your own cards'")).firstMatch
        // The list is lazy, so a row below the fold is ABSENT from the tree,
        // not merely off screen — board #110's lesson. Scroll until it exists.
        var swipes = 0
        while !english.exists, swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(english.exists,
                      "no May row said «Transfer between your own cards» after \(swipes) "
                      + "screens — an English phone is still shown the Ukrainian placeholder")

        let ukrainian = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Переказ між своїми картками'")).firstMatch
        XCTAssertFalse(ukrainian.exists,
                       "…and no row may still be showing the Ukrainian one")
    }

    /// **A category NAME is the person's own data and is never translated.**
    /// The same guard board #96 wrote for bank names and card suffixes. Without
    /// this, "translate the placeholder" slides into "translate the category",
    /// which would rewrite what somebody typed.
    func testAnEnglishPhoneStillShowsTheOwnersOwnCategoryNames() {
        let app = launchEnglish(tab: "1")
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))

        // The seed's categories are Ukrainian words the owner chose. At least
        // one must survive untouched on an English phone.
        let ownData = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Продукти'")).firstMatch
        var swipes = 0
        while !ownData.exists, swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(ownData.exists,
                      "an English phone must still show «Продукти» — a category name is "
                      + "the person's data, not the app's copy")
    }
}
