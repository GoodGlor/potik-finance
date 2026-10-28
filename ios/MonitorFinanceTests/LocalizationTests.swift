import XCTest
@testable import MonitorFinance

/// Board #85 — the English interface, tested where it can actually be wrong.
///
/// Localisation fails quietly. A missing entry renders as the Ukrainian key,
/// a `String`-typed parameter renders the key with no lookup at all, and the
/// obvious API for "give me this string in that language" returns the wrong
/// language while compiling and running perfectly. **Nothing on screen says
/// any of it happened** — which is why these are tests rather than a walk
/// through the app.
///
/// The pytest half is `tests/test_ios_localization.py`: the rules about
/// SOURCE — which literals may never be translated, who may write
/// `L10n.formatting`, which launch lists must pin a language — that no test
/// running inside the app can see.
@MainActor
final class LocalizationTests: XCTestCase {

    /// Every test here sets the formatting it is about. `L10n.formatting` is
    /// process-wide and the suite shares a process, so a test that left
    /// English behind would break whichever Ukrainian test ran next — the
    /// exact failure `pinUkrainianFormatting` exists for.
    override func tearDown() {
        L10n.setFormatting(.uk)
        super.tearDown()
    }

    // MARK: - The trap

    /// **`String(localized:locale:)` does not select a localization**, and the
    /// whole feature was nearly built on the belief that it does.
    ///
    /// The `locale:` argument formats numbers and dates *inside* the returned
    /// string. Which language is read comes from the BUNDLE and the device's
    /// preferred languages, so asking for `locale: uk` on an English phone
    /// returns "Categories". It compiles, it runs, it is silently wrong.
    ///
    /// Asserted as "the two locales return the SAME string" rather than by
    /// naming a language, because what comes back depends on the device this
    /// runs on — and the point is precisely that the argument changed nothing.
    func testTheLocaleArgumentDoesNotSelectALocalization() {
        let asUkrainian = String(localized: "Категорії", locale: Locale(identifier: "uk"))
        let asEnglish = String(localized: "Категорії", locale: Locale(identifier: "en"))

        XCTAssertEqual(asUkrainian, asEnglish,
                       "if these ever differ, the platform changed and L10n can be deleted")
        // And it is one of the two real answers rather than a raw key — which
        // is what makes the assertion above meaningful instead of vacuous.
        XCTAssertTrue(["Категорії", "Categories"].contains(asUkrainian), asUkrainian)
    }

    /// Naming the bundle is what selects a localization — the whole of `L10n`.
    ///
    /// This also proves both `.lproj` folders reached the built app. They are
    /// copied by folder membership rather than by a build phase anybody
    /// reviews, so "the catalogue did not ship" is a live failure mode, and
    /// its symptom is an English speaker seeing Ukrainian.
    func testNamingTheBundleIsWhatSelectsALocalization() {
        XCTAssertEqual(L10n.t("Категорії", .en), "Categories")
        XCTAssertEqual(L10n.t("Категорії", .uk), "Категорії",
                       "the Ukrainian catalogue is identity — the key IS the text")
    }

    /// A key nobody translated comes back as itself, in Ukrainian. This is the
    /// safe direction, and it is the entire argument for keys being the
    /// Ukrainian source text rather than `common.done`.
    func testAnUntranslatedKeyFallsBackToUkrainianRatherThanToAnIdentifier() {
        let missing = "Такого рядка в застосунку немає"
        XCTAssertEqual(L10n.t(missing, .en), missing)
    }

    // MARK: - The catalogue

    /// The English catalogue, read out of the app bundle exactly as the app
    /// reads it. `NSDictionary(contentsOf:)` parses `.strings` natively, so a
    /// file this cannot open is a file the loader could not have used either.
    private func englishCatalogue() throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"),
                                 "en.lproj did not ship — English would silently be Ukrainian")
        let bundle = try XCTUnwrap(Bundle(path: path))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                             "the catalogue did not parse — a stray quote or missing semicolon")
    }

    /// A syntax error in a `.strings` file does not fail the build. The file
    /// simply fails to parse and **every** key falls through to Ukrainian, so
    /// the whole feature turns itself off with no diagnostic anywhere.
    func testTheEnglishCatalogueParsesAndIsNotEmpty() throws {
        let catalogue = try englishCatalogue()
        XCTAssertGreaterThan(catalogue.count, 300,
                             "353 at the time of writing; a collapse to a handful means a parse failure")
    }

    /// A value identical to its key is an entry somebody added and never
    /// translated. It reads as "done" in the file and renders as Ukrainian on
    /// the screen — the one failure this scheme's safe fallback hides.
    func testNoEnglishEntryIsStillItsUkrainianKey() throws {
        let untranslated = try englishCatalogue()
            .filter { $0.key == $0.value }
            .keys.sorted()
        XCTAssertEqual(untranslated, [], "entries present but untranslated")
    }

    /// **A specifier that does not match its key crashes or prints garbage.**
    ///
    /// SwiftUI chooses `%@` or `%lld` from the type it interpolates, and the
    /// English side has to repeat that choice exactly. Get it wrong and
    /// `String(format:)` reads the wrong-sized argument off the stack — a
    /// `%@` against an `Int` is a pointer built from a number. The order
    /// matters as much as the count, so the lists are compared in sequence.
    func testEveryEnglishEntryKeepsItsKeysFormatSpecifiers() throws {
        let specifier = try NSRegularExpression(pattern: "%(%|@|lld|ld|d|\\.?[0-9]*f)")
        func specifiers(_ s: String) -> [String] {
            let range = NSRange(s.startIndex..., in: s)
            return specifier.matches(in: s, range: range).compactMap {
                Range($0.range, in: s).map { r in String(s[r]) }
            }
        }

        // The control. Two empty lists are equal, so a regex that matched
        // nothing would report every entry as fine — the shape of vacuous
        // pass this repo has been bitten by before. Ten is well under the
        // real count and well over zero.
        let catalogue = try englishCatalogue()
        let carrying = catalogue.keys.filter { !specifiers($0).isEmpty }
        XCTAssertGreaterThan(carrying.count, 10,
                             "the specifier regex matched almost nothing — the check below is vacuous")
        XCTAssertEqual(specifiers("%lld операцій за %lld міс."), ["%lld", "%lld"])
        XCTAssertEqual(specifiers("%@ — %.1f рази на місяць"), ["%@", "%.1f"])

        var wrong: [String] = []
        for (key, value) in catalogue where specifiers(key) != specifiers(value) {
            wrong.append("\(key) → \(specifiers(key)) vs \(specifiers(value))")
        }
        XCTAssertEqual(wrong.sorted(), [], "a mismatched specifier is a crash, not a typo")
    }

    // MARK: - What is NOT translated

    /// The three category names the app itself reaches for by name. They are
    /// data — a transaction, a rule and a budget line all reference a category
    /// by its name, and the person can rename it — so translating one would
    /// orphan every row pointing at it.
    ///
    /// `BudgetMath.cashCategory` and friends are the load-bearing ones: they
    /// are compared against stored strings in code, not merely displayed.
    func testTheCategoryNamesTheCodeMatchesOnAreNotTranslated() throws {
        let catalogue = try englishCatalogue()
        for name in ["Інше", "Готівка", "Заощадження", "Зарплата"] {
            XCTAssertNil(catalogue[name],
                         "«\(name)» is a category name — data, matched on by code — not copy")
        }
    }

    // MARK: - The language itself

    /// `.system` must always become a real language, and Ukrainian is the
    /// fallback for everything that is not English: this app spends hryvnia
    /// through Ukrainian banks, so a phone set to German belongs to somebody
    /// far more likely to read Ukrainian than German — which is not on offer.
    func testSystemAlwaysResolvesToARealLanguage() {
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
        XCTAssertTrue([.uk, .en].contains(AppLanguage.system.resolved))
        XCTAssertEqual(AppLanguage.uk.resolved, .uk)
        XCTAssertEqual(AppLanguage.en.resolved, .en)
    }

    /// A locale that still said `system` would make every date and amount
    /// nonsense, and `Locale(identifier: "system")` is a valid `Locale`
    /// rather than an error — so this fails late and looks like a formatter
    /// bug.
    func testTheLocaleNamesARealLanguage() {
        XCTAssertEqual(AppLanguage.uk.locale.identifier, "uk")
        XCTAssertEqual(AppLanguage.en.locale.identifier, "en")
        XCTAssertNotEqual(AppLanguage.system.locale.identifier, "system")
    }

    /// Each language's name is written IN that language. A person who has put
    /// the app into a language they cannot read has to find their own in the
    /// picker, and «Англійська» is no help to them.
    func testTheLanguageNamesAreWrittenInTheirOwnLanguage() {
        XCTAssertEqual(AppLanguage.uk.endonym, "Українська")
        XCTAssertEqual(AppLanguage.en.endonym, "English")
        XCTAssertNil(AppLanguage.system.endonym,
                     "«Як у системі» is ordinary copy and is localised by the view")
    }

    // MARK: - Formatting follows the language (the owner's decision)

    /// "1,240.50 ₴" against «1 240,50 ₴». Spelt out rather than taken from
    /// `Locale`, because a locale's grouping separator is a narrow no-break
    /// space on some systems and an ordinary one on others — a difference
    /// invisible until a test compares strings.
    func testAmountsFollowTheInterfaceLanguage() {
        L10n.setFormatting(.en)
        XCTAssertEqual(124_050.uahExact, "1,240.50 ₴")
        XCTAssertEqual(124_050.uah, "1,241 ₴")

        L10n.setFormatting(.uk)
        XCTAssertEqual(124_050.uahExact, "1 240,50 ₴")
        XCTAssertEqual(124_050.uah, "1 241 ₴")
    }

    /// The same decision on dates: "August 2026" against «серпень 2026».
    func testDatesFollowTheInterfaceLanguage() {
        let august = MonthKey(year: 2026, month: 8)

        L10n.setFormatting(.en)
        XCTAssertEqual(august.title, "August 2026")

        L10n.setFormatting(.uk)
        XCTAssertEqual(august.title, "серпень 2026")
    }

    /// **The calendar does not follow the language.** It does arithmetic —
    /// month boundaries, day starts — and those answers must be identical
    /// whichever language the app is in, or a person switching to English
    /// would see their August spending change.
    func testTheCalendarsAnswersDoNotFollowTheLanguage() {
        let date = Date(timeIntervalSince1970: 1_756_000_000)

        L10n.setFormatting(.en)
        let englishMonth = MonthKey(date)
        let englishStart = Calendar.kyiv.startOfDay(for: date)

        L10n.setFormatting(.uk)
        XCTAssertEqual(MonthKey(date), englishMonth)
        XCTAssertEqual(Calendar.kyiv.startOfDay(for: date), englishStart)

        // The calendar's own locale, pinned directly. The two assertions above
        // pass whatever it is set to — `startOfDay` and the month components
        // do not read it — so pointing `Calendar.kyiv.locale` at the interface
        // language survived them both. What it DOES decide is `firstWeekday`
        // and `minimumDaysInFirstWeek`, which nothing reads today; the moment
        // anything does, a person switching to English would see their week
        // start on a different day. Pin the line, not only today's symptoms.
        XCTAssertEqual(Calendar.kyiv.locale?.identifier, "uk_UA")
        XCTAssertEqual(Calendar.kyiv.firstWeekday, 2, "Monday, whatever the interface says")
    }

    /// Category ordering stays Ukrainian too, and for the same reason: what it
    /// sorts is Ukrainian. Collating «Інтернет» with an English locale puts it
    /// back where board #25 found it.
    func testCategoryOrderingStaysUkrainianInEnglish() {
        let names = ["Інтернет", "Їжа поза домом", "Авто", "Ювелірні"]

        L10n.setFormatting(.en)
        let inEnglish = MonitorFinance.Category.alphabetical(names)
        L10n.setFormatting(.uk)
        XCTAssertEqual(inEnglish, MonitorFinance.Category.alphabetical(names))
        XCTAssertEqual(inEnglish.first, "Авто")
    }

    // MARK: - Board #96: copy that reached an English reader in Ukrainian

    /// The queue's toolbar counter. `progressText` is shown through `Text(…)`,
    /// which takes the verbatim overload for a `String`, so «з» could only ever
    /// become "of" by being translated here.
    func testTheQueueCounterCountsInTheChosenLanguage() {
        XCTAssertEqual(QueueView.progressText(start: 27, remaining: 20, .uk), "7 з 27")
        XCTAssertEqual(QueueView.progressText(start: 27, remaining: 20, .en), "7 of 27")
    }

    /// The notification body, which arrived in Ukrainian under a title that
    /// translated correctly — `content.title` went through `L10n.t` and the
    /// `content.body` beside it did not. There is no view here, so nothing in
    /// SwiftUI could have resolved it.
    func testTheNewPurchaseNotificationTranslatesItsBodyAndNotOnlyItsTitle() {
        XCTAssertEqual(Notifications.newPurchasesTitle(1, .en), "New purchase")
        XCTAssertEqual(Notifications.newPurchaseBody(merchant: "Крамниця-Приклад", amount: "₴240", .en),
                       "Крамниця-Приклад · ₴240 — what was this?")
        XCTAssertEqual(Notifications.newPurchaseBody(merchant: "Крамниця-Приклад", amount: "₴240", .uk),
                       "Крамниця-Приклад · ₴240 — що це?")
    }

    /// Keys whose English text sits in the catalogue but was never read,
    /// because the copy was assembled into a `String` before it reached a view.
    /// Asserted against the catalogue directly: a missing entry here is the
    /// failure that renders as correct-looking Ukrainian.
    func testTheKeysThatWereBuiltIntoStringsAllHaveEnglish() {
        for key in ["План за %@", "%lld з %lld", "%@ — переказ між своїми",
                    "%@ перейдуть до «Інше».", "Разом %@ — розберемо?",
                    "%@ · %@ — що це?", "Перші %lld карток — це %@ ваших витрат."] {
            XCTAssertNotEqual(L10n.t(key, .en), key,
                              "«\(key)» has no English entry, so it renders as itself")
        }
    }

    /// The fallback inside `BudgetView`'s new-month card. It is substituted
    /// INTO the key rather than being part of it, so it is a plain `String`
    /// that the catalogue never sees unless it is translated at the source.
    func testTheMonthFallbackInsideAnInterpolationTranslates() {
        XCTAssertEqual(L10n.t("попередній місяць", .en), "previous month")
        XCTAssertEqual(L10n.t("попередній місяць", .uk), "попередній місяць")
    }

    // MARK: - Plurals

    /// English takes the singular for exactly 1 — **not for 0, and not for
    /// 21**, which is where a rule written from Ukrainian habits goes wrong.
    func testEnglishTakesTheSingularOnlyForExactlyOne() {
        XCTAssertEqual(Plural.purchases(0, .en), "0 purchases")
        XCTAssertEqual(Plural.purchases(1, .en), "1 purchase")
        XCTAssertEqual(Plural.purchases(2, .en), "2 purchases")
        XCTAssertEqual(Plural.purchases(21, .en), "21 purchases")
        XCTAssertEqual(Plural.purchases(111, .en), "111 purchases")
    }

    /// The Ukrainian rule is unchanged by any of this — 11–14 take the "many"
    /// form despite ending in 1–4, and 21 takes the singular. Both languages
    /// asserted side by side because the shared helper is where one could
    /// quietly start answering for the other.
    func testUkrainianKeepsItsThreeFormsBesideEnglishsTwo() {
        XCTAssertEqual(Plural.purchases(1, .uk), "1 покупка")
        XCTAssertEqual(Plural.purchases(11, .uk), "11 покупок")
        XCTAssertEqual(Plural.purchases(21, .uk), "21 покупка")
        XCTAssertEqual(Plural.purchases(21, .en), "21 purchases")
    }

    /// `.system` reaches the plural helpers directly from settings, so it must
    /// pick a rule rather than fall through to neither.
    func testPluralsResolveTheSystemCase() {
        let system = Plural.purchases(2, .system)
        XCTAssertTrue(["2 покупки", "2 purchases"].contains(system), system)
    }

    // MARK: - Persistence

    /// A language written by a future version — or by a corrupt file — must
    /// not throw. Every persisted field here is Optional and every load is
    /// `try?` with a whole-file fallback, so a thrown `dataCorrupted` does not
    /// lose one setting: it loses the settings file.
    func testAnUnknownStoredLanguageDecodesAsSystem() throws {
        struct Wrapper: Codable { var language: AppLanguage? }
        let decoded = try JSONDecoder().decode(
            Wrapper.self, from: Data(#"{"language":"de"}"#.utf8))
        XCTAssertEqual(decoded.language, .system)
    }

    /// Settings written before this feature existed carry no `language` key at
    /// all, and must load — as «як у системі» — rather than throw and take the
    /// whole settings file down with them. The payload is a real pre-#85 one:
    /// only the two fields that have never been Optional.
    func testSettingsWrittenBeforeThisFeatureStillDecode() throws {
        let legacy = #"{"onboarded":true,"faceIdEnabled":false}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertNil(settings.language)
        XCTAssertEqual(settings.languageChoice, .system)
    }
}
