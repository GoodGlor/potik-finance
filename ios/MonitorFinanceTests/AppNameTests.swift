import XCTest
@testable import MonitorFinance

/// Board #130 — the app's own name, in the reader's own script.
///
/// #106 chose **Потік / Potik**; this card left one thing open — Latin
/// everywhere, or Cyrillic for the Ukrainian reader. Decided: the name is
/// TRANSLITERATED, not translated. It stays the same word; only the script
/// changes, so the brand survives a language switch.
///
/// That decision needed **no new mechanism**, which is most of why it is the
/// right one. The catalogue's whole idiom is that the Ukrainian source text is
/// the key, so the app's name is one ordinary row and it degrades the same
/// safe way as every other string — a missing entry shows «Потік», never a
/// raw identifier.
///
/// The pytest half is `tests/test_ios_rename.py`, which guards the two names
/// that must NOT follow the rename: the bundle id and the data directory.
@MainActor
final class AppNameTests: XCTestCase {

    override func tearDown() {
        L10n.setFormatting(.uk)
        super.tearDown()
    }

    /// The name is a real catalogue row in both directions.
    func testTheNameIsTransliteratedForAnEnglishReader() {
        XCTAssertEqual(L10n.t("Потік", .en), "Potik")
        XCTAssertEqual(L10n.t("Потік", .uk), "Потік",
                       "a Ukrainian reader sees the word itself — the key IS the value")
    }

    /// **iOS draws this sentence, so getting it wrong is invisible in a
    /// screenshot of our own screens.** The Face ID alert is the system's;
    /// only the reason line is ours.
    ///
    /// It is also assembled outside a view, which is the shape that has broken
    /// twice on this project (boards #96 and #128): there is no environment to
    /// read, so a `Text` literal would never be translated at all.
    func testTheFaceIDReasonNamesTheAppInBothLanguages() {
        XCTAssertEqual(L10n.t("Увійти в Потік", .en), "Sign in to Potik")
        XCTAssertEqual(L10n.t("Увійти в Потік", .uk), "Увійти в Потік")
    }

    /// The working title is gone from the catalogue's answers.
    ///
    /// Asserted against what a person is SHOWN rather than against the source,
    /// because the bundle id and `Application Support/MonitorFinance` keep the
    /// old word on purpose — the source still contains it, correctly.
    func testNothingTheCatalogueAnswersStillSaysTheWorkingTitle() {
        for language in [AppLanguage.uk, .en] {
            XCTAssertFalse(L10n.t("Потік", language).contains("MonitorFinance"))
            XCTAssertFalse(L10n.t("Увійти в Потік", language).contains("MonitorFinance"))
        }
    }
}
