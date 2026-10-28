import SwiftUI

/// Pushed onto Home's shared settings path (see SettingsRoute) — not its own
/// NavigationStack, so re-locking mid add-bank-flow works the same as
/// everywhere else in Settings.
struct BanksSettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: [SettingsRoute]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.connectedBanks.isEmpty {
                    Card {
                        Text("Жодного банку не підключено").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                    }
                } else {
                    Card {
                        ForEach(Array(store.connectedBanks.enumerated()), id: \.element.id) { i, bank in
                            Button { path.append(.bankDetail(bank.id)) } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(bank.displayName).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                                        // Board #91 made a connected bank with
                                        // NO accounts reachable for the first
                                        // time: an email-only PrivatBank has
                                        // letters and no card list, and the
                                        // count line read «0 карток» — true,
                                        // and useless. Name the source it does
                                        // have instead.
                                        if bank.accounts.isEmpty && bank.hasEmailSource {
                                            Text("листи з пошти").font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                                        } else {
                                            Text(Plural.cards(bank.accounts.count, store.settings.languageChoice)).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                                }
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("banks.row.\(bank.id)")
                            if i < store.connectedBanks.count - 1 { Divider().overlay(Theme.hair) }
                        }
                    }
                }
                // Board #166. **The door that locked behind the person.**
                // Disconnecting drops a bank out of `connectedBanks`, and with
                // it the one screen carrying «Відключити разом з операціями» —
                // so the choice about their rows was offered once, at the
                // instant of disconnecting, and never again. Their only route
                // back was «Скинути додаток», which costs the passcode, every
                // token, every rule and every decision they had made.
                //
                // Listed only while it still owns rows: with nothing left to
                // act on there is nothing to open, and the section would
                // otherwise grow forever into a museum of banks somebody once
                // tried.
                if !store.pastBanks.isEmpty { pastBanksCard }
                Button { path.append(.addBankPicker) } label: {
                    Text("Додати банк")
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("banks.add")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Банки")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Board #166. A separate card rather than a second group inside the first
    /// one: these rows lead somewhere that offers a destructive action and no
    /// sync, and a single list would make «підключено» and «відключено» look
    /// like a property of a row rather than the two different things they are.
    ///
    /// The heading says what the section is FOR — these banks are not feeding
    /// anything, and their rows are still here.
    private var pastBanksCard: some View {
        Card {
            Text("Відключені").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Нових операцій не буде, але старі залишились. Відкрийте банк, щоб прибрати їх.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(store.pastBanks.enumerated()), id: \.element.id) { i, bank in
                Button { path.append(.bankDetail(bank.id)) } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bank.displayName).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                            // The count, not the card list: a disconnected bank
                            // has no accounts worth naming, and the number of
                            // rows is the only thing that decides whether
                            // somebody wants this screen at all.
                            Text(Plural.operations(store.bankDisconnectCost(bankId: bank.id).rows,
                                                   store.settings.languageChoice))
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("banks.past.\(bank.id)")
                if i < store.pastBanks.count - 1 { Divider().overlay(Theme.hair) }
            }
        }
    }
}
