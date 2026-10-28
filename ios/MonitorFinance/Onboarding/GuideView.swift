import SwiftUI

/// The short guide, board #60.
///
/// **Why it is not part of onboarding.** Board #16 deliberately kept the
/// welcome screen to one sentence: at that point the app has no bank, no rows
/// and nothing to point at, so a tour would be four screens of promises
/// between a person and the app they just installed. This runs on the other
/// side of that — onboarding is done, a bank is connected, the first sync is
/// already fetching — so every screen it names is a screen that now exists and
/// has something on it.
///
/// **Four pages, one idea each.** The app's four verbs: the money arrives by
/// itself, you answer once per shop, you split the income into shares, you
/// scan a receipt for the goods. Anything a person can work out by tapping is
/// left out; a guide long enough to be skipped teaches nothing.
///
/// **The way out is «Закрити», never «Пропустити»** — board #17, which renamed
/// onboarding's exit for the same reason: «Пропустити» tells somebody they are
/// missing something, on the one control whose whole job is to be pressed by
/// people who are fine.
struct GuideView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// nil while it is being read for the first time; `markSeen` is the
    /// caller's business, not this view's, so re-opening it from Налаштування
    /// does not re-stamp anything.
    var onFinish: (() -> Void)?

    @State private var page = 0

    struct Page: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let body: String
    }

    static let pages: [Page] = [
        .init(id: 0, icon: "arrow.down.circle",
              title: "Операції приходять самі",
              body: "Додаток забирає їх із банку — вручну вводити нічого не треба. "
                  + "Виписку з ПриватБанку можна імпортувати файлом."),
        .init(id: 1, icon: "tray.and.arrow.down",
              title: "«Розібрати» — одна відповідь на магазин",
              body: "Ви кажете, до якої категорії належить продавець, — і всі його "
                  + "покупки, минулі й майбутні, розкладаються самі."),
        .init(id: 2, icon: "chart.pie",
              title: "«Бюджет» — частки, а не суми",
              body: "Ви ділите місячний дохід на частки, а додаток показує, де "
                  + "витрати відходять від плану."),
        .init(id: 3, icon: "qrcode.viewfinder",
              title: "Чек показує, що саме куплено",
              body: "Скануйте QR із паперового чека — і в одній покупці видно "
                  + "продукти окремо від решти."),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Закрити") { finish() }
                    .font(Theme.font(16, .medium)).foregroundStyle(Theme.green)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("guide.close")
            }
            .padding(.horizontal, 12)

            TabView(selection: $page) {
                ForEach(Self.pages) { item in
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: item.icon)
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(Theme.green)
                            .accessibilityHidden(true)
                        // `LocalizedStringKey(...)`, not the bare `String`.
                        // The page list is built in code, so both fields
                        // arrive as runtime strings and took `Text`'s verbatim
                        // overload — leaving all four guide pages Ukrainian
                        // while «Next» and «Got it» underneath them were
                        // English. `TipsView` had the title half right and the
                        // body half wrong; both are fixed the same way.
                        Text(LocalizedStringKey(item.title))
                            .font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                        Text(LocalizedStringKey(item.body))
                            .font(Theme.font(17)).foregroundStyle(Theme.inkSoft)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .tag(item.id)
                    .accessibilityIdentifier("guide.page.\(item.id)")
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // «Зрозуміло» on the last page, not «Готово»: nothing was set up
            // here, so «Готово» would claim a task that was never a task.
            PrimaryButton(title: isLast ? "Зрозуміло" : "Далі") {
                if isLast { finish() } else { withAnimation { page += 1 } }
            }
            .accessibilityIdentifier("guide.next")
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guide.title")
    }

    private func finish() {
        onFinish?()
        dismiss()
    }
}
