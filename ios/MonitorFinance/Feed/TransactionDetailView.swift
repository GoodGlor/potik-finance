import SwiftUI

/// One transaction, everything known about it, and the two things the user can
/// change: its category, and whether that answer should stand for the merchant.
struct TransactionDetailView: View {
    let id: Transaction.ID
    @Environment(AppStore.self) private var store
    @State private var showPicker = false
    @State private var ruleEffect: String?
    /// Board #100. How many other rows of this merchant the last edit left
    /// disagreeing — counted at the moment of the edit, not recomputed, so the
    /// offer says the number it was made about even as it is acted on.
    @State private var offerCount = 0
    @State private var offerApplied: Int?

    private var tx: Transaction? { store.transactions.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let tx {
                VStack(spacing: 14) {
                    headline(tx)
                    facts(tx)
                    categoryCard(tx)
                    applyToSimilarCard(tx)
                    budgetCard(tx)
                    ruleCard(tx)
                    receiptCard(tx)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            } else {
                // The row was deleted or reset underneath us; say so rather
                // than render an empty screen that looks like a loading state.
                Text("Операцію не знайдено")
                    .font(Theme.font(18)).foregroundStyle(Theme.inkSoft).padding(40)
            }
        }
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.title")
        .navigationTitle("Операція")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            CategoryPicker(selected: tx?.category,
                           purpose: tx?.kind == .income ? .income : .expense) { picked in
                switch picked {
                case .category(let name):
                    store.setCategory(id, to: name)
                    // Board #100: the correction is done; the offer is about
                    // the merchant's backlog. Counted AFTER the edit, so the
                    // anchor row itself is already agreeing and is not counted.
                    offerCount = store.othersDisagreeing(with: id)
                    offerApplied = nil
                // `setNotAnExpense`, NOT the queue's `markNotAnExpense`: this
                // screen answers for the row in hand and never for the
                // merchant — see the store's own doc, and `setCategory` one
                // line above, which has always made that promise.
                case .notAnExpense: store.setNotAnExpense(id)
                }
            }
        }
    }

    private func headline(_ tx: Transaction) -> some View {
        Card {
            Text(tx.merchant).font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
            Text(tx.amount.signedUahExact)
                .font(Theme.font(36, .bold))
                .foregroundStyle(tx.kind == .income ? Theme.green
                                 : tx.kind == .transfer ? Theme.inkMuted : Theme.ink)
                .accessibilityIdentifier("detail.amount")
            Text(Self.stamp(tx.date)).font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
        }
    }

    private func facts(_ tx: Transaction) -> some View {
        Card {
            factRow("Картка", tx.cardSuffix)
            // Through `BankMark` rather than its own lookup: this screen and
            // the feed row that opens it must not be able to name the same
            // bank differently. Board #98.
            factRow("Банк", BankMark.bank(tx.bankId, store.banks))
            factRow("Звідки категорія", Self.resolutionText(tx.resolution))
        }
    }

    private func categoryCard(_ tx: Transaction) -> some View {
        Card {
            Text("Категорія").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    CategorySwatch(tx.category, size: 28, cornerRadius: 8)
                    Text(verbatim: Derived.categoryLabel(tx, store.settings.languageChoice))
                        .font(Theme.font(18, .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("detail.category.value")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.category")
        }
    }

    /// Non-nil only when this transaction is what took its line past the plan.
    /// `pushedOverPlan` runs the category's spend for the month in order and
    /// asks whether the running total was at-or-under the plan just before
    /// this row and over it once this row is added — so a purchase landing on
    /// an already-over line stays quiet, and every row after the crossing for
    /// the rest of the month stays quiet too. Otherwise they would all carry
    /// the same warning and the warning would stop meaning anything.
    private func budgetDrift(_ tx: Transaction) -> String? {
        guard let budget = store.budget,
              let row = BudgetMath.pushedOverPlan(tx, budget: budget,
                                                  txs: store.transactions, now: Date(),
                                                  categories: store.categories)
        else { return nil }
        return BudgetMath.driftText(row, store.settings.languageChoice)
    }

    @ViewBuilder
    private func budgetCard(_ tx: Transaction) -> some View {
        if let text = budgetDrift(tx) {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15)).foregroundStyle(Theme.clay)
                    // `verbatim`: `driftText` translated it at the source.
                    Text(verbatim: text).font(Theme.font(15)).foregroundStyle(Theme.clay)
                        .accessibilityIdentifier("detail.budgetDrift")
                }
            }
        }
    }

    /// What the app has learned about this merchant, and the two ways to change
    /// it: teach a rule, or forget the one that stands.
    ///
    /// **The toggle exists exactly when tapping it teaches a rule** (board #11).
    /// It used to exist always, and be `.disabled` in three states it could
    /// never leave — which is how a control ends up lying. `set:` had no way to
    /// withdraw a rule because `AppStore` had no call for it, so a standing rule
    /// left an "off" flick that silently did nothing and sprang back; there is a
    /// `deleteRule` now, and a rule is retracted with a button that says so
    /// rather than by flicking a switch backwards.
    ///
    /// The three states that are words instead:
    ///
    /// * **A rule stands.** Spelled out through `RuleText`, the same vocabulary
    ///   the list in Налаштування → Категорії → «Правила» reads, so the two
    ///   screens cannot describe one rule differently. This is where the rules
    ///   taught under board #6's old, wider «Це не витрата» finally become
    ///   visible on the row they are acting on — the repair path that card's
    ///   migration decision promises in writing.
    /// * **A `GenericMerchant`.** `confirm` writes no rule for one and returns
    ///   early, so the toggle used to report «Правило збережено» over a rule
    ///   table it had not touched, then spring back off at the next render.
    ///   Saying "we ask about these every time" is both true and the reason.
    /// * **No category.** «Завжди відносити … до цієї категорії» is a sentence
    ///   about a category, and a `.transfer` row has none. Teaching "this
    ///   merchant is always an own transfer" is still unreachable from here,
    ///   deliberately (board #13): that rule types every future row of the
    ///   merchant `.transfer` at ingest, where it reaches no queue and no
    ///   spending figure, so it stays in the one place that shows a toast and
    ///   an undo while it happens.
    ///
    /// **«Забути правило» asks for no confirmation here, and the list screen's
    /// does** — deliberately, not by oversight. There, it is a swipe (easy to
    /// mis-fire) on a row that is only a merchant and an answer. Here the
    /// person is reading the rule spelled out on a purchase it decided, the
    /// button says what it does, and the line underneath reports what happened.
    /// The two screens agree about what forgetting MEANS; they disagree about
    /// how easy the gesture is to make by accident, which is the thing a
    /// confirmation is for.
    ///
    /// It is also the only way out of an ambiguous merchant. `confirm` refuses
    /// to write a rule for one — `wasAmbiguous` keeps it asking — so a single
    /// mis-tap that contradicted an earlier answer used to mark a merchant
    /// "ask every time" permanently, with the toggle inert and no explanation.
    /// Forgetting the ambiguous rule lets the next answer teach a fresh one.
    /// **Board #100 — the same correction, offered to the merchant's backlog.**
    ///
    /// The gap this fills is narrow and real. `confirm`'s cascade reaches only
    /// `.pending` rows, so when a person finds a purchase that was categorised
    /// WRONGLY and fixes it, every other row of that merchant — already
    /// answered, and answered wrongly in the same way — keeps its answer. The
    /// rule toggle below does not help either: it governs what happens next.
    ///
    /// Shown only right after an edit, and only while there is something to
    /// offer. It is not a standing control: a card that is always on screen
    /// asking "shall I change twelve other rows?" is a thing to mis-tap, and
    /// the moment the question is worth asking is the moment the person has
    /// just said this category is the right one.
    @ViewBuilder
    private func applyToSimilarCard(_ tx: Transaction) -> some View {
        if let offerApplied {
            Card {
                Text(verbatim: String(format: L10n.t("Змінено ще %@", store.settings.languageChoice),
                                      Plural.operations(offerApplied, store.settings.languageChoice)))
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("detail.similarApplied")
            }
        } else if offerCount > 0 {
            Card {
                Text(verbatim: String(
                    format: L10n.t("Ще %@ «%@» мають іншу категорію.", store.settings.languageChoice),
                    Plural.operations(offerCount, store.settings.languageChoice), tx.merchant))
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("detail.similarOffer")
                // Says BACKLOG explicitly, because the toggle below this card
                // says future and a person must be able to tell which they got.
                Text("Змінити і їх? Це не створює правила — майбутні покупки вирішує перемикач нижче.")
                    .font(Theme.font(14)).foregroundStyle(Theme.inkSoft)
                HStack(spacing: 12) {
                    Button("Змінити всі") {
                        offerApplied = store.applyCategoryToSimilar(id)
                        offerCount = 0
                    }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.greenWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("detail.similarApply")

                    Button("Тільки цю") { offerCount = 0 }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .accessibilityIdentifier("detail.similarDecline")
                }
            }
        }
    }

    @ViewBuilder
    private func ruleCard(_ tx: Transaction) -> some View {
        let key = MerchantKey.normalize(tx.merchant)
        // The rule that governs THIS row's kind (board #81). A merchant may
        // hold one for its expenses and another for its income, and showing
        // the wrong one here would put a sentence about a salary on the detail
        // screen of a purchase — and «Забути правило» would then forget it.
        let rule = store.rules.governing(key, kind: tx.kind)
        Card {
            switch Self.ruleState(for: tx, rule: rule, store.settings.languageChoice) {
            case .stands(let sentence):
                Text(verbatim: sentence).font(Theme.font(16)).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("detail.ruleStanding")
                Button("Забути правило") {
                    if let rule { store.deleteRule(rule) }
                    // The row keeps its category — `deleteRule` touches no
                    // transaction — so without a line here the tap reads as
                    // having done nothing at all.
                    ruleEffect = String(
                        format: L10n.t("Правило забуто. Наступні покупки «%@» знову спитаємо.",
                                       store.settings.languageChoice), tx.merchant)
                }
                .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                .frame(minHeight: 44)
                .accessibilityIdentifier("detail.forgetRule")

            case .cannot(let sentence):
                Text(verbatim: sentence).font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("detail.ruleUnavailable")

            case .teachable:
                Toggle(isOn: Binding(
                    get: { false },
                    set: { on in
                        guard on else { return }
                        let changed = store.confirm(id, as: tx.category)
                        // `confirm` does not always write the rule the user
                        // asked for: answering this merchant differently from a
                        // previous answer marks it `ambiguous` with no category,
                        // and it will now ask every time. Saying "Правило
                        // збережено" there is a lie, so read the rule that
                        // actually landed.
                        let ambiguous = store.rules.governing(key, kind: tx.kind)?.ambiguous ?? false
                        ruleEffect = Self.ruleEffectText(changed: changed,
                                                         merchant: tx.merchant,
                                                         category: tx.category,
                                                         ambiguous: ambiguous,
                                                         store.settings.languageChoice)
                    })) {
                    Text("Завжди відносити «\(tx.merchant)» до цієї категорії")
                        .font(Theme.font(16)).foregroundStyle(Theme.ink)
                }
                .tint(Theme.green)
                .accessibilityIdentifier("detail.alwaysRule")
            }

            if let ruleEffect {
                // `verbatim`: already translated where it was assembled,
                // by `L10n.t` — a second lookup would find nothing.
                Text(verbatim: ruleEffect).font(Theme.font(14)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("detail.ruleEffect")
            }
        }
    }

    /// Detaching lives here and only here (spec) — never in the feed, where
    /// Task 8 reuses `ReceiptItemsView` to show the same items read-only.
    ///
    /// No "Додати чек" any more (D2): a fiscal QR carries no purchase to
    /// point back at, so scanning moved to Розібрати — the one screen that
    /// already asks the user to answer for things the app cannot decide on
    /// its own — where matching runs automatically and a person is asked
    /// only for the two cases it cannot resolve (`ReceiptCard`). This card
    /// stays read-only for an unmatched purchase; detaching an ALREADY
    /// attached receipt is still here, unaffected.
    private func receiptCard(_ tx: Transaction) -> some View {
        Card {
            Text("Чек").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
            if let receipt = store.receipt(for: tx) {
                Text(receipt.displaySeller)
                    .font(Theme.font(18, .semibold)).foregroundStyle(Theme.ink)
                Text(Self.stamp(receipt.fiscalTime))
                    .font(Theme.font(14)).foregroundStyle(Theme.inkSoft)
                Text("Каса \(receipt.registerNumber) · чек №\(receipt.documentNumber)")
                    .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                ReceiptItemsView(receipt: receipt)
                Button("Відкріпити") { store.detachReceipt(from: tx.id) }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("detail.receipt.detach")
            } else {
                Text("Чек не додано").font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
            }
        }
        // A bare identifier on this `Card` would stamp every descendant and
        // swallow `detail.receipt.detach` beneath it. `.contain` must come
        // first — declaring the container's semantics before it is named —
        // matching the `detail.title`/`scanner.title` pattern; naming first
        // let the container merge its children before `.contain` could stop
        // it, and swallowed every button beneath it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.receipt")
    }

    /// `label` is copy, `value` is the row's own data — a date, a sum, a
    /// card. The pair is why the two halves are typed differently.
    private func factRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
            Spacer()
            Text(verbatim: value).font(Theme.font(16, .medium)).foregroundStyle(Theme.ink)
        }
        .frame(minHeight: 32)
    }

    static func resolutionText(_ r: Resolution) -> String {
        switch r {
        case .rule: return "за правилом"
        case .pattern: return "за схожими"
        case .transfer: return "переказ між своїми"
        case .user: return "ви підтвердили"
        case .pending: return "ще не розібрано"
        case .skipped: return "пропущено"
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = .kyiv; f.timeZone = .kyiv
        f.locale = L10n.formatting.locale
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }
}

extension TransactionDetailView {

    /// What the rule card offers for one row: words, or a control.
    enum RuleState: Equatable {
        /// A rule stands for this merchant — the sentence describing it, and a
        /// «Забути правило» beside it.
        case stands(String)
        /// No rule stands and none can be taught from this screen — why, in
        /// words. Never a disabled control: the states below are permanent for
        /// the row in hand, so an "off" switch would be an invitation that can
        /// never be accepted.
        case cannot(String)
        /// The toggle, live. Reached only when flipping it genuinely writes a
        /// rule.
        case teachable
    }

    /// The rule card's whole decision, as a pure function of the row and the
    /// rule that matches it — so the three states are asserted in
    /// milliseconds rather than by walking a simulator into each of them.
    ///
    /// Order is load-bearing. A `GenericMerchant` CAN carry a rule (the demo
    /// ships two, and any build predating `GenericMerchant` could write one),
    /// so the existing rule is reported first and `RuleText` is what says it is
    /// inert — leading with the generic check instead would tell a person there
    /// is no rule while one sits in the table under this merchant's name,
    /// unforgettable because the screen denied it existed.
    /// `language` because every branch is a SENTENCE, assembled here rather
    /// than written at a `Text` — so no `LocalizedStringKey` literal exists for
    /// the catalogue to match and the translation has to happen at the source.
    /// Same shape `Derived` and `BudgetMath` use.
    static func ruleState(for tx: Transaction, rule: Rule?,
                          _ language: AppLanguage) -> RuleState {
        if let rule {
            let inert = RuleText.isInert(rule)
                ? L10n.t(" (не діє — про такі операції питаємо щоразу)", language) : ""
            return .stands(String(format: L10n.t("Правило: «%@» → %@%@", language),
                                  tx.merchant, RuleText.answer(rule), inert))
        }
        if GenericMerchant.matches(tx.merchant) {
            return .cannot(L10n.t("Про такі операції питаємо щоразу — назва не каже, на що пішли гроші.",
                                  language))
        }
        if tx.category.isEmpty {
            return .cannot(String(format: L10n.t("Спершу оберіть категорію — тоді її можна зробити правилом для «%@».", language),
                                  tx.merchant))
        }
        return .teachable
    }

    /// The line shown after the "always" toggle fires. `changed` is what
    /// `AppStore.confirm` returned: the row in hand, plus every other pending
    /// row of the same merchant that the new rule just resolved.
    ///
    /// `ambiguous` is whether the rule that actually landed asks rather than
    /// answers. It outranks the count: a cascade of 1 is still a rule that
    /// stands, while an ambiguous rule resolved this one row and will resolve
    /// nothing again, so "Правило збережено" would be the opposite of true.
    ///
    /// A static so the count arithmetic and its plural agreement are testable
    /// without a simulator. Inline in the view it was untestable, and the UI
    /// test that appeared to cover it passed for any count at all.
    static func ruleEffectText(changed: Int, merchant: String, category: String,
                               ambiguous: Bool, _ language: AppLanguage) -> String {
        if ambiguous {
            return "«\(merchant)» трапляється в різних категоріях — питатимемо щоразу"
        }
        guard changed > 1 else { return "Правило збережено" }
        let others = changed - 1
        return "Ще \(Plural.purchases(others, language)) \(merchant) → \(category)"
    }
}
