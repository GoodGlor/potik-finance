import SwiftUI

/// Says plainly which parts of the app are real. The owner is evaluating a
/// half-built product; a screen that implies the bank connection is live would
/// waste their time in the worst possible way.
struct AboutView: View {
    @Environment(AppStore.self) private var store
    @State private var showingGuide = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    Text("Потік").font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
                    Text("Версія \(version)").font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    Text("\(store.transactions.count) операцій за \(Derived.months(store.transactions).count) міс.")
                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                        .accessibilityIdentifier("about.dataset")
                }
                Card {
                    // Board #60's re-open route. Here rather than as a sixth
                    // settings row: «Про додаток» is already the screen that
                    // answers "what is this and what does it do".
                    Button { showingGuide = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "book")
                                .font(.system(size: 20)).foregroundStyle(Theme.green).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Як користуватись")
                                    .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                                Text("Короткий огляд на чотири екрани")
                                    .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("about.guide")
                }
                Card {
                    Text("Що вже справжнє").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    // Board #60 moved three lines up from «Що ще ні». Adding a
                    // guide that explains the budget and the receipt scanner
                    // two taps from a screen calling both unbuilt is a
                    // contradiction the app would be making about itself — and
                    // all three shipped: the token is verified through
                    // `clientInfo` before a bank connects, `BudgetMath` and its
                    // editor are live, and a scanned QR is fetched from the tax
                    // cabinet and split by product group.
                    bullets(["Код входу та Face ID", "Збереження між запусками",
                             "Синхронізація з monobank та імпорт виписки Приват",
                             "Стрічка, пошук і фільтри", "Категорії та правила",
                             "Бюджет за частками доходу", "Фіскальні чеки та їхні товари",
                             "Статистика за живими даними"], Theme.green)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Про додаток")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.about")
        // No `onFinish`: re-reading the guide must not re-stamp when it was
        // first read. `markGuideSeen` guards that too — belt and brace,
        // because the guard is one line away from being "optimised" out.
        .sheet(isPresented: $showingGuide) { GuideView() }
    }

    private func bullets(_ lines: [String], _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(colour).frame(width: 6, height: 6).padding(.top, 7)
                    // `LocalizedStringKey(line)`, not `Text(line)`: these are
                    // copy that happens to arrive as a runtime `String` from
                    // an array, and the verbatim overload left «Що вже
                    // працює» listing eight Ukrainian bullets under an English
                    // heading.
                    Text(LocalizedStringKey(line)).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }
}
