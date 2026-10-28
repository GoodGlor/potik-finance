import SwiftUI

/// A picker answer. Deliberately not a `String`: «Переказ між своїми картками»
/// is not a category, and a reserved string in the same field as real category
/// names is the bug this enum exists to prevent.
enum CategoryChoice: Hashable {
    case category(String)
    /// Money moved between the owner's own accounts. The case is still named
    /// for what it does to the row — it becomes `.transfer` and leaves every
    /// spending figure — but board #6 narrowed what may be answered with it to
    /// own-account transfers alone. Cash is «Готівка», a jar is «Заощадження»,
    /// and a payment to another person is whatever it bought; each of those is
    /// a real category, because each is really money leaving.
    case notAnExpense
}

/// What the picker was opened for.
///
/// This used to be a lone `allowsNotAnExpense: Bool`, which left the picker
/// unable to tell a salary from a purchase — so the full spending list was
/// offered for both. A salary took «Продукти» in one tap, the app learned it
/// as a rule and cascaded it, and from then on Головна (which counts income by
/// the sign of the amount) and Бюджет (which counts it by category) reported
/// different incomes with no error anywhere. One enum instead of a flag,
/// because the illegal combination — an own-transfer answer offered for income
/// — is then not expressible.
enum CategoryPurpose: Hashable {
    /// A spending row: every category, plus «Переказ між своїми картками».
    case expense
    /// An income row: only the handful of things money coming in can be,
    /// plus an explicit way to say "a shop gave this back".
    case income
    /// A budget plan line. A line names a category; it cannot be "not an
    /// expense", and it is never income.
    case planLine
}

/// The one category picker. Presented as a sheet everywhere — safe, because
/// the lock is a separate window above every presentation.
struct CategoryPicker: View {
    var selected: String?
    /// Set by the caller from what is being categorised. No default: a new
    /// call site has to say which of the three it is.
    var purpose: CategoryPurpose
    var onPick: (CategoryChoice) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The refund list, pushed on top of the income list. A push rather than
    /// a second sheet so `dismiss` still means "close the picker" — one tap
    /// on a category there both answers and closes, exactly as it does here.
    @State private var refunding = false
    /// Its own query, not the income list's: the two lists are different
    /// lengths and a search typed for one must not survive into the other.
    @State private var refundQuery = ""

    /// The income vocabulary is the same list `BudgetMath` computes the income
    /// base from, so the two can never disagree about what income is.
    ///
    /// Board #94: it used to be a hardcoded, fixed list that deliberately
    /// could not be "extended by whatever the user has created" — because a
    /// category they created could not have been income. Now one can be, and
    /// `incomeCategories(_:)` keeps the seeded names in their canonical order
    /// with anything added after them.
    private var all: [String] {
        purpose == .income ? BudgetMath.incomeCategories(store.categories) : everyCategory
    }

    private var everyCategory: [String] { Category.alphabetical(store.categories.map(\.name)) }

    /// What «Популярні» offers before this person has picked anything.
    ///
    /// A fixed list, not a computed one: the whole point is the moment when
    /// there is nothing to compute from. `recentCategories` takes over on the
    /// first tap and this is never seen again, so it does not need to be right
    /// for everybody — only ordinary enough that a first purchase usually lands
    /// in one tap instead of a scroll through nineteen.
    ///
    /// Filtered against what the store actually holds, so a person who has
    /// deleted or renamed one is not offered a category that no longer exists.
    private var popular: [String] {
        let known = Set(store.categories.map(\.name))
        return Self.popularCategories.filter(known.contains)
    }

    private var matches: [String] { Self.matching(query, in: all) }

    /// See `offeredCreation`, which owns the rules and is testable.
    private var creatable: String? {
        Self.offeredCreation(for: query, in: all, purpose: purpose)
    }

    var body: some View {
        NavigationStack {
            searchableList
                .navigationTitle(purpose == .income ? "Надходження" : "Категорія")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("picker.list")
                .navigationDestination(isPresented: $refunding) { refundList }
                .toolbar {
                    Button("Скасувати") { dismiss() }.accessibilityIdentifier("picker.cancel")
                }
        }
    }

    /// Four rows need no search field. The branch is here rather than inline
    /// because `.searchable` cannot be applied conditionally to one view.
    @ViewBuilder private var searchableList: some View {
        if purpose == .income {
            list
        } else {
            list.searchable(text: $query, prompt: "Пошук категорії")
        }
    }

    private var list: some View {
        List {
            // No `Divider()` after the row: as a direct child of a `List` it is
            // a ROW, not a rule, so it drew an empty cell with a stray tick in
            // it under the card — visible in any screenshot of this screen. The
            // sections below are already separated by their own headers.
            //
            // It survives a search that is looking for it (board #12). It used
            // to vanish on the first keystroke, so typing «переказ» — the word
            // it is named after — was the one way to guarantee never finding it.
            if purpose == .expense && Self.searchFindsOwnTransfer(query) {
                notAnExpenseRow
            }
            // «Нещодавні» when this person has picked something, «Популярні»
            // until then — never both, and never an empty heading. The two
            // answer the same question ("what do I probably want?") and only
            // one of them can be answered at a time.
            if purpose != .income && query.isEmpty {
                let recents = store.recentCategories
                if !recents.isEmpty {
                    Section("Нещодавні") { ForEach(recents, id: \.self) { row($0) } }
                } else if !popular.isEmpty {
                    Section("Популярні") { ForEach(popular, id: \.self) { row($0) } }
                }
            }
            Section(purpose == .income ? "Звідки ці гроші" : "Усі") {
                ForEach(matches, id: \.self) { row($0) }
            }
            if purpose == .income {
                Section { refundRow }
            }
            if let name = creatable {
                Section {
                    Button {
                        // What it creates is what the row needs: a category
                        // made from an income row IS income, which is what
                        // makes offering creation here safe at all.
                        store.addCategory(name, kind: purpose == .income ? .earned : .spending)
                        onPick(.category(name))
                        dismiss()
                    } label: {
                        Label("Створити «\(name)»", systemImage: "plus.circle")
                            .foregroundStyle(Theme.green)
                    }
                    .accessibilityIdentifier("picker.create")
                }
            }
        }
    }

    private var notAnExpenseRow: some View {
        Button {
            onPick(.notAnExpense)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Theme.inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Переказ між своїми картками").font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Гроші лишились у вас — просто на іншому рахунку")
                        .font(Theme.font(13)).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("picker.notAnExpense")
    }

    /// Money can also come in because a shop gave it back, and that row is
    /// genuinely «Продукти» — it belongs against the groceries it cancels,
    /// not in the income base. Without this the four income categories would
    /// be the only answers available, and «Інші надходження» is one of the
    /// three earned categories the seed ships: every refund would then inflate
    /// the monthly income the whole plan is a percentage of.
    private var refundRow: some View {
        Button {
            refunding = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(Theme.inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Це повернення покупки").font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Магазин повернув гроші — оберіть, за що саме")
                        .font(Theme.font(13)).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("picker.refund")
    }

    private var refundList: some View {
        List {
            Section("За що повернули гроші") {
                ForEach(Self.matching(refundQuery, in: everyCategory), id: \.self) { row($0) }
            }
        }
        .searchable(text: $refundQuery, prompt: "Пошук категорії")
        .navigationTitle("Повернення")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("picker.refund.list")
    }

    private func row(_ name: String) -> some View {
        Button {
            onPick(.category(name))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CategorySwatch(name, size: 26, cornerRadius: 8)
                Text(name).foregroundStyle(Theme.ink)
                Spacer()
                if name == selected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.green)
                }
            }
        }
        .accessibilityIdentifier("picker.row.\(name)")
    }
}

extension CategoryPicker {
    /// The eight «Популярні» offers, most-reached-for first rather than
    /// alphabetical: this list is short enough to read whole, and its job is to
    /// put the likeliest answer under the thumb.
    static let popularCategories = ["Продукти", "Кафе та ресторани", "Транспорт",
                                    "Покупки", "Автомобіль", "Розваги",
                                    "Квартплата", "Медицина"]

    /// Whether the own-transfer row belongs in a list filtered by `query`.
    ///
    /// Its title is not in `store.categories` — it is not a category — so the
    /// ordinary filter cannot see it, and the row simply disappeared on the
    /// first keystroke. The old wording is included deliberately: someone who
    /// remembers «Це не витрата» is looking for exactly this row.
    static func searchFindsOwnTransfer(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let words = ["переказ між своїми картками", "свої картки", "це не витрата"]
        return words.contains { $0.contains(needle) }
    }

    /// Categories matching the query by substring, case-insensitively.
    /// A blank query is not a filter — it returns everything.
    static func matching(_ query: String, in all: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(needle) }
    }

    /// Whether the picker offers to create the searched-for name, and under
    /// which name.
    ///
    /// **It refused for income until board #94, and the reason was real:** a
    /// category invented there sat outside a hardcoded `earnedCategories`, so
    /// the row counted as income on Головна and as nothing at all in Бюджет —
    /// the very split `.income` exists to close. A category now carries its
    /// own kind and one created here is `.earned`, which closes that split at
    /// the source instead of by refusing to let anybody near it.
    ///
    /// It still never offers beside the own-transfer row, for the reason
    /// `creatableName` gives about near-matches: now that «переказ» keeps that
    /// row on screen (board #12), offering «Створити «переказ»» in the same
    /// breath invites a person to make a category out of the one answer that
    /// must not be one — and the app would remember it forever.
    static func offeredCreation(for query: String, in all: [String],
                                purpose: CategoryPurpose) -> String? {
        guard !(purpose == .expense && searchFindsOwnTransfer(query)) else { return nil }
        return creatableName(for: query, in: all)
    }

    /// The name to offer creating, or nil.
    ///
    /// Offered ONLY when nothing in the list matches — including as a
    /// substring. Offering it beside a visible near-match invites the user to
    /// create "Прод" while "Продукти" sits one row above, which splits that
    /// category's history in two and cannot be undone by renaming later.
    static func creatableName(for query: String, in all: [String]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, matching(trimmed, in: all).isEmpty else { return nil }
        return trimmed
    }
}
