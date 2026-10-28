import XCTest

/// The import path a person actually walks: «Вибрати файл» → the system
/// Files sheet → a real .xlsx on the device → the app's own summary.
///
/// `PrivatImportTests` covers the same screens with `-stubPrivatStatement`,
/// which hands the fixture straight to the importer and never opens Files.
/// That leaves the half that only runs in production untested: presenting
/// `.fileImporter`, the security-scoped URL it returns, and reading bytes
/// off disk. This test is that half — the only one where the data reaches
/// the app through the file system.
///
/// Two things make it unlike every other test in the suite:
///
/// 1. **It needs a file to exist on the device.** The picker's file browser
///    is a remote view; XCUITest cannot see into it and a test cannot put a
///    file there. `ios/seed-privat-statement.sh` does that first, and
///    `ios/test.sh` runs it.
/// 2. **One tap is a coordinate, not a query.** The Files sheet publishes
///    its navigation title and nothing else — no cells, no search field. So
///    the file cell is tapped by position. Everything either side of that
///    tap is a real assertion, including the title, so a coordinate that
///    goes stale fails here rather than somewhere misleading.
final class PrivatFileImportTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Where the Files sheet puts its «Browse» tab and the FIRST file in a
    /// folder, as fractions of the screen. Fractions, not points, so the
    /// numbers survive a change of simulator size.
    ///
    /// "First" is the assumption to know about: it holds because the seeded
    /// statement is the only thing in On My iPhone on a test machine. If
    /// something else is put there and sorts ahead of it, this taps that
    /// instead — and the run fails on the row counts below rather than
    /// passing on the wrong file, which is the way round it should fail.
    private static let browseTab = CGVector(dx: 0.713, dy: 0.939)
    private static let firstFile = CGVector(dx: 0.176, dy: 0.295)

    private func type(_ pin: String, in app: XCUIApplication) {
        for d in pin { app.buttons["pin.key.\(d)"].tap() }
    }

    func testAStatementPickedFromFilesImportsItsRealRows() {
        let app = XCUIApplication()
        // No -stubPrivatStatement: «Вибрати файл» must open the real sheet.
        app.launchArguments = ["-noGuide", "-resetState", "-noBiometrics", "-stubMonobank", "-lang", "uk"]
        app.launch()

        app.startOnboarding()                            // board #16: welcome, then the PIN pad
        type("1111", in: app)
        XCTAssertTrue(app.staticTexts["Повторіть код"].waitForExistence(timeout: 3))
        type("1111", in: app)

        let privat = app.buttons["bank.row.privatbank"]
        XCTAssertTrue(privat.waitForExistence(timeout: 5))
        privat.tap()                                     // board #19: one tap, no «Далі»

        let statement = app.buttons["privat.source.statement"]
        XCTAssertTrue(statement.waitForExistence(timeout: 5),
                      "board #91: PrivatBank asks letters-or-statement first")
        statement.tap()

        let choose = app.buttons["import.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5),
                      "the statement side of the choice lands on the import screen")
        choose.tap()

        // The sheet is a separate view service. Its navigation title is the
        // one thing it publishes, so it is the only handle for "the picker
        // is up" — and the only way to tell which folder it opened in.
        let onDevice = app.staticTexts["On My iPhone"]
        let sheetIsUp = NSPredicate(format: "label IN {'Recents', 'On My iPhone'}")
        XCTAssertTrue(app.staticTexts.containing(sheetIsUp).firstMatch.waitForExistence(timeout: 10),
                      "«Вибрати файл» must present the system Files sheet")

        // Files reopens wherever it was left, so «Recents» is a first-run
        // state, not a given. Only reach for «Browse» when it is needed.
        if !onDevice.exists {
            app.coordinate(withNormalizedOffset: Self.browseTab).tap()
            XCTAssertTrue(onDevice.waitForExistence(timeout: 10),
                          "«Browse» must reach On My iPhone — where the statement was seeded")
        }

        app.coordinate(withNormalizedOffset: Self.firstFile).tap()

        // Everything past here proves the bytes came off the file system:
        // the sheet dismissed, the security-scoped URL read, and the same
        // parse → map → merge pipeline ran on a file nobody handed the app.
        XCTAssertTrue(app.staticTexts["import.summary"].waitForExistence(timeout: 10),
                      "picking privat-statement.xlsx must import it — if the sheet is still up, "
                      + "run ios/seed-privat-statement.sh, and check firstFile against the layout")

        // The fixture's real content, not a placeholder: 14 rows, of which 12
        // are UAH and 2 are foreign currency the app refuses to count. Same
        // numbers AppStoreImportTests asserts against the same bytes.
        XCTAssertTrue(app.staticTexts["Нових операцій: 12."].exists,
                      "twelve UAH rows must land")
        XCTAssertTrue(app.staticTexts["Картки: *1111, *2222"].exists,
                      "both UAH cards must be named")
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'в іншій валюті пропущено'"))
            .firstMatch.exists, "the two USD rows must be reported as skipped")

        let done = app.buttons["import.done"]
        assertLive(done)
        done.tap()
        XCTAssertTrue(app.buttons["bank.done"].waitForExistence(timeout: 5),
                      "«Далі» returns to the picker with a bank now connected")
    }
}
