import SwiftUI

/// The plan against the month. Empty until a plan exists; after that, one row
/// per line with a bar and a tick where the plan sits, plus whatever was spent
/// outside the plan entirely.
struct BudgetView: View {
    @Environment(AppStore.self) private var store
    @State private var month: MonthKey?
    @State private var editing = false
    /// Board #114 — the bank scope sheet.
    @State private var scoping = false

    /// Months with data, plus the month being lived in even when nothing has
    /// been spent in it yet. Without that last part the tab opened on the
    /// newest month that *had* rows — disagreeing with Головна, which always
    /// reports the current calendar month — and the `›` chevron was disabled
    /// at the far end, so the current month could not be reached at all.
    private var months: [MonthKey] {
        let m = Derived.months(store.transactions), now = MonthKey(Date())
        return m.contains(now) ? m : (m + [now]).sorted()
    }

    /// The spec is explicit: actuals are always the current calendar month
    /// until the user steps away from it.
    private var current: MonthKey { month ?? MonthKey(Date()) }

    /// The plan the month being looked at was actually measured against —
    /// board #62, and the point of the whole card. Browsing back to a month
    /// that was lived under different shares now shows THOSE shares.
    private var planInForce: Budget? { store.plan(for: current) }

    private var report: BudgetMath.Report? {
        planInForce.map {
            BudgetMath.report($0, txs: store.transactions, month: current, now: Date(),
                              categories: store.categories)
        }
    }

    private var isCurrentMonth: Bool { current == MonthKey(Date()) }

    var body: some View {
        NavigationStack {
            Group {
                if store.transactions.isEmpty {
                    noIncomeYet
                } else if let report {
                    filled(report)
                } else {
                    empty
                }
            }
            .background(Theme.bg)
            .navigationTitle("Бюджет")
            .toolbar {
                if store.budget != nil {
                    ToolbarItem(placement: .principal) { monthStepper }
                    // Still current-month only, but the reason changed with
                    // board #62. It used to be that one stored plan meant
                    // editing from March would rewrite what August was
                    // measured against. Now each month keeps the plan it had —
                    // so editing a past one would be rewriting what actually
                    // happened, which is a worse thing to offer, not a better
                    // one. A past month is browsable and nothing else.
                    if isCurrentMonth {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Змінити") { editing = true }
                                .accessibilityIdentifier("budget.edit")
                        }
                    }
                }
            }
            .sheet(isPresented: $scoping) {
                BudgetScopeView(current: planInForce?.banks) { store.setBudgetScope($0) }
            }
            .sheet(isPresented: $editing) {
                // Pre-filled from the plan in force, so «Скласти новий» on the
                // 1st starts from last month's shares rather than from a blank
                // sheet — re-planning is usually an adjustment, not a rewrite.
                PercentEditorView(budget: planInForce) { store.setBudget($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("budget.title")
        }
    }

    /// Board #114. The banks this plan is about, named — never «2 банки»,
    /// which would make a person open the sheet to find out which two.
    ///
    /// **A bank NAME is the person's own data and is never translated**
    /// (board #96), which is why the whole line is assembled here and drawn
    /// verbatim rather than handed to the catalogue as a key.
    private var scopeLabel: String {
        Self.scopeLabel(planInForce?.banks, store: store)
    }

    static func scopeLabel(_ banks: [String]?, store: AppStore) -> String {
        guard let banks, !banks.isEmpty else {
            return L10n.t("Усі банки", store.settings.languageChoice)
        }
        let names = banks.compactMap { id in
            store.banks.first { $0.id == id }?.displayName
        }
        // A scope naming a bank that is no longer connected still has to read
        // as something: falling back to the ids keeps the line honest rather
        // than quietly shortening it to the banks that survived.
        return (names.isEmpty ? banks : names).joined(separator: ", ")
    }

    /// The pending change, said as a date and a scope. Shown for the rest of
    /// the month the change was made in — the whole time the cost is being
    /// paid, not just the moment it was chosen.
    static func pendingLine(_ pending: [String]?, store: AppStore) -> String {
        let month = MonthKey(Date()).advanced(by: 1).fromTitle
        return String(format: L10n.t("З %@: %@", store.settings.languageChoice),
                      month, scopeLabel(pending, store: store))
    }

    /// Before `empty`: nothing has synced yet, so there is no income to read.
    ///
    /// **Board #23 took the dead end out of it.** This screen used to be an
    /// explanation and nothing else — and the comment that lived here said
    /// offering «Скласти план» would send the user into an editor with nothing
    /// to divide. That was wrong: `IncomeBaseView` has always had «Своя сума»,
    /// and the editor works on percentages, so a person who knows their salary
    /// can write the whole plan before a single purchase arrives. The tab was
    /// telling them to wait for a number they already knew.
    private var noIncomeYet: some View {
        VStack(spacing: 16) {
            Spacer()
            Card {
                Text("Покупки ще не завантажилися, тож середній дохід рахувати нема з чого.")
                    .font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("budget.empty")
                Text("Але чекати не обов'язково: вкажіть свою суму на місяць. Коли дані прийдуть, перемкнете план на середній дохід.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                SyncStatusView()
            }
            Spacer()
            PrimaryButton(title: "Скласти план") { editing = true }
                .accessibilityIdentifier("budget.create")
        }
        .padding(.horizontal, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "chart.pie")
                .font(.system(size: 56, weight: .light)).foregroundStyle(Theme.inkMuted)
            Text("Плану ще немає").font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
            Text("Тут ви розділите місячний дохід на частки — оренда, продукти, заощадження — і побачите, де витрати від плану відходять.")
                .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
            Spacer()
            PrimaryButton(title: "Скласти план") { editing = true }
                .accessibilityIdentifier("budget.create")
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filled(_ report: BudgetMath.Report) -> some View {
        let worst = BudgetMath.worstDrift(report)
        return ScrollView {
            VStack(spacing: 14) {
                if isCurrentMonth && store.planNeedsAMonthlyDecision() { monthlyDecisionCard }
                if let worst, let text = BudgetMath.driftText(worst, store.settings.languageChoice) {
                    Card {
                        // The category above the sentence, exactly as Home
                        // does it: `driftText` leaves the savings line's
                        // subject out on purpose, so on its own the card
                        // could read «Залишилось 2 116 ₴ із запланованих
                        // 4 670 ₴» with nothing saying of what.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(worst.category)
                                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                                .accessibilityIdentifier("budget.drift.category")
                            // `verbatim`: `driftText` translated it at the source.
                    Text(verbatim: text).font(Theme.font(15)).foregroundStyle(Theme.clay)
                                .accessibilityIdentifier("budget.drift.text")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // `.contain`, not a bare identifier: `Card` is a plain
                    // VStack, and a bare id here would stamp itself onto both
                    // Texts above and smother their own.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("budget.drift")
                }

                Card {
                    HStack {
                        Text("Дохід на місяць").font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                        Spacer()
                        Text(report.income.uah).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    }
                    // Board #62's first criterion. The stepper says which month
                    // you are LOOKING at; this says which month the plan you
                    // are looking at was written for, and the two are not the
                    // same thing the moment there is more than one plan.
                    Text(planLabel).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("budget.planMonth")
                    // Board #114. Which banks this plan is about, on the card
                    // that already says which month it is about — the two
                    // together are the whole answer to "what am I looking at".
                    // Always shown, including «Усі банки»: a scope that only
                    // appeared once narrowed would make the ordinary case
                    // silent, and somebody would have to remember whether they
                    // had ever set one.
                    Button { scoping = true } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: scopeLabel)
                                .font(Theme.font(14, .medium)).foregroundStyle(Theme.green)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.green)
                        }
                        .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("budget.scope")
                    if let pending = store.pendingBudgetScope() {
                        // The cost, kept visible for the whole month it is
                        // being paid. Saying it once inside a sheet somebody
                        // has closed is saying it to nobody.
                        Text(verbatim: Self.pendingLine(pending, store: store))
                            .font(Theme.font(13)).foregroundStyle(Theme.clay)
                            .accessibilityIdentifier("budget.scope.pending")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("budget.income")

                VStack(spacing: 12) {
                    // The worst drift already has the top card to itself; the
                    // row repeating it word for word made the same sentence
                    // appear twice on one screen.
                    ForEach(report.rows) { row in
                        rowCard(row, repeatsTopCard: row.id == worst?.id)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("budget.rows")

                if !report.unplanned.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Поза планом").font(Theme.font(15, .medium))
                                    .foregroundStyle(Theme.inkMuted)
                                Spacer()
                                Text(report.unplannedTotal.uah)
                                    .font(Theme.font(15, .semibold)).foregroundStyle(Theme.inkSoft)
                                    .accessibilityIdentifier("budget.unplanned.total")
                            }
                            ForEach(report.unplanned.prefix(6)) { slice in
                                HStack {
                                    Text(slice.name).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                                    Spacer()
                                    Text(slice.sum.uah).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
    }

    private func rowCard(_ row: BudgetMath.PlanRow, repeatsTopCard: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(row.category).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("budget.row.\(row.category)")
                    Spacer()
                    Text("\(row.actual.uah) / \(row.planned.uah)")
                        .font(Theme.font(15))
                        .foregroundStyle(row.offPlan ? Theme.clay : Theme.inkSoft)
                }
                bar(row)
                // The spec asks for planned % and ₴ AND actual % and ₴. The
                // ₴ pair is the line above; the bar's fill and tick show the
                // percentages graphically, and a graph is not a number.
                HStack {
                    Text("Факт \(BudgetMath.percentText(row.share))")
                        .accessibilityIdentifier("budget.actualPercent.\(row.category)")
                    Spacer()
                    Text("План \(BudgetMath.planPercentText(row.percent))")
                        .accessibilityIdentifier("budget.plannedPercent.\(row.category)")
                }
                .font(Theme.font(13))
                .foregroundStyle(Theme.inkMuted)
                if !repeatsTopCard, let text = BudgetMath.driftText(row, store.settings.languageChoice) {
                    Text(text).font(Theme.font(14)).foregroundStyle(Theme.clay)
                        .accessibilityIdentifier("budget.drift.\(row.category)")
                }
            }
        }
    }

    /// Fill is the actual share; the tick is where the plan sits. Both are
    /// shares of the same income base, or the tick would mean nothing (D4).
    private func bar(_ row: BudgetMath.PlanRow) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.greenWash).frame(height: 8)
                Capsule()
                    .fill(row.offPlan ? Theme.clayLight : Theme.green)
                    .frame(width: max(0, min(1, row.share)) * width, height: 8)
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: 2, height: 14)
                    .offset(x: min(1, row.percent / 100) * width - 1)
            }
            .frame(height: 14)
        }
        .frame(height: 14)
    }

    /// «План на липень 2026» — or «План на цей місяць» when the two agree,
    /// which is the ordinary case and does not need a date repeated from the
    /// stepper two inches above it.
    private var planLabel: LocalizedStringKey {
        guard let month = planInForce?.month else {
            // A plan written before board #62 belongs to no month in
            // particular, and saying «План на січень 0» would be worse than
            // saying nothing precise.
            return "План без прив'язки до місяця"
        }
        // «за», not «від». `MonthKey.title` is nominative («серпень 2026»),
        // and «від» governs the genitive — «План від серпень 2026» is
        // ungrammatical. «за» governs the accusative, which for an inanimate
        // masculine noun is the nominative form, so this reads correctly with
        // the string the formatter already produces. It is also the natural
        // Ukrainian phrase for it: «звіт за серпень», «план за серпень».
        return month == current ? "План на цей місяць" : "План за \(month.title)"
    }

    /// The 1st has come round. An offer on the screen, not a modal on launch:
    /// the old plan is still the newest one written on or before now, so it
    /// goes on measuring this month and nothing is broken while the person
    /// ignores this.
    private var monthlyDecisionCard: some View {
        Card {
            Text("Новий місяць — \(MonthKey(Date()).title)")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            // Same grammar note as `planLabel`: «на» takes the accusative,
            // which for these month names is the nominative the formatter
            // gives, so no second form of the string is needed.
            //
            // The fallback goes through `L10n.t` because it is substituted INTO
            // the key rather than being part of it: a bare literal here is a
            // plain `String` filling `%@`, so it reaches an English reader
            // untouched even though the catalogue has held its translation
            // since board #85. Nothing read it.
            Text("Поки що діє план, складений на \(store.budget?.month?.title ?? L10n.t("попередній місяць", store.settings.languageChoice)). Лишити його чи скласти новий?")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            HStack(spacing: 12) {
                Button("Лишити той самий") { store.carryPlanForward() }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.greenWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("budget.carryForward")
                Button("Скласти новий") { editing = true }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.greenWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("budget.replan")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("budget.monthlyDecision")
    }

    private var monthStepper: some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(months.first == nil || current <= months.first!)
                .accessibilityIdentifier("budget.prevMonth")
            Text(current.title).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("budget.month")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(months.last == nil || current >= months.last!)
                .accessibilityIdentifier("budget.nextMonth")
        }
    }

    /// Steps through months that HAVE data, like the feed's: calendar
    /// arithmetic would strand the user on an empty gap month.
    private func step(_ delta: Int) {
        guard let i = months.firstIndex(of: current) else { return }
        let next = i + delta
        guard months.indices.contains(next) else { return }
        month = months[next]
    }
}
