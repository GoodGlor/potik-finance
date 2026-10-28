import XCTest

/// Board #148 — «Виписки» on the ПриватБанк screen.
///
/// `StatementImportTests` in the unit target holds the model: what a record
/// contains, and that deleting with transactions removes only the rows the
/// file created. This holds the half a unit test cannot reach — **that the
/// question is asked at all.**
///
/// The owner's requirement was not "delete a statement"; it was «ask the user
/// whether to delete just the file or with transactions». A single destructive
/// button would satisfy every unit test in this feature and none of the ask.
final class StatementListTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func bankScreen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-skipOnboarding", "-noBiometrics",
                               "-noGuide", "-lang", "uk", "-stubMonobank",
                               // `-statements`: the list is about records that
                               // only a real file picker could otherwise create.
                               "-statements"]
        app.launch()
        return app
    }

    private func openPrivat(_ app: XCUIApplication) {
        let home = app.buttons["home.settings"]
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        home.tap()
        let settings = app.buttons["settings.banks"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let privat = app.buttons["banks.row.privatbank"]
        XCTAssertTrue(privat.waitForExistence(timeout: 10))
        privat.tap()
    }

    @MainActor
    func testTheImportedStatementsAreListed() {
        let app = bankScreen()
        openPrivat(app)

        let names = app.staticTexts.matching(identifier: "bank.statement.name")
        XCTAssertTrue(names.element(boundBy: 0).waitForExistence(timeout: 10),
                      "an imported statement must be listed where the person imports one")
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.element(boundBy: 0).label, "виписка-приклад-2.xlsx",
                       "newest first — the reason somebody opens this is the last import")

        // The older record brought three rows, and the line has to say so —
        // a list of filenames with no numbers cannot answer "which import was
        // that". Reported verbatim on failure, because the seeded ids either
        // match real transactions or the whole delete has nothing to take.
        let detail = app.staticTexts.matching(identifier: "bank.statement.detail")
            .element(boundBy: 1).label
        XCTAssertTrue(detail.contains("3"),
                      "the older record must name the rows it brought, got: \(detail)")
    }

    /// **The requirement, as a test.**
    ///
    /// Both answers have to be offered, and the destructive one has to say
    /// what it costs before it is tapped rather than reporting afterwards.
    @MainActor
    func testDeleteAsksWhichKindOfDeleteAndStatesTheCost() {
        let app = bankScreen()
        openPrivat(app)

        let delete = app.buttons.matching(identifier: "bank.statement.delete")
        XCTAssertTrue(delete.element(boundBy: 1).waitForExistence(timeout: 10))
        delete.element(boundBy: 1).tap()   // the older record, which created rows

        XCTAssertTrue(app.buttons["Видалити лише файл"].waitForExistence(timeout: 5),
                      "the file-only answer must be offered, not assumed")
        XCTAssertTrue(app.buttons["Видалити разом з операціями"].exists,
                      "and so must the one that takes the transactions")
        // **No cancel button is asserted, and that is not an oversight.**
        // A screenshot showed this dialog rendering as a POPOVER anchored to
        // the list, not as an action sheet — so SwiftUI omits the cancel
        // button, because tapping outside is the way out. Asserting for one
        // failed here for three runs while the dialog was perfectly correct.
        // It is also why `app.sheets` is empty and why the dialog's own texts
        // sit in the app's flat query rather than inside a sheet element.

        // The cost, on screen, before either is chosen. Read from the app's
        // flat query for the reason above — the popover's texts are not
        // inside a sheet element to look in.
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("Зникнуть") },
                      "the dialog must say what deleting costs before the tap; got: \(labels)")
        // …and say it in grammatical Ukrainian. «3 операцій» is the "many"
        // form on a number that takes the "few" one; only a screenshot caught
        // it, so the count goes through `Plural.operations` and this pins it.
        XCTAssertTrue(labels.contains { $0.contains("3 операції") },
                      "2–4 takes «операції», not «операцій»; got: \(labels)")
    }

    /// «Видалити лише файл» is the safe answer and has to behave like one.
    @MainActor
    func testDeletingOnlyTheFileLeavesTheOtherRecord() {
        let app = bankScreen()
        openPrivat(app)

        let delete = app.buttons.matching(identifier: "bank.statement.delete")
        XCTAssertTrue(delete.element(boundBy: 0).waitForExistence(timeout: 10))
        delete.element(boundBy: 0).tap()
        app.buttons["Видалити лише файл"].tap()

        let names = app.staticTexts.matching(identifier: "bank.statement.name")
        XCTAssertTrue(names.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(names.count, 1, "one record removed, the other untouched")
        XCTAssertEqual(names.element(boundBy: 0).label, "виписка-приклад-1.xlsx")
    }
}
