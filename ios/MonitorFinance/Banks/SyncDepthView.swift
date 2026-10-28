import SwiftUI

/// «Наскільки глибоко завантажити історію?» — shown once, straight after a
/// token verifies, and reachable later from Налаштування → Дані.
struct SyncDepthView: View {
    @Environment(AppStore.self) private var store
    var onChosen: () -> Void

    private static let choices: [(months: Int, title: String)] = [
        (1, "1 місяць"), (3, "3 місяці"), (6, "6 місяців"),
        (12, "12 місяців"), (0, "Усе, що є"),
    ]

    private var accounts: Int { store.syncAccounts.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Скільки історії завантажити?")
                    .font(Theme.font(20, .bold)).foregroundStyle(Theme.ink)
                Text("monobank віддає один місяць на запит і дозволяє один запит на хвилину. Перший місяць з'явиться одразу, решта — у фоні.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)

                ForEach(Self.choices, id: \.months) { choice in
                    Card {
                        Button {
                            store.setSyncDepth(choice.months)
                            onChosen()
                        } label: {
                            HStack(spacing: 8) {
                                Text(LocalizedStringKey(choice.title)).font(Theme.font(17, .semibold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(Self.estimate(choice.months, accounts, store.settings.languageChoice))
                                    .font(Theme.font(14)).foregroundStyle(Theme.inkSoft)
                                // Reachable from Налаштування → Дані now, not
                                // only from onboarding — and a settings screen
                                // that does not say what is currently set is a
                                // guess. During onboarding this marks the
                                // default the user gets if they change nothing,
                                // which is equally true.
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.green)
                                    .opacity(choice.months == store.syncState.depthMonths ? 1 : 0)
                            }
                            // Without this, a tap landing in the Spacer's gap
                            // — which is exactly where the middle of the row
                            // sits — never reaches the button at all. Same
                            // fix `BankPickerView`'s row already carries.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("depth.\(choice.months)")
                        // The checkmark above is drawn at `.opacity(0)` when
                        // unselected, which XCUITest cannot tell from visible
                        // — and SwiftUI folds a Button's label into one
                        // element anyway, so an identifier on the image would
                        // not be queryable. The value sits on the button
                        // itself, where both VoiceOver and a test can read it.
                        .accessibilityValue(choice.months == store.syncState.depthMonths
                                            ? "обрано" : "")
                    }
                }
            }
            .padding(18)
        }
        .background(Theme.bg)
    }

    /// Honest, and derived from what the engine will actually do rather than
    /// from a number written here.
    static func estimate(_ months: Int, _ accounts: Int, _ language: AppLanguage) -> String {
        guard months > 0 else { return "поки не закінчиться" }
        let seconds = SyncPlan.estimate(depthMonths: months, accounts: accounts)
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 0 ? "майже одразу" : "≈ \(Plural.minutes(minutes, language))"
    }
}
