import SwiftUI

/// Board #114 — which banks the budget is about.
///
/// **One plan with a scope, not a plan per bank.** That was the owner's
/// decision and the card's real work; the alternative it beat would multiply
/// every board #94 concept — income base, category kinds, the month a plan
/// belongs to — by the number of banks, leaving somebody with N plans that can
/// disagree about what a month's income was.
///
/// So a scope is a FILTER on the rows a plan is measured against and nothing
/// else, which is what keeps `BudgetMath` kind-driven: it is applied to the
/// transactions before they arrive there, and no function in that file ever
/// asks which bank a row came from.
///
/// **A change takes effect next month**, and this screen says so before the
/// tap rather than after it. A half-spent month has a plan somebody already
/// made decisions against, and narrowing it now would rewrite what those
/// decisions were measured by.
struct BudgetScopeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// `nil` — every bank. Mirrors `Budget.banks`, including its reason for
    /// being optional rather than a full list: a plan that has never been
    /// scoped means "everything", not "everything as it happened to be on the
    /// day somebody opened this screen".
    @State private var chosen: Set<String>?

    let current: [String]?
    var onSave: ([String]?) -> Void

    /// Only banks that are actually connected. A scope naming a bank somebody
    /// removed would be a filter nobody can see or clear.
    private var banks: [Bank] { store.banks.filter(\.connected) }

    private var isEverything: Bool { chosen == nil }

    /// The month the change lands in, named rather than called «наступного
    /// місяця»: a person deciding this in the last week of August needs to see
    /// «вересень», not do the arithmetic.
    private var effectiveMonth: String {
        MonthKey(Date()).advanced(by: 1).fromTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Text("Які банки рахує бюджет")
                            .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                        Text("План лишається один. Ви лише обираєте, чиї покупки він рахує — і дохід береться з тих самих карток.")
                            .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    }

                    Card {
                        choice(title: "Усі банки", on: isEverything) { chosen = nil }
                        ForEach(banks) { bank in
                            // `Text(verbatim:)`: a bank NAME is the person's
                            // own data and is never translated — board #96's
                            // rule, and the reason this row cannot take the
                            // ordinary `LocalizedStringKey` overload.
                            choice(title: nil, verbatim: bank.displayName,
                                   identifier: bank.id,
                                   on: chosen?.contains(bank.id) == true) {
                                toggle(bank.id)
                            }
                        }
                    }

                    // Stated BEFORE the tap. The cost is real: for the rest of
                    // this month the budget goes on counting banks the person
                    // has just decided it should not, and a screen that only
                    // said so afterwards would have let them believe otherwise
                    // for four weeks.
                    Card {
                        Text("Зміна почне діяти з наступного місяця")
                            .font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("scope.effective.title")
                        Text(verbatim: String(format: L10n.t("До кінця цього місяця план рахує так, як рахував — ви вже приймали рішення за цими числами. Новий обсяг застосується з %@.",
                                                             store.settings.languageChoice),
                                              effectiveMonth))
                            .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                            .accessibilityIdentifier("scope.effective.cost")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(Theme.bg)
            .navigationTitle("Обсяг бюджету")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Скасувати") { dismiss() }
                        .accessibilityIdentifier("scope.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Зберегти") {
                        onSave(chosen.map { Array($0).sorted() })
                        dismiss()
                    }
                    // An empty selection would measure a month against
                    // nothing, which reads as a broken screen rather than a
                    // choice. «Усі банки» is how you mean everything.
                    .disabled(chosen?.isEmpty == true)
                    .accessibilityIdentifier("scope.save")
                }
            }
            .onAppear { chosen = current.map(Set.init) }
        }
    }

    private func toggle(_ id: String) {
        // Starting from "everything", the first tap means "only this one" —
        // not "everything except". Somebody narrowing a scope has one bank in
        // mind, and pre-selecting all of them would make them untick the rest.
        var next = chosen ?? []
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        chosen = next
    }

    @ViewBuilder
    /// `identifier` is the bank's ID, never its display name. A bank NAME is
    /// the person's own data, and an identifier built from one puts it into
    /// every test that queries the row — the rule `BankDetailView` states for
    /// card suffixes, and the same reason.
    private func choice(title: LocalizedStringKey?, verbatim: String? = nil,
                        identifier: String = "all",
                        on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Theme.green : Theme.inkMuted)
                if let verbatim {
                    Text(verbatim: verbatim).font(Theme.font(16)).foregroundStyle(Theme.ink)
                } else if let title {
                    Text(title).font(Theme.font(16)).foregroundStyle(Theme.ink)
                }
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scope.choice.\(identifier)")
    }
}
