import SwiftUI

/// Every observation `Derived.tips` can currently support, not just the first
/// one shown on Home. A ledger with nothing to say shows an empty scroll
/// view rather than crashing or inventing something — Home's own guard
/// already keeps a user from reaching this screen with zero tips in hand.
struct TipsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(Derived.tips(store.transactions, store.settings.languageChoice)) { tip in
                    Card {
                        Text(LocalizedStringKey(tip.title)).font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                        Text(LocalizedStringKey(tip.body)).font(Theme.font(18, .semibold)).foregroundStyle(Theme.ink)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .accessibilityIdentifier("tips.list")
        .navigationTitle("Спостереження")
    }
}
