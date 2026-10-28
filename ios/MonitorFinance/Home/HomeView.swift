import SwiftUI

struct HomeView: View {
    /// Cards left to answer — the same number the tab badge shows. Board #8:
    /// this used to be the row count, so Головна and the badge could name two
    /// different figures for one screen's worth of work.
    let cards: Int
    /// Purchases behind those cards. One card can carry twenty.
    let purchases: Int
    var openQueue: () -> Void
    var openBudget: () -> Void
    @Environment(AppStore.self) private var store
    // Settings and Banks push onto this same stack rather than opening as a
    // sheet: a sheet would present above RootView's ZStack, and LockView
    // lives inside that ZStack — backgrounding mid-settings would re-lock
    // underneath the sheet instead of over it. See SettingsRoute.
    @State private var path: [SettingsRoute] = []

    private var month: MonthKey { Derived.months(store.transactions).last ?? MonthKey(Date()) }
    private var totals: Derived.MonthTotals { Derived.totals(Derived.inMonth(store.transactions, month)) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    SyncStatusView()
                    if store.transactions.isEmpty {
                        emptyCard
                    } else {
                        monthCard
                    }
                    budgetCard
                    queueCard
                    tipCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Theme.bg)
            .refreshable {
                // ONE window, at most 61 s — which is what a manual pull means.
                // `.max` pinned the spinner above the list for the whole backfill
                // (~23 paced windows on «12 місяців» × 2 cards, so ~23 minutes), and
                // `.refreshable`'s task belongs to the view: switching tabs or
                // opening a purchase cancels it, and `run` tears the whole backfill
                // down mid-flight. The long backfill belongs to the Task started
                // after onboarding, which no view owns.
                await store.startSync(maxSteps: 1)
                // The independent second source — never instead of the line
                // above, since a person can have either connected, both, or
                // neither. Same gated call the scene-phase handler and the
                // background wake use, so a pull-to-refresh never bypasses
                // the fixture guard those triggers already respect.
                await store.syncPrivatEmailIfConnected()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.title")
            .navigationTitle("Головна")
            .toolbar {
                Button { path.append(.settings) } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.inkSoft)
                }
                .accessibilityIdentifier("home.settings")
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                settingsDestination(route)
            }
        }
    }

    /// The settings hierarchy, moved here unchanged from `MainView.swift`.
    /// Task 11 adds the three new cases; nothing else about this changes. It
    /// stays a pushed stack rather than a sheet because settings is a
    /// hierarchy, not a modal interruption.
    @ViewBuilder
    private func settingsDestination(_ route: SettingsRoute) -> some View {
        switch route {
        case .settings:
            SettingsView(path: $path)
        case .security:
            SecuritySettingsView(path: $path)
        case .changePin:
            ChangePinFlow { path.removeLast() }
        case .banks:
            BanksSettingsView(path: $path)
        case .bankDetail(let id):
            BankDetailView(bankId: id, path: $path)
        case .addBankPicker:
            BankPickerView { id in
                let bank = store.banks.first { $0.id == id }
                if bank?.hasEmailSource == true {
                    path.append(.privatSource)
                } else if bank?.status == .statement {
                    path.append(.importStatement)
                } else {
                    path.append(.addBankToken(id))
                }
            }
        case .privatSource:
            PrivatSourceView(onEmail: { path.append(.emailSetup) },
                             onStatement: { path.append(.importStatement) })
        case .emailSetup:
            PrivatEmailSetupView(buttonTitle: "Готово") { path = [.settings, .banks] }
        case .addBankToken(let id):
            TokenView(bankId: id) { path.append(.addBankCards(id)) }
        case .addBankCards(let id):
            CardSelectionView(bankId: id) {
                path.append(.addBankConnected(id))
                // Board #22: a bank added from Settings never synced. Its
                // rows turned up whenever the app was next activated, which
                // can be hours — so «Підключено» was followed by an app that
                // knew nothing about the bank it had just connected.
                //
                // Here rather than on «Готово», to match onboarding exactly:
                // `SyncDepthView` starts the first run as it pushes the same
                // screen. It is also the first moment the run can honour the
                // card selection — `CardSelectionView` writes every
                // `setSyncEnabled` before calling this.
                Task { await store.startSync() }
            }
        case .addBankConnected(let id):
            ConnectedView(bankId: id, buttonTitle: "Готово") { path = [.settings, .banks] }
        case .importStatement:
            ImportStatementView { summary in path.append(.importSummary(summary)) }
        case .importSummary(let summary):
            ImportSummaryView(summary: summary, buttonTitle: "Готово") { path = [.settings, .banks] }
        case .categories:
            CategoriesSettingsView(path: $path)
        case .rules:
            RulesSettingsView()
        case .data:
            DataSettingsView(path: $path)
        case .syncDepth:
            SyncDepthView {
                path.removeLast()
                // Depth changed under a running app: nothing else would act
                // on it until the next foreground activation or background
                // wake, which can be hours away. `setSyncDepth` has already
                // cleared every cursor's `exhausted`, so this run is what
                // actually reaches the newly-allowed months. `startSync`'s
                // own `guard !isSyncing` keeps it from doubling a backfill
                // that is already in flight.
                Task { await store.startSync() }
            }
        case .about:
            AboutView()
        }
    }

    /// Stands in for `monthCard` while `store.transactions` is empty — there
    /// is no month to report on yet, and falling back to `MonthKey(Date())`
    /// would show «0 ₴», which reads as "you have spent nothing" rather than
    /// "we have not looked yet".
    private var emptyCard: some View {
        Card {
            Text("Ще нічого не завантажено. Перші покупки з'являться за хвилину-дві.")
                .font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                .accessibilityIdentifier("home.empty")
        }
    }

    /// Spent against income for the month in view, with a bar only once there
    /// is income to compare against — on the 1st there is not, and a bar
    /// against zero would read as "you have overspent everything".
    private var monthCard: some View {
        Card {
            Text("Цього місяця").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
            Text(totals.spent.uah).font(Theme.font(44, .bold)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("home.month.spent")
            if totals.income > 0 {
                Text("з \(totals.income.uah) доходу")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hair)
                        Capsule()
                            .fill(totals.spent > totals.income ? Theme.clay : Theme.green)
                            .frame(width: geo.size.width
                                   * min(1, Double(totals.spent) / Double(totals.income)))
                    }
                }
                .frame(height: 12)
            } else {
                Text("Доходу цього місяця ще не було.")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
            }
        }
    }

    /// Compact: the worst-drifting line, or an invitation when there is no
    /// plan. The whole card is a button either way — spec Subsystem 3 requires
    /// the tap-through, and a card that only looks actionable is worse than
    /// one that is.
    ///
    /// Deliberately NO inner accessibility identifier: a Button merges its
    /// children into one element, and prying them apart with
    /// `children: .contain` would stop `app.buttons["home.budget.open"]`
    /// matching — which an existing test in OnboardingAndQueueTests depends
    /// on. The button's own label carries the copy a test needs to read.
    private var budgetCard: some View {
        Button(action: openBudget) {
            Card {
                Text("Бюджет").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                if let budget = store.budget {
                    // The month the user is living in, not `month`'s newest
                    // month with data — a drift warning computed from July
                    // while it is August would be about money no longer
                    // actionable.
                    let report = BudgetMath.report(budget, txs: store.transactions,
                                                   month: MonthKey(Date()), now: Date(),
                                                   categories: store.categories)
                    if let worst = BudgetMath.worstDrift(report), let text = BudgetMath.driftText(worst, store.settings.languageChoice) {
                        Text(worst.category)
                            .font(Theme.font(20, .semibold)).foregroundStyle(Theme.ink)
                        // `verbatim`: `driftText` translated it at the source.
                        Text(verbatim: text).font(Theme.font(15)).foregroundStyle(Theme.clay)
                    } else {
                        Text("План витримується")
                            .font(Theme.font(20, .semibold)).foregroundStyle(Theme.ink)
                        Text("Жодна стаття поки не вийшла за межі.")
                            .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    }
                } else {
                    Text("Плану ще немає").font(Theme.font(20, .semibold)).foregroundStyle(Theme.ink)
                    Text("Розділіть дохід на частки, щоб бачити, де витрати відходять від плану.")
                        .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.budget.open")
    }

    /// Stays visible at zero, in a muted register: a card that vanishes when
    /// the work is done reads as a bug, not as praise.
    ///
    /// «Усе розібрано» now waits for the CARDS to run out, not the purchases
    /// (board #8). A receipt question has no pending row behind it, so on the
    /// old count Головна congratulated the person while the queue still had a
    /// card up and the tab still had a badge.
    private var queueCard: some View {
        Card {
            if cards > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 22)).foregroundStyle(Theme.clayLight)
                    Text(Self.queueLine(cards: cards, purchases: purchases, store.settings.languageChoice))
                        .font(Theme.font(17, .medium)).foregroundStyle(Theme.ink)
                        // Named since board #8: this line is the only place
                        // the purchase count is on screen, and it is what
                        // `testOneTapResolvesEveryPurchaseFromThatShop` reads
                        // now that the queue's progress counts cards.
                        .accessibilityIdentifier("home.queue.line")
                }
                PrimaryButton(title: "Розібрати за хвилину", action: openQueue)
                    .accessibilityIdentifier("home.queue.open")
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22)).foregroundStyle(Theme.green)
                    Text("Усе розібрано").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        // `.contain`, not a bare identifier on the plain-VStack `Card`: without
        // it SwiftUI stamps this identifier onto every descendant, which
        // silently overwrote the `PrimaryButton`'s own "home.queue.open".
        //
        // It surfaces here because its parent marker, `home.title`, sits on a
        // real `ScrollView`. `QueueView.doneScreen` tried the same shape under
        // a SYNTHESISED parent container and never reached the tree at all; it
        // names its headline `Text` instead. A nested `.contain` is only safe
        // under a parent that is a real element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.queue")
    }

    private var tipCard: some View {
        Group {
            if let tip = Derived.tips(store.transactions, store.settings.languageChoice).first {
                Card {
                    Text(LocalizedStringKey(tip.title)).font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                    Text(LocalizedStringKey(tip.body)).font(Theme.font(18, .semibold)).foregroundStyle(Theme.ink)
                    NavigationLink { TipsView() } label: {
                        Text("Ще спостереження")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.greenWash,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityIdentifier("home.tips")
                }
            }
        }
    }

    /// 1 покупка · 2–4 покупки · 5+ покупок — Ukrainian needs all three forms,
    /// and 11–14 take the last one despite ending in 1–4.
    static func purchaseWord(_ n: Int, _ language: AppLanguage) -> String {
        Plural.word(n, language, uk: ("покупка", "покупки", "покупок"),
                    en: ("purchase", "purchases"))
    }

    /// «12 запитань · 66 покупок» — the queue card's headline, board #8.
    ///
    /// **Leads with the same number the badge shows**, because it used to lead
    /// with the row count and the badge with something else, and one screen's
    /// worth of work had two names. The purchases follow it rather than
    /// replace it: the cards are how much work is left, the purchases are how
    /// much of the person's spending is still unsorted, and dropping either
    /// answers only half of what they were looking at the card to find out.
    ///
    /// **Both numbers only when they differ.** One card per purchase is the
    /// common shape after board #7 made every transfer its own card, and «61
    /// запитання · 61 покупка» says one thing twice.
    ///
    /// «запитання», not «магазинів»: a card is a shop, a single transfer, an
    /// ATM withdrawal or a receipt the tax service never published, and only
    /// the first of those is a shop. It is what the queue does to all of them
    /// — it asks.
    ///
    /// **A «·» and not «про N покупок»**, which was the first phrasing and is
    /// ungrammatical: «про» governs the accusative, so 21 needs «про 21
    /// покупку» while `purchaseWord` — correctly, for a standalone label —
    /// gives the nominative «покупка». Two nominative labels beside a
    /// separator need no case agreement at all, and the app already writes
    /// figures this way on the queue cards.
    ///
    /// The adjective agreed here too, once — the line read «61 нових покупка»
    /// with a hardcoded genitive plural. A `static func` so the whole sentence
    /// is assertable without a running screen.
    static func queueLine(cards: Int, purchases: Int, _ language: AppLanguage) -> String {
        let asked = Plural.questions(cards, language)
        guard purchases > cards else { return asked }
        return "\(asked) · \(Plural.purchases(purchases, language))"
    }
}
