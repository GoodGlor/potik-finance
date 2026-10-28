import SwiftUI

/// Every rule the app has learned, and the one thing that could never be done
/// to one: forgotten.
///
/// Board #11. The app teaches itself a rule from a single tap in the queue —
/// «цей продавець → Продукти» — and from then on every row from that shop is
/// decided as it arrives, never enters the queue, and is never mentioned
/// again. (No shop is named in this comment on purpose: every merchant this
/// screen will actually list comes off the owner's own statement, and the
/// privacy guard rightly refuses one in source.) That is the
/// trade the queue is built on and it is a good one, right up until the rule is
/// wrong. Then it is a wrong answer applied silently, forever, to a merchant
/// the person may not even remember confirming; the only retraction was the
/// «Скасувати» on a toast that lives about five seconds.
/// `markNotAnExpense`'s own doc comment says the quiet part out loud — "there
/// is no rule-editing UI anywhere to see it or repair it". This is that UI.
struct RulesSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var forgetting: Rule?

    /// Every rule's display name and row count, resolved in one pass — see
    /// `RuleText.summarise`, which explains why this is not a helper called per
    /// row.
    ///
    /// The count is how many rows this MERCHANT has, and nothing more.
    /// Deliberately NOT "rows this rule settled": `resolution == .rule` is
    /// carried by 670 of the demo's rows, almost none of which any seeded rule
    /// decided, so a provenance claim here would be confidently wrong. How much
    /// of a person's history a merchant accounts for is what makes forgetting
    /// its rule feel consequential or trivial, and it is a number this screen
    /// can stand behind. The word «операцій» is spelled out rather than left as
    /// a bare figure in a column — the unlabelled count on the categories
    /// screen next door is its own open card (#25).
    private var summaries: [String: RuleText.Summary] {
        RuleText.summarise(store.rules.map(\.merchantKey), in: store.transactions)
    }

    /// By the name a person would look for, not by the key that is stored.
    /// `Category.alphabetical` is named for the list it was written for and is
    /// really the app's one Ukrainian collation — reusing it here is what keeps
    /// this screen from opening at І the way every list did before board #15.
    private func sorted(_ facts: [String: RuleText.Summary]) -> [Rule] {
        let byName = Dictionary(grouping: store.rules) { facts[$0.merchantKey]?.name ?? $0.merchantKey }
        return Category.alphabetical(Array(byName.keys)).flatMap { byName[$0] ?? [] }
    }

    var body: some View {
        let facts = summaries
        return List {
            if store.rules.isEmpty {
                empty
            } else {
                Section {
                    ForEach(sorted(facts)) { rule in
                        row(rule, facts[rule.merchantKey] ?? RuleText.Summary(name: rule.merchantKey, count: 0),
                            // Board #81: the kind is worth saying only where a
                            // merchant holds more than one rule. Computed here
                            // rather than in `row` because it is a fact about
                            // the LIST, not about the rule.
                            shareTheMerchant: store.rules.filter { $0.merchantKey == rule.merchantKey }.count > 1)
                    }
                } footer: { footer }
            }
        }
        .navigationTitle("Правила")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.rules")
        .confirmationDialog("Забути правило?",
                            isPresented: Binding(get: { forgetting != nil },
                                                 set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Забути", role: .destructive) {
                if let rule = forgetting { store.deleteRule(rule) }
                forgetting = nil
            }
            .accessibilityIdentifier("settings.rules.forgetConfirm")
            Button("Скасувати", role: .cancel) { forgetting = nil }
        } message: {
            // Both halves, because the surprising one is the first: nothing a
            // person has already sorted moves. Saying only "we will ask again"
            // would leave them wondering what happened to the history.
            Text("Уже розібрані операції залишаться як є. Наступні покупки цього продавця знову спитаємо.")
        }
    }

    private func row(_ rule: Rule, _ facts: RuleText.Summary,
                     shareTheMerchant: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(facts.name).font(Theme.font(17, .medium)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                Text(LocalizedStringKey(RuleText.answer(rule))).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                // Board #81. Two rules for one merchant are two rows under the
                // same name; without this the screen shows the merchant
                // answering «Зарплата» and «Послуги» at once and explains
                // neither. Suppressed when the merchant has only one rule, so
                // no existing row gains a qualifier that answers nothing.
                if shareTheMerchant, let note = RuleText.scopeNote(rule) {
                    Text(LocalizedStringKey(note))
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("settings.rules.scope.\(rule.id)")
                }
            }
            if RuleText.isInert(rule) {
                // A rule `applyingRule` refuses on sight. Two of the five the
                // demo ships are like this, and without a line saying so the
                // screen would present them as working.
                Text("Не діє: про такі операції питаємо щоразу")
                    .font(Theme.font(13)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("settings.rules.inert.\(rule.id)")
            }
            Text(Plural.operations(facts.count, store.settings.languageChoice))
                .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, 2)
        // `.contain` FIRST, then the name — the `detail.receipt` pattern. A
        // bare identifier on this `VStack` is stamped onto every `Text` inside
        // it instead of naming the row: the tree then held four or five
        // elements per rule all answering to `settings.rules.row.<key>`, so a
        // count of rows counted texts, and «Не діє…» lost its own identifier
        // under the parent's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.rules.row.\(rule.id)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { forgetting = rule } label: { Text("Забути") }
                .accessibilityIdentifier("settings.rules.forget.\(rule.id)")
        }
    }

    private var footer: some View {
        Text("Правило з'являється, коли ви розбираєте покупку в Черзі. Далі такі покупки розбираються самі.")
            .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
    }

    /// A real new user arrives here with nothing — rules are earned, and the
    /// screen has to explain what would put something on it rather than read as
    /// broken.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Правил ще немає").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("settings.rules.empty")
            Text("Коли ви розберете покупку в Черзі, додаток запам'ятає продавця і наступні такі покупки розбере сам. Тут можна буде це скасувати.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
        }
        .padding(.vertical, 6)
    }
}
