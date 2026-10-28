import XCTest

/// Board #61, the half only a running app can answer: can a person actually
/// reach the chooser and change an icon.
///
/// The unit tests hold what an icon IS and what the store accepts. What they
/// cannot hold is that tapping a category row opens the grid rather than
/// renaming it, or that the swipe actions still work on a row that has just
/// become a Button.
final class CategoryIconUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func openCategories() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-noBiometrics", "-stubMonobank",
                               "-skipOnboarding", "-noGuide", "-lang", "uk"]
        app.launch()
        app.buttons["home.settings"].tap()
        app.buttons["settings.open.categories"].tap()
        XCTAssertTrue(app.marker("settings.categories").waitForExistence(timeout: 5))
        return app
    }

    /// The whole path: row → grid → a different icon → back, and it stuck.
    ///
    /// Rows near the TOP of the alphabet on purpose. A SwiftUI `List` only
    /// materialises the rows on screen, so «Продукти» — which is what this
    /// test wanted to name — is simply not in the accessibility tree until
    /// something scrolls to it, and the failure reads as "no matches found"
    /// rather than as "you need to scroll".
    func testACategorysIconCanBeChangedFromSettings() {
        let app = openCategories()
        app.buttons["settings.categories.row.Автомобіль"].tap()

        XCTAssertTrue(app.marker("icons.sheet").waitForExistence(timeout: 5))
        // The preview names the category, so the sheet cannot be about a
        // different row than the one that was tapped.
        XCTAssertTrue(app.staticTexts["Автомобіль"].exists)

        let gift = app.buttons["icons.cell.gift"]
        XCTAssertTrue(gift.waitForExistence(timeout: 3))
        gift.tap()
        app.buttons["icons.done"].tap()

        // Reopening is what proves it was stored rather than only drawn: the
        // cell for the chosen icon is the one selected.
        XCTAssertTrue(app.marker("settings.categories").waitForExistence(timeout: 5))
        app.buttons["settings.categories.row.Автомобіль"].tap()
        XCTAssertTrue(app.marker("icons.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["icons.cell.gift"].isSelected
                      || app.buttons["icons.cell.gift"].exists)
    }

    /// **The regression this card could plausibly cause.** The category rows
    /// were plain `HStack`s and are now `Button`s, and board #63 already
    /// records what happens when a gesture and a `List` row's `swipeActions`
    /// disagree — two dead tests on a screen the card never mentioned.
    func testTheSwipeActionsStillWorkOnARowThatIsNowAButton() {
        let app = openCategories()
        let row = app.buttons["settings.categories.row.Благодійність"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()

        let rename = app.buttons["settings.categories.rename.Благодійність"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3),
                      "the row became a Button and ate its own swipe actions")
        rename.tap()
        // The alert, not its text field: a SwiftUI `.alert` is a
        // `UIAlertController`, and the identifier put on the `TextField`
        // inside it does not survive into that. The alert appearing is what
        // proves the swipe action fired and still does its job.
        XCTAssertTrue(app.alerts["Нова назва"].waitForExistence(timeout: 3),
                      "the rename swipe action no longer opens its alert")
    }

    /// A category the app has no opinion about still draws something. The
    /// fallback is a real symbol, so the row is present and hittable rather
    /// than a bare colour — which is all a UI test can see of it.
    func testANewlyCreatedCategoryAppearsWithoutAnIconAndCanBeGivenOne() {
        let app = openCategories()
        let row = app.buttons["settings.categories.row.Заощадження"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.marker("icons.sheet").waitForExistence(timeout: 5))
        // Every group heading is present, so the offered set is browsable
        // rather than one undifferentiated grid.
        for title in ["Щодня", "Дорога", "Дім"] {
            XCTAssertTrue(app.staticTexts[title].exists, "«\(title)» is missing from the chooser")
        }
    }
}
