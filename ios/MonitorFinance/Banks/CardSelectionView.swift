import SwiftUI

/// «Які картки синхронізувати?» — straight after the token verifies. All
/// on by default; at least one required. Editable later from the bank's
/// detail screen.
struct CardSelectionView: View {
    @Environment(AppStore.self) private var store
    let bankId: String
    var onDone: () -> Void
    @State private var enabled: Set<String> = []
    @State private var seeded = false

    private var accounts: [Account] { store.banks.first { $0.id == bankId }?.accounts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Які картки синхронізувати?")
                            .font(Theme.font(26, .bold)).foregroundStyle(Theme.ink)
                        Text("Вимкнені картки не завантажуються. Змінити вибір можна в налаштуваннях банку.")
                            .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    }
                    .padding(.horizontal, 6)

                    Card {
                        if accounts.isEmpty {
                            Text("Немає гривневих карток для синхронізації — застосунок продовжить без вибору карток.")
                                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                        }
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { i, account in
                            row(account)
                            if i < accounts.count - 1 { Divider().overlay(Theme.hair) }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }

            PrimaryButton(title: "Далі") {
                for account in accounts {
                    store.setSyncEnabled(bankId: bankId, accountId: account.id,
                                         enabled.contains(account.id))
                }
                onDone()
            }
            // Requiring a selection only makes sense when there is something
            // to select. `accounts` is empty only if a client somehow has no
            // UAH accounts at all — but this screen has no back button, so
            // trapping that person behind a permanently-disabled button
            // would strand onboarding rather than just doing nothing to sync.
            .disabled(enabled.isEmpty && !accounts.isEmpty)
            .opacity(enabled.isEmpty && !accounts.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("cards.next")
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden()
        .onAppear {
            guard !seeded else { return }
            seeded = true
            enabled = Set(accounts.filter { $0.syncEnabled != false }.map(\.id))
        }
    }

    private func row(_ account: Account) -> some View {
        Button {
            if enabled.contains(account.id) { enabled.remove(account.id) }
            else { enabled.insert(account.id) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.suffix).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    Text(account.type).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Text(account.balance.uah).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                Image(systemName: enabled.contains(account.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(enabled.contains(account.id) ? Theme.green : Theme.hair)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the BUTTON, not the leaf `Text`: SwiftUI merges a Button's
        // label into one accessibility element, so an identifier on a child
        // inside it is never exposed at runtime. Same convention as
        // `CategoryPicker`'s row buttons — and, same as `bank.account`'s
        // no-suffix convention, this identifier never carries the owner's
        // card suffix either way.
        .accessibilityIdentifier("cards.row")
    }
}
