import SwiftUI

struct FeedView: View {
    @Environment(AppStore.self) private var store
    @State private var month: MonthKey?
    @State private var query = ""
    @State private var path: [Transaction] = []
    @State private var filter = FeedFilter()
    @State private var showFilters = false
    @State private var showMonths = false
    private let initialCategory: String?
    private let initialSource: StatsSource
    private let embedded: Bool

    init(initialMonth: MonthKey? = nil, initialCategory: String? = nil,
         initialSource: StatsSource = .all, embedded: Bool = false) {
        _month = State(initialValue: initialMonth)
        self.initialCategory = initialCategory
        self.initialSource = initialSource
        self.embedded = embedded
    }

    private var months: [MonthKey] { Derived.months(store.transactions) }
    /// Defaults to the newest month that actually has data — not "today",
    /// which on this frozen dataset would be an empty screen.
    private var current: MonthKey { month ?? months.last ?? MonthKey(Date()) }

    /// Everything the feed is narrowed by **except** the month cut — board
    /// #109. The month sheet sums these per month, so the number a row promises
    /// and the number the feed then shows cannot disagree: filters, source,
    /// category and search are all already applied to both.
    ///
    /// Splitting the month out reorders nothing that matters: all five are
    /// row-wise predicates.
    private var unmonthed: [Transaction] {
        var rows = store.transactions
        if let category = initialCategory { rows = rows.filter { $0.category == category } }
        rows = Derived.bySource(rows, initialSource)
        rows = Derived.apply(filter, to: rows)
        return Derived.search(rows, query)
    }

    private var rows: [Transaction] { Derived.inMonth(unmonthed, current) }

    var body: some View {
        // Embedded (pushed from the stats donut) it must NOT open a stack of
        // its own: two nested NavigationStacks give you two navigation bars,
        // a back button that dismisses the wrong level, and a toolbar that
        // silently stops appearing.
        if embedded { content } else { NavigationStack(path: $path) { content } }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            chipBar
            countLine
            Group {
                if store.transactions.isEmpty {
                    // Nothing has synced yet — distinct from "no matches for
                    // this search", which the branch below still owns once
                    // there is real data to search through. A `ScrollView`,
                    // not a bare `VStack`: this is the one screen where a
                    // stalled sync is most worth nudging by hand, so it needs
                    // somewhere for `.refreshable` to attach — a plain VStack
                    // has nothing to pull against. `.containerRelativeFrame`
                    // gives the content the scroll view's own height so the
                    // spacers still centre the card exactly as before.
                    ScrollView {
                        VStack {
                            Spacer()
                            Card {
                                // Its OWN identifier, not the `feed.empty` the
                                // search-found-nothing branch below carries.
                                // Sharing one made `EmptyStateTests` unable to
                                // fail: with no transactions `rows` is empty
                                // too, so deleting this whole branch still
                                // rendered `feed.empty` — from the other
                                // message — and the test stayed green.
                                // `FeedTests` and `StatsAndSettingsTests` keep
                                // querying `feed.empty` for the other branch.
                                Text("Тут з'являться ваші покупки, щойно банк їх віддасть.")
                                    .font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                                    .accessibilityIdentifier("feed.empty.noData")
                                SyncStatusView()
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .containerRelativeFrame(.vertical)
                    }
                    .refreshable {
                        // ONE window, at most 61 s — which is what a manual pull means.
                        // `.max` pinned the spinner above the list for the whole backfill
                        // (~23 paced windows on «12 місяців» × 2 cards, so ~23 minutes), and
                        // `.refreshable`'s task belongs to the view: switching tabs or
                        // opening a purchase cancels it, and `run` tears the whole backfill
                        // down mid-flight. The long backfill belongs to the Task started
                        // after onboarding, which no view owns.
                        await store.startSync(maxSteps: 1)
                        // The independent second source — never instead of the
                        // line above, since a person can have either connected,
                        // both, or neither. Same gated call the scene-phase
                        // handler and the background wake use, so a
                        // pull-to-refresh never bypasses the fixture guard
                        // those triggers already respect.
                        await store.syncPrivatEmailIfConnected()
                    }
                } else if rows.isEmpty {
                    VStack(spacing: 10) {
                        Text("Нічого не знайдено")
                            .font(Theme.font(20, .semibold)).foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("feed.empty")
                        Text("Спробуйте інший місяць або інший запит.")
                            .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(Derived.days(rows)) { section in
                                Section {
                                    ForEach(section.rows) { tx in
                                        NavigationLink(value: tx) {
                                            TransactionRow(tx, showsReceiptDisclosure: true)
                                        }
                                            .buttonStyle(.plain)
                                            .accessibilityIdentifier("feed.row.\(tx.id.uuidString)")
                                    }
                                } header: {
                                    Text(Self.dayTitle(section.day))
                                        .font(Theme.font(14, .semibold)).foregroundStyle(Theme.inkMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20).padding(.vertical, 8)
                                        .background(Theme.bg)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .refreshable {
                        // ONE window, at most 61 s — which is what a manual pull means.
                        // `.max` pinned the spinner above the list for the whole backfill
                        // (~23 paced windows on «12 місяців» × 2 cards, so ~23 minutes), and
                        // `.refreshable`'s task belongs to the view: switching tabs or
                        // opening a purchase cancels it, and `run` tears the whole backfill
                        // down mid-flight. The long backfill belongs to the Task started
                        // after onboarding, which no view owns.
                        await store.startSync(maxSteps: 1)
                        // The independent second source — never instead of the
                        // line above, since a person can have either connected,
                        // both, or neither. Same gated call the scene-phase
                        // handler and the background wake use, so a
                        // pull-to-refresh never bypasses the fixture guard
                        // those triggers already respect.
                        await store.syncPrivatEmailIfConnected()
                    }
                }
            }
            .background(Theme.bg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("feed.title")
            // Board #131: the swipe changes TAB here, as it does everywhere.
            // Board #115 had given it to the months; the owner's verdict on a
            // phone was «Now I can't swipe from statistics to budget» — two
            // tabs behaving differently from the other three reads as broken.
            // The months keep their chevrons and the month sheet, which is
            // what #109 built them for.
            //
            // `enabled: !embedded` because the embedded feed is a PUSHED
            // screen showing one category of one month, and changing tabs from
            // a pushed screen is exactly what board #63 put this gesture
            // inside each stack to prevent. INSIDE the stack for that same
            // reason: a pushed screen is not this view, so the gesture is not
            // there to compete with its swipe actions or its back edge.
            .searchable(text: $query, prompt: "Продавець або категорія")
            .navigationDestination(for: Transaction.self) { TransactionDetailView(id: $0.id) }
            .sheet(isPresented: $showFilters) {
                // Board #110: the month's rows UNFILTERED. The sheet's «Без
                // чека» count is a to-do, and one that moved as you changed
                // the filters would not be.
                FeedFilterSheet(filter: $filter,
                                monthRows: Derived.inMonth(store.transactions, current))
            }
            .sheet(isPresented: $showMonths) {
                FeedMonthSheet(rows: Derived.monthRows(store.transactions, matching: unmonthed),
                               current: current) { month = $0 }
            }
            .toolbar {
                // An embedded feed is already titled by its pusher and cannot
                // change month — it is showing one category of one month.
                if !embedded {
                    ToolbarItem(placement: .principal) { monthStepper }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(filter.isEmpty ? Theme.inkSoft : Theme.green)
                    }
                    .accessibilityIdentifier("feed.filter")
                }
            }
        }
    }

    /// A deterministic figure a test can assert on. Counting rows the
    /// ScrollView happened to render is not — a lazy container only
    /// materialises what is on screen, so the number stays here rather than
    /// being derived from the accessibility tree.
    private var countLine: some View {
        // Bound to `String` locals on purpose. `.accessibilityValue("\(n)")`
        // takes the `LocalizedStringKey` overload, which **groups the digits**
        // — «1 234 500», with a non-breaking space — so `Int(value)` in a test
        // comes back nil. Three digits never group, which is why `feed.count`
        // has quietly had this since it was written and no test ever saw it:
        // a month with a thousand rows would have broken four of them at once.
        // A `String` variable selects the verbatim overload.
        let count = String(rows.count)
        let spent = String(Derived.totals(rows).spent)
        return HStack(spacing: 6) {
            Text(Plural.operations(rows.count, store.settings.languageChoice))
                .accessibilityIdentifier("feed.count")
                // The raw number as the value, so a test asserts on arithmetic
                // rather than on Ukrainian copy the owner will keep rewording.
                .accessibilityValue(count)
            // Board #109: the feed said how many and never how much, so
            // "totals reflect the chosen month" was a claim about a total that
            // did not exist.
            //
            // LABELLED «витрати», not a bare figure. Under a filter that keeps
            // only income the spending is genuinely zero, and an unlabelled
            // «0 ₴» beside twelve rows reads as a broken number rather than an
            // accurate one.
            Text(verbatim: "·").accessibilityHidden(true)
            Text("витрати \(Derived.totals(rows).spent.uahExact)")
                .accessibilityIdentifier("feed.total")
                // Minor units, for the same reason the count is raw.
                .accessibilityValue(spent)
            Spacer(minLength: 0)
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// Board #109. Stepped away from the newest month, which is the one the
    /// feed opens on — so there is a way back to offer.
    private var isAwayFromNewest: Bool {
        guard let newest = months.last else { return false }
        return current != newest
    }

    @ViewBuilder
    private var chipBar: some View {
        // A month away from the newest IS a narrowing, so the bar that exists
        // to say "you have narrowed something, here is the way back" is where
        // the way back belongs.
        if !filter.isEmpty || isAwayFromNewest {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // First, because it is the one control here that is not
                    // about the filters — and because with no filters set it is
                    // the only thing in the bar.
                    //
                    // Deliberately NOT folded into «Скинути все». That button
                    // means "clear the filters", three UI tests assert exactly
                    // that, and widening it would change what a green test is
                    // checking without any of them going red.
                    if isAwayFromNewest {
                        // A capsule with an arrow, not bare green text. Looked
                        // at on a simulator, bare text sat directly above
                        // «103 операції · витрати …» and read as a HEADING for
                        // that line — which made it a false one: the month on
                        // screen was липень. A capsule with a return arrow can
                        // only be read as something to press.
                        Button { month = months.last } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.uturn.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Цей місяць").font(Theme.font(14, .semibold))
                            }
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.greenWash, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("feed.thisMonth")
                    }
                    ForEach(filter.chips(store.banks, store.settings.languageChoice),
                            id: \.self) { chip in
                        // A card suffix, a category name or a bank's own name —
                        // the person's data. The one chip that IS copy, the
                        // transaction kind, is translated inside `chips` before
                        // it gets here; it used to arrive in Ukrainian and be
                        // drawn faithfully, beside a sheet that said "Spending".
                        Text(verbatim: chip)
                            .font(Theme.font(14, .medium)).foregroundStyle(Theme.green)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.greenWash, in: Capsule())
                    }
                    // Gated now that the bar can appear for a month alone:
                    // «Скинути все» with no filter set is a control that
                    // resets nothing, on a bar that says something is set.
                    if !filter.isEmpty {
                        Button("Скинути все") { filter = FeedFilter() }
                            .font(Theme.font(14, .semibold)).foregroundStyle(Theme.clay)
                            .accessibilityIdentifier("feed.filter.clearAll")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
    }

    private var monthStepper: some View {
        HStack(spacing: 14) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(months.first == nil || current <= months.first!)
                .accessibilityIdentifier("feed.prevMonth")
            // Board #109: the title is the control now. It kept `feed.month`
            // rather than taking a new identifier — this IS the month control,
            // and a second name for it would leave two things to keep in step.
            // A `Button` merges its label, so the three UI tests that read
            // `app.staticTexts["feed.month"]` moved to `app.buttons`; the label
            // they compare is unchanged.
            Button { showMonths = true } label: {
                Text(current.title)
                    .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feed.month")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(months.last == nil || current >= months.last!)
                .accessibilityIdentifier("feed.nextMonth")
        }
        .tint(Theme.green)
    }

    private func step(_ delta: Int) {
        guard let next = Self.steppedMonth(months, from: current, by: delta) else { return }
        month = next
    }

    /// Steps through the months that HAVE data rather than by calendar
    /// arithmetic — a gap month would otherwise strand the user on an empty
    /// screen with no clue which way to go. `nil` at either end: **the ends do
    /// not wrap**, the same rule the tab swipe follows and for the same reason.
    ///
    /// A static with no defaulted parameters because board #115 made a swipe
    /// drive it too, and a gesture's effect must be provable without a device
    /// even though its feel cannot be.
    static func steppedMonth(_ months: [MonthKey], from: MonthKey, by delta: Int) -> MonthKey? {
        guard let i = months.firstIndex(of: from) else { return nil }
        let next = i + delta
        guard months.indices.contains(next) else { return nil }
        return months[next]
    }

    /// Board #105: cached. `QueueView.countText` calls this once per
    /// generic-merchant card, and the demo queue has 35 of them.
    static func dayTitle(_ day: Date) -> String { KyivFormat.string(day, "d MMMM") }
}

/// A push from the stats donut into the feed, narrowed to one category and
/// optionally one month. A Hashable value rather than a String so it can be a
/// `navigationDestination(for:)` route and carry the month with it.
struct CategoryDrill: Hashable {
    /// Board #101. The drill re-applies the SOURCE that produced the slice for
    /// the same reason it already re-applies the window: otherwise a tap on a
    /// slice of «ПриватБанк» opens a list with monobank's rows in it, and the
    /// number the person tapped stops explaining the list they got.
    var source: StatsSource = .all
    var category: String
    var month: MonthKey?
}

/// One feed row. Shared with search results and, later, receipt matching, so
/// the amount column never disagrees between screens.
///
/// Task 8: a row whose transaction carries a `receiptId` gains a disclosure
/// that expands the row in place to show `ReceiptItemsView`. Per D6 `expanded`
/// is plain `@State` here — nothing about it is persisted, so the row folds
/// back up the moment it leaves the tree (a scroll recycling it, a re-launch).
///
/// Opt-in, and only the feed opts in. The reason used to be «QueueView's
/// skipped list wraps this row in a Button» — a list board #26 established
/// had never existed in the UI at all. The rule survives its stale
/// justification: any caller that wraps this row in a Button would nest a
/// Button inside a Button, and would leak `feed.expand.<uuid>` onto whatever
/// screen it did that on.
struct TransactionRow: View {
    @Environment(AppStore.self) private var store
    @State private var expanded = false
    let tx: Transaction
    let showsReceiptDisclosure: Bool
    init(_ tx: Transaction, showsReceiptDisclosure: Bool = false) {
        self.tx = tx
        self.showsReceiptDisclosure = showsReceiptDisclosure
    }

    private var receipt: Receipt? { store.receipt(for: tx) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                CategorySwatch(tx.category, size: 40, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tx.merchant).font(Theme.font(16, .semibold))
                        .foregroundStyle(tx.kind == .transfer ? Theme.inkMuted : Theme.ink)
                        .lineLimit(1)
                    // `verbatim:` — board #96. Interpolating into a `Text`
                    // literal takes the LocalizedStringKey overload and sends
                    // the whole composed line to the catalogue as a key. Both
                    // halves are already what they should be: a category name
                    // is the person's data, and `categoryLabel` has just
                    // localised its own placeholder.
                    Text(verbatim: "\(Derived.categoryLabel(tx, store.settings.languageChoice))"
                         + " · \(Self.time(tx.date))")
                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                // The amount never wraps and never shrinks — it is the column the
                // eye scans down; the merchant line yields.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tx.amount.signedUahExact)
                        .fixedSize()
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(amountColour)
                    // Board #98: which bank, and which card. It goes UNDER the
                    // amount rather than into the subtitle line because that
                    // line is already `lineLimit(1)` over a category and a
                    // time — appending here would put the mark in exactly the
                    // place a long category truncates away.
                    //
                    // `verbatim`: a bank's name and a card's digits are data.
                    Text(verbatim: BankMark.line(tx, store.banks))
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .accessibilityIdentifier("feed.mark.\(tx.id.uuidString)")
                }
                // Only a row with a receipt gets a disclosure at all — never
                // one for every row regardless of `receiptId` (that would make
                // the control look live on rows with nothing behind it).
                if showsReceiptDisclosure, tx.receiptId != nil {
                    // A REAL nested `Button`, not a second tap gesture on the
                    // same shape: within a `NavigationLink`'s label, SwiftUI
                    // hands a tap to the innermost control whose frame
                    // contains it, so this toggles expansion and nothing
                    // navigates. Sharing one shape with the row instead would
                    // make expansion unreachable while still compiling clean.
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Keyed by the transaction's own id, like `feed.row.…`
                    // above it — not by the receipt's — so the three
                    // identifiers for one row always share one uuid.
                    .accessibilityIdentifier("feed.expand.\(tx.id.uuidString)")
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 64)
            .contentShape(Rectangle())

            if expanded, let receipt {
                VStack(alignment: .leading, spacing: 8) {
                    // The seller, then one line per item (spec). The row's own
                    // merchant line above is bank-statement text and is
                    // frequently not what the shop calls itself, so a bare list
                    // of goods leaves the owner without the one name that says
                    // where they were. Same copy as the detail card.
                    //
                    // `feed.items.<uuid>` lives HERE, on this leaf `Text`, not
                    // on the `VStack` that wraps it. It used to sit on that
                    // wrapper — a bare `.accessibilityIdentifier` with no
                    // `.accessibilityElement` of its own — on the theory that a
                    // container identifier is harmless to its descendants.
                    // It is not: a bare identifier on a container STAMPS THAT
                    // SAME STRING onto every descendant beneath it, overwriting
                    // whatever identifier each one carried. `ReceiptItemsView`'s
                    // own `receipt.item.group.<itemId>` and `receipt.confirm`
                    // buttons were unreachable by their own identifiers while
                    // nested under it — confirmed live with
                    // `app.debugDescription`, which showed both buttons
                    // reporting `identifier: 'feed.items.<uuid>'` instead of
                    // their own. Labels survived (nothing here merges elements
                    // into one), which is why earlier assertions that matched
                    // by label never caught it. Moving the identifier onto this
                    // `Text` — present only once expanded, exactly the
                    // absent-before/present-after behaviour the two existing
                    // consumers (`ReceiptTests`, `SplitTests`) already rely on
                    // via `app.marker`, which searches the whole tree by
                    // identifier and does not care which element carries it —
                    // fixes the shadowing without needing a second synthesised
                    // `.contain` container, which `feed.title` above already
                    // has one of, and which a `.contain` nested inside another
                    // `.contain` drops entirely. Leave this on the leaf.
                    Text(receipt.displaySeller)
                        .font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("feed.items.\(tx.id.uuidString)")
                    ReceiptItemsView(receipt: receipt, editable: true)
                }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        }
    }

    private var amountColour: Color {
        switch tx.kind {
        case .transfer: return Theme.inkMuted   // muted: the money never left
        case .income: return Theme.green
        case .expense: return Theme.ink
        }
    }

    /// Board #105: cached. This is per ROW, on a list of 114.
    static func time(_ date: Date) -> String { KyivFormat.string(date, "HH:mm") }
}
