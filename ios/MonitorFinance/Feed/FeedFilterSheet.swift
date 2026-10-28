import SwiftUI

struct FeedFilterSheet: View {
    @Binding var filter: FeedFilter
    /// Board #110. The month's rows with **no filters applied** — the set the
    /// «Без чека» count is taken over.
    ///
    /// Not what the feed is currently showing: a to-do that moves while you
    /// fiddle with the filters is not a to-do, and once «Без чека» is selected
    /// the filtered count would simply equal the row count and say nothing.
    let monthRows: [Transaction]
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Every bank that actually has rows, ordered by the name shown.
    ///
    /// Read from the TRANSACTIONS rather than from `store.banks`: a bank the
    /// person disconnected leaves its rows behind, and those rows still need a
    /// way to be found. `BankMark.bank` gives such a bank its id as a label,
    /// which is the only thing that names it.
    private var bankIds: [String] {
        Array(Set(store.transactions.map(\.bankId)))
            .sorted { BankMark.bank($0, store.banks) < BankMark.bank($1, store.banks) }
    }

    /// The cards on offer, narrowed to the chosen banks.
    ///
    /// Listing every card regardless would offer a person combinations that
    /// match nothing — «ПриватБанк» AND a monobank card is an empty feed, and
    /// an empty feed does not say which of the two choices emptied it.
    private var cards: [String] {
        let rows = filter.banks.isEmpty
            ? store.transactions
            : store.transactions.filter { filter.banks.contains($0.bankId) }
        return Array(Set(rows.map(\.cardSuffix))).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                // Тип is listed first, above the 39-row Категорії section: a
                // SwiftUI List only materializes on-screen rows, so a UI test
                // (or a user) reaching for "Тип" must not have to scroll past
                // every category first.
                Section("Тип") {
                    ForEach([TxKind.expense, .income, .transfer], id: \.self) { kind in
                        row(LocalizedStringKey(kind.title), selected: filter.kinds.contains(kind),
                            id: "filter.kind.\(kind.rawValue)") { toggle(&filter.kinds, kind) }
                    }
                }
                // Board #110, second — high, for the same reason «Тип» is: the
                // «Без чека» count is the one thing on this sheet a person may
                // open it purely to read, and a `List` past 39 categories is a
                // scroll away.
                Section("Чек") {
                    ForEach(ReceiptPresence.allCases, id: \.self) { presence in
                        receiptRow(presence)
                    }
                }
                // Above Картки because it is the broader cut, and because
                // choosing a bank changes what Картки offers.
                Section("Банки") {
                    ForEach(bankIds, id: \.self) { id in
                        dataRow(BankMark.bank(id, store.banks),
                                selected: filter.banks.contains(id),
                                id: "filter.bank.\(id)") { toggleBank(id) }
                    }
                }
                Section("Картки") {
                    ForEach(cards, id: \.self) { card in
                        dataRow(card, selected: filter.cards.contains(card),
                                id: "filter.card.\(card)") { toggle(&filter.cards, card) }
                    }
                }
                Section("Категорії") {
                    ForEach(Category.alphabetical(store.categories.map(\.name)), id: \.self) { name in
                        dataRow(name, selected: filter.categories.contains(name),
                                id: "filter.category.\(name)") { toggle(&filter.categories, name) }
                    }
                }
            }
            .navigationTitle("Фільтри")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("filter.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скинути") { filter = FeedFilter() }
                        .accessibilityIdentifier("filter.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .accessibilityIdentifier("filter.done")
                }
            }
        }
    }

    /// Copy — «Витрата», «Дохід», «Переказ». `LocalizedStringKey`, because
    /// `Text(someStringVariable)` takes the verbatim overload and would leave
    /// the three type filters Ukrainian on an English phone.
    private func row(_ title: LocalizedStringKey, selected: Bool, id: String,
                     action: @escaping () -> Void) -> some View {
        rowBody(Text(title), selected: selected, id: id, action: action)
    }

    /// A card suffix or a category name — the person's own DATA, never copy.
    /// Category names in particular are the owner's standing decision, pinned
    /// by `test_the_seeded_category_names_are_never_offered_for_translation`.
    private func dataRow(_ name: String, selected: Bool, id: String,
                         action: @escaping () -> Void) -> some View {
        rowBody(Text(verbatim: name), selected: selected, id: id, action: action)
    }

    /// Board #110. A radio row, not a membership row: tapping the selected one
    /// clears it, and tapping the other REPLACES it. Choosing both would select
    /// every row, which is what choosing neither already does.
    ///
    /// The «without» side carries the count, because that is the side a person
    /// can act on — «12 без чеків» is a to-do; «102 з чеком» is trivia.
    private func receiptRow(_ presence: ReceiptPresence) -> some View {
        let selected = filter.receipts == presence
        return Button {
            filter.receipts = selected ? nil : presence
        } label: {
            HStack {
                Text(LocalizedStringKey(presence.title)).foregroundStyle(Theme.ink)
                Spacer()
                if presence == .without, missing > 0 {
                    // `verbatim`: a bare count, and one that must not pick up
                    // the LocalizedStringKey overload's digit grouping — the
                    // trap board #109 found in `.accessibilityValue`.
                    // Muted, not `Theme.clay`. On a simulator the warning
                    // colour read as an alarm about the normal state — 104 of
                    // the seed month's 114 purchases are unscanned, and that is
                    // simply what a person who does not scan receipts looks
                    // like. A permanent red number is nagging about something
                    // no single tap can fix. Semibold and right-aligned is
                    // enough to find.
                    Text(verbatim: String(missing))
                        .font(Theme.font(15, .semibold)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("filter.receipt.missingCount")
                }
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("filter.receipt.\(presence.rawValue)")
    }

    private var missing: Int { Derived.withoutReceipt(monthRows) }

    private func rowBody(_ title: Text, selected: Bool, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                title.foregroundStyle(Theme.ink)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }

    /// Membership toggle: tapping a selected term removes it, so the sheet is
    /// its own undo and nothing needs a separate "deselect" affordance.
    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    /// **A bank cannot leave a card selected behind it.**
    ///
    /// Pick monobank's card, then pick ПриватБанк: the two constraints are
    /// ANDed, so the feed goes empty — and an empty feed does not say which of
    /// the two choices emptied it, or that the card doing it is no longer on
    /// screen to un-tick. Dropping the cards the new bank set does not offer
    /// keeps the sheet's state and its list saying the same thing.
    private func toggleBank(_ id: String) {
        toggle(&filter.banks, id)
        let offered = Set(cards)          // computed from the NEW bank set
        filter.cards.formIntersection(offered)
    }
}
