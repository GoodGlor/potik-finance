import SwiftUI

/// Every settings/banks screen lives on Home's own NavigationStack — pushed,
/// not sheeted. Settings screens are a hierarchy, not a modal interruption, so
/// they share Home's stack rather than opening on their own. Sheets are safe
/// here — the lock is its own window as of `3590f46` and outranks every
/// presentation — and this stage already uses them elsewhere: the filter
/// sheet and the category picker.
enum SettingsRoute: Hashable {
    case settings
    case security
    case changePin
    case banks
    case bankDetail(String)
    case addBankPicker
    case addBankToken(String)
    /// «Які картки синхронізувати?», board #22. Adding a bank from Settings
    /// used to go token → «Підключено» and skip this, so a second card was
    /// synced without anybody being asked — while onboarding, which is the
    /// same connection, always asks. Depth is deliberately NOT here: it is one
    /// setting for the whole app and lives in Налаштування → Дані.
    case addBankCards(String)
    case addBankConnected(String)
    /// «Звідки брати покупки?» — board #91. PrivatBank's picker row lands here
    /// rather than straight on the import, because it now has two sources.
    case privatSource
    /// The registration-and-waiting screen for the notification letters.
    case emailSetup
    case importStatement
    case importSummary(ImportSummary)
    case categories
    /// «Правила», pushed from `CategoriesSettingsView` (board #11). Under
    /// Категорії rather than beside it: a rule is an answer about a category,
    /// and the settings root is a list of five things that should stay five.
    case rules
    case data
    /// «Глибина історії», pushed from `DataSettingsView`. The only route to
    /// `SyncDepthView` after onboarding — without it the single way to change
    /// depth was «Скинути додаток», which deletes the PIN, the token and every
    /// categorisation the user has ever made.
    case syncDepth
    case about
}

struct SettingsView: View {
    @Binding var path: [SettingsRoute]
    /// Board #68: only to know whether «Дані» needs a warning on it. A card
    /// buried one screen down is not "noticed by somebody" — a person whose
    /// history went quiet has no reason to go looking in Налаштування, so the
    /// warning has to be visible from the level above the explanation.
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    Button { path.append(.security) } label: {
                        row("lock", "Безпека", "Код входу, Face ID")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.security")
                    Divider().overlay(Theme.hair)
                    Button { path.append(.banks) } label: {
                        row("building.columns", "Банки", "Підключені картки")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.banks")
                    Divider().overlay(Theme.hair)
                    Button { path.append(.categories) } label: {
                        row("tag", "Категорії", "Перейменувати, об'єднати, видалити")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.open.categories")
                    Divider().overlay(Theme.hair)
                    Button { path.append(.data) } label: {
                        row("square.and.arrow.up", "Дані",
                            store.loadFailures.isEmpty
                                ? "Експорт і скидання"
                                : "Не вдалося прочитати частину даних",
                            warning: !store.loadFailures.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.open.data")
                    Divider().overlay(Theme.hair)
                    Button { path.append(.about) } label: {
                        row("info.circle", "Про додаток", "Версія та що вже готово")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.open.about")
                }
                appearanceCard
                languageCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Налаштування")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Board #58. A card rather than a sixth row, and deliberately: the
    /// settings root is a list of five things that should stay five (see
    /// `SettingsRoute.rules`), and appearance is a one-tap choice with nothing
    /// on the far side of a push — a screen holding three radio buttons would
    /// be a navigation for its own sake.
    ///
    /// Below the five, not above: it is the least consequential thing here and
    /// putting it first would say otherwise.
    private var appearanceCard: some View {
        Card {
            Text("Вигляд").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            // `.segmented`, because all three options fit and the choice is
            // worth showing rather than hiding behind a menu that shows only
            // the current one — a person who has never noticed the app can be
            // dark will not open a menu to find out.
            Picker("Вигляд", selection: Binding(
                get: { store.settings.appearanceChoice },
                set: { store.setAppearance($0) })) {
                    ForEach(Appearance.allCases, id: \.self) { choice in
                        Text(LocalizedStringKey(choice.title)).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
            Text("«Як у системі» — світла чи темна разом із рештою телефона.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
        }
    }

    /// The same shape as `appearanceCard` above, for the same reasons — three
    /// options that all fit, nothing on the far side of a push.
    ///
    /// **The two language names are NOT translated.** «Українська» and
    /// "English" are each written in their own language, because a person who
    /// has somehow put the app into a language they cannot read has to find
    /// their own in this list — and «Англійська» is no help to them. Only «Як
    /// у системі» is ordinary copy, and it is the one row that follows the
    /// current choice.
    private var languageCard: some View {
        Card {
            Text("Мова").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Picker("Мова", selection: Binding(
                get: { store.settings.languageChoice },
                set: { store.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        if let endonym = choice.endonym {
                            Text(verbatim: endonym).tag(choice)
                        } else {
                            Text("Як у системі").tag(choice)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.language")
            Text("Назви категорій — ваші власні дані й не перекладаються.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
        }
    }

    /// `warning` recolours the icon and the note rather than adding a dot: the
    /// note is where the reason fits, and a bare badge would say only that
    /// something is wrong on a screen with five rows to check.
    private func row(_ icon: String, _ title: LocalizedStringKey, _ note: LocalizedStringKey,
                     warning: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: warning ? "exclamationmark.triangle" : icon)
                .font(.system(size: 20))
                .foregroundStyle(warning ? Theme.clay : Theme.green).frame(width: 28)
                // A red triangle is the whole signal to somebody LOOKING at
                // this row, and it says nothing whatever to a screen reader —
                // the merged Button label would read «Дані, Не вдалося
                // прочитати частину даних» with no hint that it is a warning.
                // Named when it is one, decoration when it is not.
                //
                // It is also what makes the tint assertable: two mutations
                // that broke the colour while leaving the note alone survived
                // the UI tests, because the label a test can read carried the
                // text and not the colour.
                .accessibilityLabel(warning ? "Помилка" : "")
                .accessibilityHidden(!warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                Text(note).font(Theme.font(14))
                    .foregroundStyle(warning ? Theme.clay : Theme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
