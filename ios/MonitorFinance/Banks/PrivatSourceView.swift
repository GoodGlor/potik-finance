import SwiftUI

/// «Звідки брати покупки?» — board #91's two-way choice.
///
/// The two sources are not alternatives and the screen must not read as if
/// they were: a letter arrives within a minute of a purchase and carries
/// nothing older, a statement carries the history and then stops. Most people
/// end up with both, which is why this keeps offering the second one after the
/// first is connected rather than disappearing once something is set up.
///
/// It is a destination, not a confirmation. Board #19's rule — the row's tap IS
/// the choice — still holds: the picker row goes somewhere, this is where it
/// goes, and every row here has a back edge and connects nothing by being
/// arrived at.
struct PrivatSourceView: View {
    @Environment(AppStore.self) private var store
    var onEmail: () -> Void
    var onStatement: () -> Void

    /// The email row reports its own state, which is what lets one row keep one
    /// destination on every visit — no branching on state the person cannot
    /// see, and nothing for a returning person to guess at.
    private var emailNote: LocalizedStringKey {
        if store.syncState.emailNeedsReconnect { return "потрібно підключити заново" }
        if store.privatEmailCredentials != nil { return "підключено" }
        return "Приват24 надсилає лист про кожну покупку"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Звідки брати покупки?")
                        .font(Theme.font(26, .bold)).foregroundStyle(Theme.ink)
                    Text("Можна і те, і те: листи показують нові покупки одразу, виписка приносить історію.")
                        .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                }
                .padding(.horizontal, 6)
                Card {
                    row("envelope", "Отримувати листи", emailNote,
                        identifier: "privat.source.email", action: onEmail)
                    Divider().overlay(Theme.hair)
                    row("doc.text", "Імпортувати виписку", "файл .xlsx з Приват24",
                        identifier: "privat.source.statement", action: onStatement)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
        .background(Theme.bg)
        .navigationTitle("ПриватБанк")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, _ note: LocalizedStringKey,
                     identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20))
                    .foregroundStyle(Theme.green).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    Text(note).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
