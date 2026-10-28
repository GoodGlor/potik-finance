import SwiftUI

struct StatsView: View {
    @Environment(AppStore.self) private var store
    @State private var scope: Scope = .month
    /// Board #101 — whose numbers these are. `@State`, like `scope` beside it:
    /// the tab keeps its view alive (board #64), so it survives a tab switch,
    /// and it deliberately does not survive a relaunch — a scope narrowed to
    /// one card is a question being asked now, not a setting.
    @State private var source: StatsSource = .all
    /// Which question this screen answers: «Загальна» slices by SPENDING
    /// category (today's behaviour, unchanged); «За чеками» slices by
    /// PRODUCT GROUP read from confirmed receipt splits. Stored directly as
    /// `@AppStorage` rather than as a new `Settings` field — a non-optional
    /// field Swift's synthesised `Codable` cannot default on a missing key,
    /// so it would fail every previously-written `settings.json` and silently
    /// reset the owner to not-onboarded, losing `startedUsingAt`.
    @AppStorage("stats.bySplits") private var bySplits = false
    // A typed array only accepts links whose value matches that element type;
    // the embedded feed this stack pushes into also pushes `Transaction`
    // values (its own `NavigationLink(value: tx)`), so the path must be a
    // NavigationPath to carry both route types. It also now carries
    // `ContributionDrill` alongside `CategoryDrill` for the same reason.
    @State private var path = NavigationPath()

    enum Scope: String, CaseIterable { case week, month, year
        var title: String {
            switch self { case .week: return "Тиждень"; case .month: return "Місяць"; case .year: return "Рік" }
        }
    }

    // Board #131 removed `moveScope` and `steppedScope`. They existed only to
    // serve board #115's scope swipe, and that swipe is gone — the scope has
    // always been a row of buttons, which is how the owner uses it. Keeping a
    // tested static that nothing calls would be worse than deleting it: the
    // tests would still pass and would still prove nothing about the app.

    /// **A selection whose rows are gone falls back to everything.** A bank
    /// the person disconnected, or a card that stopped appearing, would
    /// otherwise leave every chart empty — which looks exactly like a bug and
    /// gives no way back except guessing.
    private var liveSource: StatsSource {
        let offered = Derived.sourceOptions(store.transactions, store.banks)
        return offered.contains(source) ? source : .all
    }

    /// Every row this screen is about, before the period is applied.
    private var sourced: [Transaction] { Derived.bySource(store.transactions, liveSource) }

    private var months: [MonthKey] { Derived.months(sourced) }
    private var current: MonthKey { months.last ?? MonthKey(Date()) }
    /// The dataset is frozen and ends in the past, so "this week" must mean the
    /// last week that HAS data — anchoring on Date() shows seven empty bars.
    ///
    /// Read from `sourced`, not from everything: scoping to a bank whose newest
    /// row is older than another's would otherwise anchor «Тиждень» on a week
    /// that bank has no rows in, and show seven empty bars for exactly the
    /// reason this property exists to avoid.
    private var anchor: Date { sourced.map(\.date).max() ?? Date() }

    /// The period this screen is currently summing, as ONE value.
    ///
    /// Defined once and used twice — to compute `scoped` (what the total,
    /// the donut and the share list are all drawn from) and as the payload
    /// of the «За чеками» drill route. That is the whole point: the drill
    /// re-applies the very window that produced the slice, so "what the
    /// drill lists" and "what the slice summed" cannot drift apart. They
    /// did: the drill used to carry `scope == .month ? current : nil`, and
    /// nil at the far end meant the WHOLE dataset — so a tap on a slice in
    /// «Тиждень» opened all 772 rows of all eight months.
    ///
    /// nil in «Рік» because «Рік» genuinely is the whole dataset here
    /// (`scoped` was `store.transactions` before this too) — the same
    /// meaning `Derived.inWindow` gives nil, not a second one.
    private var window: Derived.DateWindow? {
        switch scope {
        case .week:  return Derived.DateWindow(weekEndingAt: anchor)
        case .month: return Derived.DateWindow(current)
        case .year:  return nil
        }
    }

    private var scoped: [Transaction] { Derived.inWindow(sourced, window) }

    /// Has anybody ever confirmed a receipt? Board #24.
    ///
    /// `byProductGroup` files every UNSPLIT purchase under «Без чека», so
    /// «За чеками» is not empty for a person with no receipts — it is a donut
    /// that is 100% «Без чека», which is the same lie board #20 took off
    /// Головна. The mode is not offered until there is something for it to
    /// slice, which is also what takes the second segmented control off the
    /// screen for everybody who has never scanned anything.
    ///
    /// Asked of the whole dataset, not of `scoped`: a picker that appeared and
    /// vanished as the period changed would be worse than either answer.
    private var hasReceiptData: Bool {
        store.transactions.contains { !$0.splits.isEmpty }
    }

    /// The mode actually in force. The stored flag alone is not enough — it
    /// can be true from a previous session while `hasReceiptData` is false.
    private var showingReceipts: Bool { bySplits && hasReceiptData }

    /// One computation, read by the donut and by the legend beneath it. They
    /// used to call this separately, and both take `prefix(8)` — so "the
    /// legend's n-th row is the donut's n-th arc" was true by coincidence.
    /// Board #24 keys colour to that index, which makes it load-bearing.
    private var slices: [Derived.CategorySlice] {
        showingReceipts ? Derived.byProductGroup(scoped) : Derived.byCategory(scoped)
    }

    /// What the ring and the legend both draw — board #83.
    ///
    /// One property rather than a `prefix(8)` written twice: the two used to
    /// take their own copy of the limit, which is how they could have come to
    /// disagree about what they were showing. Now the arcs and the rows are
    /// literally the same array, so the legend explains the ring by
    /// construction.
    private var ring: [Derived.CategorySlice] { Derived.ringSlices(slices) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    sourcePicker
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stats.scope")

                    if hasReceiptData {
                        Picker("", selection: $bySplits) {
                            Text("Загальна").tag(false)
                                .accessibilityIdentifier("stats.mode.general")
                            Text("За чеками").tag(true)
                                .accessibilityIdentifier("stats.mode.receipts")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("stats.mode")
                    }

                    if scope == .week { barsCard(Derived.dailyTotals(store.transactions, week: anchor)) }
                    if scope == .year { barsCard(Derived.monthlyTotals(store.transactions)) }
                    donutCard
                    shareListCard
                    fuelCard
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
            .background(Theme.bg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stats.title")
            // Board #115: on Статистика the swipe pages the SCOPE — Тиждень,
            // Місяць, Рік — not the tabs. That axis and not the mode picker:
            // it visibly changes which chart is drawn (daily bars, nothing,
            // monthly bars), it is always on screen where the mode picker
            // appears only with receipt data, and two swipe meanings on one
            // screen would be worse than none. INSIDE the stack for board
            // #63's reason: a pushed screen is not this view.
            .navigationTitle("Статистика")
            // `.navigationDestination(item:)` needs an Identifiable, and
            // String is not one — this is a value route over a Hashable
            // wrapper instead, which also carries the month the slice came from.
            .navigationDestination(for: CategoryDrill.self) { drill in
                FeedView(initialMonth: drill.month, initialCategory: drill.category,
                         initialSource: drill.source, embedded: true)
                    .navigationTitle(drill.category)
                    .navigationBarTitleDisplayMode(.inline)
            }
            // A second route type alongside `CategoryDrill` — `path` is an
            // untyped `NavigationPath`, so both activate regardless of which
            // one a given push carries. (A typed `[SomeType]` path would
            // silently ignore whichever route it was not declared with —
            // this repo has already shipped that as a dead-end drill-through
            // once.)
            .navigationDestination(for: ContributionDrill.self) { drill in
                ContributionsView(group: drill.group, window: drill.window,
                                  source: drill.source)
                    .navigationTitle(drill.group)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// **Whose numbers these are.** Board #101.
    ///
    /// A scrolling row of chips, not a `Menu` and not a third segmented
    /// control. The segmented control is out because the screen already stacks
    /// one or two, and this list grows with every bank and card a person
    /// connects — six segments is unreadable. A `Menu` was written first and
    /// removed: under XCUITest its label taps without opening, so the only
    /// end-to-end assertion available was that the control exists, which is
    /// the assertion that would still pass if the scope did nothing.
    ///
    /// Chips are what the feed already uses for exactly this shape, they are
    /// real buttons with real identifiers, and they scroll.
    ///
    /// Hidden entirely when there is nothing to choose — see `sourceOptions`.
    @ViewBuilder
    private var sourcePicker: some View {
        let options = Derived.sourceOptions(store.transactions, store.banks)
        if options.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let chosen = option == liveSource
                        Button { source = option } label: {
                            Text(verbatim: sourceLabel(option))
                                .font(Theme.font(14, .medium))
                                .foregroundStyle(chosen ? Theme.card : Theme.green)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(chosen ? Theme.green : Theme.greenWash,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("stats.source.\(Self.key(option))")
                    }
                }
                .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("stats.sources")
        }
    }

    /// A stable identifier for a scope. Built from ids and suffixes, which are
    /// data — so no seed value is written into source, and a UI test can find
    /// a chip by prefix without naming one.
    static func key(_ source: StatsSource) -> String {
        switch source {
        case .all: return "all"
        case .bank(let id): return "bank.\(id)"
        case .card(let id, let suffix): return "card.\(id).\(suffix)"
        }
    }

    private func sourceLabel(_ source: StatsSource) -> String {
        Self.sourceLabel(source, banks: store.banks, language: store.settings.languageChoice)
    }

    /// «Усі банки» is copy; a bank's name and a card's digits are the person's
    /// data. `BankMark` so this screen and the feed cannot name one bank two
    /// ways.
    ///
    /// **Board #165 — a disconnected bank is named as past.** The owner
    /// disconnected monobank and its name went on sitting in this row exactly
    /// as before, which read as the app not having registered the disconnect.
    /// The rows behind it are real: `sourceOptions` groups TRANSACTIONS by
    /// `bankId`, and board #157 keeps a bank's history when it goes unless the
    /// person asked for it to be removed too.
    ///
    /// So hiding the bank was rejected — its rows would still be counted in
    /// every total under «Усі банки» with no way left to filter to them, which
    /// trades one confusion for a worse one. The owner chose the mark
    /// (2026-08-31), and chose it on the BANK row only: a card already reads
    /// «monobank · 4321», and «monobank · відключено · 4321» is three marks
    /// fighting over two separators.
    ///
    /// A bank id that matches nothing in `banks` is left alone. `BankMark.bank`
    /// falls back to the raw id there, and that is a different state from
    /// disconnected — calling it disconnected would be inventing a fact.
    ///
    /// `static`, and not `private`, so the rule is unit-testable: this is copy
    /// assembled from data, which is the one thing a screenshot proves slowly
    /// and an assertion proves fast.
    static func sourceLabel(_ source: StatsSource,
                            banks: [Bank], language: AppLanguage) -> String {
        switch source {
        case .all:
            return L10n.t("Усі банки", language)
        case .bank(let id):
            let name = BankMark.bank(id, banks)
            guard banks.contains(where: { $0.id == id && !$0.connected }) else { return name }
            return "\(name) · \(L10n.t("відключено", language))"
        case .card(let id, let suffix):
            return "\(BankMark.bank(id, banks)) · \(suffix)"
        }
    }

    private func barsCard(_ bars: [Derived.Bar]) -> some View {
        let peak = max(1, bars.map(\.sum).max() ?? 1)
        return Card {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(bars) { bar in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.green.opacity(0.85))
                            .frame(height: max(2, 120 * Double(bar.sum) / Double(peak)))
                        Text(LocalizedStringKey(bar.label)).font(Theme.font(11)).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(height: 150, alignment: .bottom)
            .accessibilityIdentifier("stats.bars")
        }
    }

    /// The donut, with the period's total in the middle of it. Board #24 —
    /// there used to be a `totalCard` above this one, so the screen opened on
    /// two segmented controls and a big number before anything shaped like a
    /// statistic. The ring has a hole in it; the number the ring is a
    /// breakdown OF belongs in the hole.
    ///
    /// It is also what makes the zero state one card instead of two: the old
    /// pairing was «Витрачено 0 ₴» above «Витрат за цей період немає», which
    /// is the same sentence twice.
    private var donutCard: some View {
        Card {
            if store.transactions.isEmpty {
                // Distinct from "no spending this period" below: nothing has
                // synced yet at all, so there is nothing to count anywhere.
                //
                // Its OWN identifier, not the `stats.empty` the branch below
                // carries. Sharing one made `EmptyStateTests` unable to fail:
                // with no transactions `slices` is empty too, so deleting this
                // whole branch still rendered `stats.empty` — from the other
                // message — and the test stayed green.
                Text("Статистика з'явиться, коли буде що рахувати.")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("stats.empty.noData")
                SyncStatusView()
            } else if showingReceipts && !scopedHasReceipts {
                // The «За чеками» half of board #24's "gated or explained".
                // The mode is only offered once SOME receipt is confirmed —
                // but a period can still hold none of them, and the honest
                // answer is a sentence, not a donut that is 100% «Без чека».
                Text("За цей період немає підтверджених чеків.")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("stats.empty.noReceipts")
                Text("Розберіть чек у покупці — і побачите, з чого склалися витрати.")
                    .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
            } else if slices.isEmpty {
                Text("Витрат за цей період немає")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("stats.empty")
            } else {
                ZStack {
                  // Two nested ZStacks, and the nesting is load-bearing:
                  // `stats.donut` sits on a container holding ONLY the arcs.
                  // A bare identifier is stamped onto every descendant, so
                  // with the total inside the identified stack the total's own
                  // `stats.total` was smothered — five UI tests failed on
                  // «the screen never loaded», which is what that always looks
                  // like. The alternative, `.accessibilityElement(children:
                  // .contain)`, would also work; keeping the identifier off
                  // the shared parent needs no such reasoning.
                  ZStack {
                    ForEach(Array(ring.enumerated()), id: \.element.id) { index, slice in
                        let s = start(ring, index)
                        let gap = 0.004
                        // The gap is cut into the trim, not into a uniform
                        // `.padding` on the frame — padding insets every slice
                        // onto the same circle, so adjacent arcs stay exactly
                        // contiguous and never actually separate. Guarding
                        // `share > gap` keeps a hairline slice from inverting
                        // (from > to). It used to be load-bearing for a second
                        // reason — two neighbours could hash to the same wash
                        // — which board #24 removed by colouring these by
                        // RANK; it stays because touching arcs of ANY two
                        // colours read better with a hairline between them.
                        Circle()
                            .trim(from: slice.share > gap ? s + gap / 2 : s,
                                  to: slice.share > gap ? s + slice.share - gap / 2 : s + slice.share)
                            .stroke(Theme.rank(index), lineWidth: 34)
                    }
                    .rotationEffect(.degrees(-90))
                  }
                  .accessibilityIdentifier("stats.donut")

                    VStack(spacing: 2) {
                        Text("Витрачено")
                            .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        Text(Derived.totals(scoped).spent.uah)
                            .font(Theme.font(26, .bold)).foregroundStyle(Theme.ink)
                            // The hole is ~132pt across and a year's spend can
                            // be seven figures; shrinking beats truncating the
                            // one number this screen exists to show.
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .accessibilityIdentifier("stats.total")
                    }
                    .padding(.horizontal, 40)
                }
                // `maxWidth`, not just a height (board #59). `Card` is a
                // leading-aligned `VStack`, and a stack given only a height
                // sizes to its content — so the ring sat against the left edge
                // of a full-width card, off centre from everything above and
                // below it. Filling the width lets the ZStack centre it.
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            }
        }
    }

    /// Does anything in the CURRENT period carry a confirmed split?
    private var scopedHasReceipts: Bool { scoped.contains { !$0.splits.isEmpty } }

    private func start(_ slices: [Derived.CategorySlice], _ index: Int) -> Double {
        slices.prefix(index).reduce(0) { $0 + $1.share }
    }

    @ViewBuilder
    private var shareListCard: some View {
        // Nothing to list under an empty donut — an empty white `Card` would
        // otherwise render directly beneath `stats.empty`. Also nothing to
        // list beside the «no receipts this period» explanation, which the
        // donut card shows INSTEAD of a ring: `slices` is not empty there
        // («Без чека» fills it), so the emptiness test alone is not enough.
        if !slices.isEmpty, !(showingReceipts && !scopedHasReceipts) {
            Card {
                // `enumerated()`, and the same `prefix(8)` the donut takes:
                // the swatch is the arc's colour because it is the arc's
                // INDEX, not because two hashes happened to agree.
                ForEach(Array(ring.enumerated()), id: \.element.id) { index, slice in
                    // The everything-else arc opens nothing. It stands for
                    // several categories at once, and `CategoryDrill` takes
                    // one — a button that pushed a feed filtered to a
                    // category called «Решта» would open an empty screen.
                    if slice.isAggregate {
                        restRow(slice, index: index)
                    } else {
                    Button {
                        if showingReceipts {
                            // The window this screen just summed, not a
                            // month — see `window`.
                            path.append(ContributionDrill(group: slice.name, window: window,
                                                          source: liveSource))
                        } else {
                            // `CategoryDrill` still carries a month: it opens
                            // `FeedView`, which is a month browser with its
                            // own stepper and has no way to show a week.
                            path.append(CategoryDrill(source: liveSource,
                                                      category: slice.name,
                                                      month: scope == .month ? current : nil))
                        }
                    } label: {
                        HStack(spacing: 12) {
                            // The legend swatch carries the category's icon
                            // (board #61's set), on the RANK colour rather
                            // than the category's own wash.
                            //
                            // **Deliberately not a `CategorySwatch`.** That
                            // view answers "which category is this" and
                            // colours itself accordingly; this screen's
                            // question is "which slice is this", which is
                            // positional — the swatch has to match the arc
                            // beside it, and `StatsColourTests` is what keeps
                            // those two schemes apart. The icon is the part
                            // that names the category, and it works here for
                            // the same reason it does there: at eight slices
                            // colour alone is thin, and it is thinner still
                            // for a colourblind reader.
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.rank(index)).frame(width: 22, height: 22)
                                .overlay {
                                    Image(systemName: store.iconName(for: slice.name))
                                        .font(.system(size: 11, weight: .semibold))
                                        // White, not `Theme.swatchInk`: a rank
                                        // colour is a saturated arc colour,
                                        // not one of the pale washes the dark
                                        // ink was measured against.
                                        .foregroundStyle(.white)
                                }
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(slice.name)).font(Theme.font(16)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int((slice.share * 100).rounded()))%")
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                            Text(slice.sum.uah).font(Theme.font(16, .semibold))
                                .foregroundStyle(Theme.ink).fixedSize()
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stats.slice.\(slice.name)")
                    }
                }
            }
        }
    }

    /// The everything-else row: the same swatch, colour and figures as any
    /// other, and no chevron, no tap, no icon of its own.
    ///
    /// `list.bullet` rather than a category glyph, because it is not a
    /// category — `store.iconName(for:)` would hand back the `tag` fallback
    /// for a name it has never seen, which is the icon an unrecognised
    /// category gets and would say the wrong thing.
    private func restRow(_ slice: Derived.CategorySlice, index: Int) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.rank(index)).frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text(LocalizedStringKey(slice.name)).font(Theme.font(16))
                .foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int((slice.share * 100).rounded()))%")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
            Text(slice.sum.uah).font(Theme.font(16, .semibold))
                .foregroundStyle(Theme.ink).fixedSize()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stats.slice.rest")
    }

    /// Read straight off receipt items via `scoped` — the same period the
    /// rest of the screen already answers to — but independent of `bySplits`:
    /// a fill-up needs an ATTACHED receipt, never a CONFIRMED split, so it
    /// renders identically in «Загальна» and «За чеками». `fuelSummary`
    /// returning nil (an empty `fills`) IS the "hide this card" signal — an
    /// empty Заправки card on a month with no driving would be noise, not
    /// information, so nothing renders rather than a zeroed-out card.
    @ViewBuilder
    private var fuelCard: some View {
        let fills = Derived.fillUps(scoped, receipts: store.receipts)
        if let summary = Derived.fuelSummary(fills) {
            Card {
                Text("Заправки").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                // «10 л · 800,00 ₴ · середня 80,00 ₴/л» — the one line this
                // card exists to answer at a glance.
                Text("\(ReceiptItemsView.qty(summary.litres)) л · \(summary.total.uahExact) · середня \(summary.averagePerLitre.uahExact)/л")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                    .accessibilityIdentifier("stats.fuel.summary")
                ForEach(Array(fills.enumerated()), id: \.element.id) { index, fill in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            // The row's own identity — the grade, not the
                            // station — mirroring `stats.contribution.<index>`
                            // sitting on the PRODUCT name one card over.
                            Text(fill.grade)
                                .font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .accessibilityIdentifier("stats.fuel.row.\(index)")
                            Text("\(fill.station) · \(ContributionsView.dateTitle(fill.date))")
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(fill.total.uahExact)
                                .font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                                .fixedSize()
                            Text("\(ReceiptItemsView.qty(fill.litres)) л · \(fill.pricePerLitre.uahExact)/л")
                                .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                                .fixedSize()
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }
}

extension StatsView {
    /// The rows within the seven Kyiv days ending on `anchor`, by Kyiv DAY —
    /// not by instant. An instant window (`anchor - 7 × 24h`) admits part of
    /// an eighth day, which the bars do not draw. Reads off
    /// `Derived.DateWindow`, the same window `Derived.dailyTotals` buckets,
    /// so a stats screen whose total disagrees with the bars under it by a
    /// partial day can't happen. Stays here as the name the tests and the
    /// rest of this file already use.
    static func weekRows(_ txs: [Transaction], endingAt anchor: Date) -> [Transaction] {
        Derived.inWindow(txs, Derived.DateWindow(weekEndingAt: anchor))
    }
}
