import SwiftUI

struct ConnectedView: View {
    @Environment(AppStore.self) private var store
    let bankId: String
    var buttonTitle: LocalizedStringKey
    var onContinue: () -> Void

    private var bank: Bank? { store.banks.first { $0.id == bankId } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 40, weight: .light)).foregroundStyle(Theme.green)
                        Text("\(bank?.displayName ?? bankId) підключено")
                            .font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
                        Text("Виписка оновлюватиметься сама. Токен лежить лише на цьому телефоні.")
                            .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    }
                    if let accounts = bank?.accounts, !accounts.isEmpty {
                        Card {
                            Text("Картки").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                            ForEach(accounts) { a in
                                HStack {
                                    // Same convention as `BankDetailView`: the
                                    // identifier is NOT built from the card
                                    // suffix — a real one is the owner's own,
                                    // and a test only needs to know accounts
                                    // render at all.
                                    Text(a.suffix).font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                                        .accessibilityIdentifier("bank.account")
                                    Text(a.type).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                                    Spacer()
                                    Text(a.balance.uah).font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                                }
                                .frame(minHeight: 40)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            PrimaryButton(title: buttonTitle, action: onContinue)
                .accessibilityIdentifier("bank.connected.start")
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden()
    }
}
