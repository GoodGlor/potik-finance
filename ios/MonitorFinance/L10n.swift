import Foundation

/// Where a string that is NOT inside a SwiftUI view gets translated.
///
/// **Most of the app does not need this.** `Text("Готово")`,
/// `.navigationTitle("Категорії")`, `Label(…)` and friends all take a
/// `LocalizedStringKey`, and SwiftUI resolves those against
/// `EnvironmentValues.locale` — which `RootView` sets from the person's
/// choice. Roughly two hundred strings therefore localise with no change at
/// their call site at all. This type is for the other ninety: copy assembled
/// in `Derived`, `Plural`, `AppStore` and the guide's page list, where there
/// is no view and no environment to read.
///
/// ## The keys are the Ukrainian text
///
/// `"Готово"`, not `"common.done"`. Two reasons, and the second is the one
/// that matters. The first is that it made the change tractable: the two
/// hundred view strings above needed no edit precisely because their existing
/// literal already IS the key. The second is the failure mode — **a key with
/// no entry in the catalogue renders as the key itself**, so a string somebody
/// forgets to translate appears in Ukrainian, which is a missing translation.
/// With opaque keys it would appear as `common.done`, which is a bug on
/// screen. The whole catalogue degrades in the safe direction.
///
/// ## `String(localized:locale:)` does not do what it looks like
///
/// Measured, 2026-08-28: `String(localized: "Категорії", locale: uk)` returns
/// **"Categories"** on a device whose preferred language is English. The
/// `locale` argument formats numbers and dates inside the string; it does not
/// choose which localization to read. It is the obvious API, it compiles, it
/// silently returns the wrong language, and nothing on screen says so —
/// `LocalizationTests` pins the real behaviour and a pytest guard keeps the
/// call out of the app.
///
/// Selecting a localization means naming the bundle, which is what this does.
enum L10n {

    /// The `.lproj` for a language, or `Bundle.main` when it cannot be found —
    /// a missing bundle then falls through to the key, which is Ukrainian.
    /// Never a crash and never a raw key on screen.
    ///
    /// Cached: `Bundle(path:)` touches the filesystem, and the feed asks for
    /// plural forms once per visible row.
    private static let bundles: [AppLanguage: Bundle] = {
        var found: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases where language != .system {
            if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                found[language] = bundle
            }
        }
        return found
    }()

    /// **The language every FORMATTER reads, and the one piece of process-wide
    /// state this feature has.**
    ///
    /// Dates and amounts follow the chosen language — the owner's decision —
    /// which means `MonthKey.title`, `FeedView.dayTitle` and `Int.uah` all need
    /// to know it. Those are computed properties and pure statics reached from
    /// forty-one call sites, several of them inside `Derived` and `BudgetMath`,
    /// which are pure functions over `[Transaction]` and have no other reason
    /// to take a language. Threading one through them to build a separator was
    /// the wrong shape; so was giving every screen a formatter of its own.
    ///
    /// So: one value, one writer. `AppStore` sets it at launch and on every
    /// change of the setting; everything else reads. It is `nonisolated(unsafe)`
    /// because a formatter is reached from `Notifications`' async context as
    /// well as from the main actor, and an enum this size cannot tear — but it
    /// is genuinely global state and `LocalizationTests` pins that exactly one
    /// place assigns it.
    /// **The invariant is that this is never `.system`**, and it holds from the
    /// process's first instruction: the initial value resolves, and the only
    /// writer resolves. Before that was true, `Int.separated()`'s bare
    /// `== .en` and `MonthKey.title`'s `.locale` — which resolves — disagreed
    /// for the length of one launch, and an English phone drew "August 2026"
    /// above «1 240,50 ₴». Readers still go through `.resolved` or `.locale`;
    /// a pytest guard keeps a bare comparison out.
    nonisolated(unsafe) private(set) static var formatting: AppLanguage = AppLanguage.system.resolved

    /// Called by `AppStore` and by nothing else.
    static func setFormatting(_ language: AppLanguage) { formatting = language.resolved }

    /// `key` translated into `language`. `.system` resolves first.
    static func t(_ key: String, _ language: AppLanguage) -> String {
        let resolved = language.resolved
        guard let bundle = bundles[resolved] else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

extension AppLanguage {
    /// `.system` turned into a real language, once, here.
    ///
    /// **Ukrainian is the fallback for anything that is not English**, and that
    /// is a decision rather than an accident: this app is written for spending
    /// hryvnia through Ukrainian banks, so a phone set to German is far more
    /// likely to belong to somebody who reads Ukrainian than to somebody who
    /// wants the app in German — which it is not available in anyway.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "uk"
        return preferred.hasPrefix("en") ? .en : .uk
    }

    /// What `RootView` hands to `EnvironmentValues.locale`. It drives both the
    /// string lookup SwiftUI does for every `Text` and the formatting of every
    /// date and amount — which is the owner's decision recorded: in English the
    /// app reads "21 August" and "1,240.50 ₴".
    var locale: Locale { Locale(identifier: resolved.rawValue) }

    /// The name of a language, written IN that language — «Українська»,
    /// "English", never «Англійська».
    ///
    /// A person who has somehow put the app into a language they cannot read
    /// has to find their own language in that list, and a translated list is
    /// no help to them. `nil` for `.system`, whose row is ordinary copy and is
    /// localised the ordinary way by the view that draws it.
    var endonym: String? {
        switch self {
        case .system: nil
        case .uk: "Українська"
        case .en: "English"
        }
    }
}
