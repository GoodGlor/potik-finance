import Foundation

/// Every figure any screen shows is computed here, from `[Transaction]` and
/// nothing else. Pure functions, no SwiftUI, no store — so the arithmetic is
/// unit-tested in milliseconds instead of through a five-minute UI suite.
///
/// Transfers between the owner's own cards are excluded from every total on
/// purpose: the money never left. So is an expense in `savingsCategory`, for
/// the same reason in a different shape — see `totals`. Both still appear in
/// the feed; a transfer is muted there.
enum Derived {

    struct MonthTotals: Equatable {
        var spent: Int    // magnitude, always >= 0
        var income: Int   // magnitude, always >= 0
    }

    struct CategorySlice: Identifiable, Equatable {
        var name: String
        var sum: Int          // magnitude
        var share: Double     // of total spend, 0...1

        /// The everything-else arc, board #83 — not a category anybody has.
        ///
        /// It exists because a slice cannot be drilled into if it stands for
        /// several categories at once, and because `id` must not collide with
        /// a real category that happens to share its name: a person can rename
        /// one to «Решта», and two rows under one id make SwiftUI's `ForEach`
        /// draw one of them.
        var isAggregate: Bool = false

        var id: String { isAggregate ? "\u{0}rest" : name }
    }

    /// The label on the everything-else arc.
    ///
    /// **Not «Інше».** The seed ships a real category by that name, so an
    /// aggregate arc wearing it would put two different things under one label
    /// in the legend — the trap board #83 names. «Решта» is not a category the
    /// app creates, and `isAggregate` above keeps the two apart even if
    /// somebody renames one to it.
    static let restOfTheRing = "Решта"

    /// The slices a ring can actually draw, with everything past the palette
    /// folded into one arc.
    ///
    /// `StatsView` drew `prefix(8)` and dropped the rest, so the ring had a
    /// visible unfilled remainder — 8.5% across the demo seed's fifteen
    /// categories, and about a tenth of the circle in a single month. Board
    /// #57 made it worse: the middle is occupied and each category now has its
    /// own colour, so the gap reads as missing data rather than as styling.
    ///
    /// **Seven and a tail, not eight and a ninth arc.** `Theme.rank` offers
    /// eight colours and wraps, so a ninth would repeat the largest slice's
    /// own colour; and slate, the eighth, is already documented as the one
    /// "for the smallest". Folding into the last slot closes the ring without
    /// a new colour to justify against `StatsColourTests`' separation floors.
    ///
    /// Nine or more is the only case that folds. Exactly eight fits.
    static func ringSlices(_ slices: [CategorySlice], limit: Int = 8) -> [CategorySlice] {
        guard slices.count > limit else { return slices }
        let head = Array(slices.prefix(limit - 1))
        let tail = slices.dropFirst(limit - 1)
        return head + [CategorySlice(name: restOfTheRing,
                                     sum: tail.reduce(0) { $0 + $1.sum },
                                     // Summed, not `1 - head`: the shares are
                                     // already rounded off a ratio, and
                                     // subtracting would hand the arc every
                                     // rounding error the other seven made.
                                     share: tail.reduce(0) { $0 + $1.share },
                                     isAggregate: true)]
    }

    struct DaySection: Identifiable, Equatable {
        var day: Date         // start of the Kyiv day
        var rows: [Transaction]
        var id: Date { day }
    }

    // MARK: months

    /// Every Kyiv month the data touches, oldest first.
    static func months(_ txs: [Transaction]) -> [MonthKey] {
        Array(Set(txs.map { MonthKey($0.date) })).sorted()
    }

    static func inMonth(_ txs: [Transaction], _ month: MonthKey) -> [Transaction] {
        txs.filter { month.contains($0.date) }
    }

    /// One month, as a month picker reads it — board #109.
    struct MonthRow: Identifiable, Equatable {
        var month: MonthKey
        var count: Int
        var spent: Int        // magnitude, the same figure `totals` computes
        var id: MonthKey { month }
    }

    /// Every month the data touches, **newest first** — a picker's order, which
    /// is the reverse of `months`.
    ///
    /// **Two sets, and they are deliberately not the same one.** `all` decides
    /// which months are listed; `matching` decides their numbers. A filter that
    /// empties a month must still leave that month in the list, or the list
    /// reshuffles as you filter and — worse — the month currently on screen can
    /// vanish from the picker with no way back to it.
    ///
    /// Neither parameter has a default, so no call site can silently pass one
    /// set for both and get a picker that quietly hides months.
    static func monthRows(_ all: [Transaction], matching: [Transaction]) -> [MonthRow] {
        let grouped = Dictionary(grouping: matching) { MonthKey($0.date) }
        return months(all).reversed().map { month in
            let rows = grouped[month, default: []]
            return MonthRow(month: month, count: rows.count, spent: totals(rows).spent)
        }
    }

    // MARK: periods

    /// A half-open span of Kyiv DAYS, `start ..< end` — the period a screen
    /// is currently summing, as a value it can hand to another screen.
    ///
    /// It exists because a period is not always a month. `StatsView` offers
    /// «Тиждень» / «Місяць» / «Рік», and a drill-through that carried only an
    /// optional `MonthKey` could not say "this week" at all: it said nil, and
    /// nil at the far end meant "everything, all eight months", so tapping a
    /// slice showing one week's spend opened a list whose total bore no
    /// relation to it. Carrying the window instead makes the drill's rows the
    /// slice's rows by construction.
    ///
    /// By DAY, not by instant: an instant window (`anchor − 7 × 24h`) admits
    /// part of an eighth day, which the bars under the donut do not draw.
    struct DateWindow: Hashable {
        var start: Date
        var end: Date

        /// The whole of one Kyiv month.
        init(_ month: MonthKey) {
            start = month.start
            end = month.advanced(by: 1).start
        }

        /// The seven Kyiv days ending on `anchor`'s day — the SAME window
        /// `dailyTotals` buckets into bars.
        init(weekEndingAt anchor: Date) {
            let lastDay = Calendar.kyiv.startOfDay(for: anchor)
            start = Calendar.kyiv.date(byAdding: .day, value: -6, to: lastDay)!
            end = Calendar.kyiv.date(byAdding: .day, value: 1, to: lastDay)!
        }

        func contains(_ date: Date) -> Bool {
            let day = Calendar.kyiv.startOfDay(for: date)
            return day >= start && day < end
        }
    }

    /// nil means NO period filter — the whole dataset. So the scope that
    /// shows everything and the scopes that show a period both run through
    /// one function, and a caller that carries the window around cannot
    /// accidentally mean two different things by "no value".
    static func inWindow(_ txs: [Transaction], _ window: DateWindow?) -> [Transaction] {
        guard let window else { return txs }
        return txs.filter { window.contains($0.date) }
    }

    // MARK: totals

    /// Money the owner still has is not spending, however it was recorded.
    ///
    /// A jar top-up can reach this function two ways: as a `.transfer`, which
    /// has always been skipped, or — since board #6 narrowed «Це не витрата»
    /// to own-card transfers — as an `.expense` in «Заощадження», which is the
    /// answer the picker now steers a person to. Counting the second as spent
    /// would be worse than the old behaviour, not better: the budget's savings
    /// line is `income - spent`, so every hryvnia moved into a jar would both
    /// inflate spending AND subtract itself from the savings it is. The two
    /// recordings must produce identical numbers, and
    /// `SavingsIsNotSpendingTests` is the test that says so.
    static func totals(_ txs: [Transaction]) -> MonthTotals {
        var spent = 0, income = 0
        for tx in txs {
            switch tx.kind {
            case .expense where isSetAside(tx): break
            case .expense: spent += abs(tx.amount)
            case .income: income += abs(tx.amount)
            case .transfer: break
            }
        }
        return MonthTotals(spent: spent, income: income)
    }

    /// Money put aside rather than spent. One predicate, so `totals` and
    /// `byCategory` cannot disagree about which rows are spending — a split
    /// between them would show Статистика a slice whose ₴ are missing from the
    /// total printed directly above it.
    static func isSetAside(_ tx: Transaction) -> Bool {
        tx.category == BudgetMath.savingsCategory
    }

    // MARK: breakdown

    /// Spending only, largest first. An empty result (all income, or nothing)
    /// is returned rather than a zero-share list, so callers show their empty
    /// state instead of dividing by zero.
    static func byCategory(_ txs: [Transaction]) -> [CategorySlice] {
        var sums: [String: Int] = [:]
        // `isSetAside` for the same reason `totals` applies it: a savings slice
        // here would be a share of a total that never included it, and the
        // budget's «не заплановано» list would invite a person to plan for
        // spending that is not spending.
        for tx in txs where tx.kind == .expense && !isSetAside(tx) {
            sums[tx.category.isEmpty ? uncategorised : tx.category, default: 0] += abs(tx.amount)
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums
            .map { CategorySlice(name: $0.key, sum: $0.value, share: Double($0.value) / Double(total)) }
            // Name breaks ties so the order is stable across launches — a
            // dictionary's iteration order is not, and two categories with
            // equal sums would otherwise swap places between runs.
            .sorted { $0.sum != $1.sum ? $0.sum > $1.sum : $0.name < $1.name }
    }

    /// A purchase with no splits is UNSPLIT, not worthless: `SplitMath.build`
    /// returns `.ok([])` for a receipt with no line items, so an empty split
    /// list means "nothing is known about what was bought", not "this
    /// purchase is worth nothing". Its whole amount lands here rather than
    /// being dropped, so this view's total always matches `byCategory`'s.
    /// Synthetic — not one of the 21 seeded product groups.
    static let noReceipt = "Без чека"

    /// A spending category nobody has chosen yet. Until this stage it was
    /// nearly unreachable; with nothing guessing categories it is the LARGEST
    /// slice on every fresh install. Pinned here because it was spelled in
    /// four places, and a value drifting between them would show a blank or a
    /// double-counted slice with every test still green.
    static let uncategorised = "Без категорії"

    /// What a row's category line reads, in the feed and on the detail screen.
    ///
    /// A transfer has no category and never will — every path that types one
    /// clears it, because «Переказ між своїми картками» is not a category and
    /// must not be stored as one — so both screens fell through to «Без
    /// категорії» and called an answered row unanswered (board #10). The demo
    /// alone carries 36 of them.
    ///
    /// It replaces the PLACEHOLDER only, never a category that exists: a row
    /// that knows what it is should say so rather than be overwritten by a
    /// label the app chose.
    ///
    /// One function for both screens, so they cannot drift into describing the
    /// same row two ways — the reason `uncategorised` above is a constant.
    /// **The language has NO DEFAULT.** Board #128, and board #96's rule: a
    /// defaulted parameter is how a call site silently keeps the old answer,
    /// and both call sites here had been keeping it for months.
    ///
    /// **`tx.category` is returned untranslated, deliberately.** Category names
    /// are the person's own data — they type them, rename them and delete them
    /// — so translating one would rewrite what somebody wrote. Only the two
    /// placeholders below are app copy, and only they go through `L10n`.
    static func categoryLabel(_ tx: Transaction, _ language: AppLanguage) -> String {
        guard tx.category.isEmpty else { return tx.category }
        return L10n.t(tx.kind == .transfer ? "Переказ між своїми картками" : uncategorised,
                      language)
    }

    /// Spending only, sliced by PRODUCT GROUP (`Split.category` — what was
    /// bought) rather than spending category (`Transaction.category` — where
    /// the money went). Largest first, name breaking ties, same as
    /// `byCategory`. An unsplit purchase contributes its whole amount to
    /// `noReceipt` so the two views' totals always agree.
    static func byProductGroup(_ txs: [Transaction]) -> [CategorySlice] {
        var sums: [String: Int] = [:]
        for tx in txs where tx.kind == .expense {
            if tx.splits.isEmpty {
                sums[noReceipt, default: 0] += abs(tx.amount)
            } else {
                for split in tx.splits {
                    sums[productGroupName(split), default: 0] += abs(split.amount)
                }
            }
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums
            .map { CategorySlice(name: $0.key, sum: $0.value, share: Double($0.value) / Double(total)) }
            .sorted { $0.sum != $1.sum ? $0.sum > $1.sum : $0.name < $1.name }
    }

    /// A split's product group, defensively mapped the same way `byCategory`
    /// maps a blank spending category to «Без категорії». A hand-built
    /// `Split` with an empty `category` must not silently collide with a
    /// real, named group.
    private static func productGroupName(_ split: Split) -> String {
        split.category.isEmpty ? uncategorised : split.category
    }

    struct Contribution: Identifiable, Equatable {
        var id: UUID
        var name: String
        var merchant: String
        var date: Date
        var amount: Int   // magnitude
    }

    /// What, inside `group`, was actually bought: one row per matching split
    /// (named by the PRODUCT — `split.name`), plus one row per matching
    /// unsplit transaction when `group == noReceipt` (named by the MERCHANT,
    /// since it has no product to name). Largest first, name breaking ties.
    static func contributions(_ txs: [Transaction], to group: String) -> [Contribution] {
        var rows: [Contribution] = []
        for tx in txs where tx.kind == .expense {
            if tx.splits.isEmpty {
                guard group == noReceipt else { continue }
                rows.append(Contribution(id: tx.id, name: tx.merchant, merchant: tx.merchant,
                                         date: tx.date, amount: abs(tx.amount)))
            } else {
                for split in tx.splits where productGroupName(split) == group {
                    rows.append(Contribution(id: split.id, name: split.name, merchant: tx.merchant,
                                             date: tx.date, amount: abs(split.amount)))
                }
            }
        }
        return rows.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.name < $1.name }
    }

    // MARK: grouping

    static func days(_ txs: [Transaction]) -> [DaySection] {
        let grouped = Dictionary(grouping: txs) { Calendar.kyiv.startOfDay(for: $0.date) }
        return grouped
            .map { DaySection(day: $0.key, rows: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    // MARK: chart series

    struct Bar: Identifiable, Equatable {
        var label: String
        var sum: Int
        var id: String { label }
    }

    /// One bar per Kyiv month the data touches, ascending, spending only.
    static func monthlyTotals(_ txs: [Transaction]) -> [Bar] {
        months(txs).map { month in
            Bar(label: month.title, sum: totals(inMonth(txs, month)).spent)
        }
    }

    /// Seven bars ending on `ending`'s Kyiv day, oldest first. Days with no
    /// spending are present with a zero, so the chart shows a week's rhythm
    /// rather than only its busy days.
    static func dailyTotals(_ txs: [Transaction], week ending: Date) -> [Bar] {
        let lastDay = Calendar.kyiv.startOfDay(for: ending)
        let spends = txs.filter { $0.kind == .expense }
        let byDay = Dictionary(grouping: spends) { Calendar.kyiv.startOfDay(for: $0.date) }
        return (0..<7).reversed().map { back in
            let day = Calendar.kyiv.date(byAdding: .day, value: -back, to: lastDay)!
            return Bar(label: Self.weekdayLabel(day),
                       sum: (byDay[day] ?? []).reduce(0) { $0 + abs($1.amount) })
        }
    }

    // "пн 7" — the date disambiguates repeats. Cached, board #105.
    private static func weekdayLabel(_ day: Date) -> String {
        KyivFormat.string(day, "EEEEEE d")
    }

    // MARK: search

    /// Matches merchant or category. A blank or whitespace-only query is not a
    /// filter — it returns everything, so clearing the field restores the list.
    static func search(_ txs: [Transaction], _ query: String) -> [Transaction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return txs }
        return txs.filter {
            $0.merchant.lowercased().contains(needle) || $0.category.lowercased().contains(needle)
        }
    }

    // MARK: tips

    struct Tip: Identifiable, Equatable {
        /// **The Ukrainian text, used as a key AND as this tip's identity.**
        /// Not translated here: it is `id`, so translating it would change
        /// which tip SwiftUI thinks it is looking at when the language
        /// changes. The screens render it with `Text(LocalizedStringKey(...))`,
        /// which is the ordinary catalogue lookup. Board #85.
        var title: String
        /// Already translated — it carries numbers, so it has to be built
        /// with a format string rather than looked up whole.
        var body: String
        var id: String { title }
    }

    /// How much of a corpus may be UNSORTED before «Найбільша стаття» stops
    /// being an observation and becomes a guess.
    ///
    /// A share of SPEND, not of rows: one unsorted purchase of 8 000 ₴ moves
    /// the answer further than twenty unsorted 40 ₴ ones, and ₴ is what the
    /// sentence is about. Board #20 also offered "the queue has never been
    /// drained" as the test; this one is better in the way that matters — it
    /// is derived from the rows themselves, so it comes back ON when a new
    /// import refills the queue, where a drained-once flag is true forever
    /// after the first confirm.
    static let unsortedTipCeiling = 0.15

    /// The category «Найбільша стаття» can honestly name, or nil while too
    /// much of the corpus is unsorted. Board #20.
    ///
    /// Two ways for that sentence to lie, and a fresh install hits both at
    /// once — every synced row arrives `.pending` with no category:
    ///
    /// - **The top slice IS «Без категорії».** Naming the pile the app has not
    ///   sorted yet is not an observation about spending. The first launch
    ///   after a sync read «Без категорії — 100% усіх витрат»: true, and it
    ///   reads as mockery from something the person has just installed.
    /// - **A named top slice is unreliable while a big share is unsorted.**
    ///   «Продукти — 30%» with 45% of the money unsorted invites a conclusion
    ///   the data cannot support; the unsorted 45% could belong anywhere.
    ///
    /// Neither test subsumes the other: «Без категорії» can lead a long tail
    /// of small categories while holding well under the ceiling.
    ///
    /// **Only this tip is affected.** The other two are about months and
    /// merchants, and neither gets less true because nobody has typed a
    /// category yet — hiding them too would trade one useless sentence for an
    /// empty screen, and Home shows the FIRST tip, so it would be blank.
    static func topSpendingCategory(_ slices: [CategorySlice]) -> CategorySlice? {
        guard let top = slices.first, top.name != uncategorised else { return nil }
        let unsorted = slices.first { $0.name == uncategorised }?.share ?? 0
        return unsorted > unsortedTipCeiling ? nil : top
    }

    /// Three observations the data can actually support. Each returns nothing
    /// rather than something vacuous when the data does not support it — three
    /// empty cards are worse than one real one.
    static func tips(_ txs: [Transaction], _ language: AppLanguage = .uk) -> [Tip] {
        var tips: [Tip] = []
        let allMonths = months(txs)
        guard !allMonths.isEmpty else { return [] }

        // 1. The largest category's share of all spending — when the corpus is
        //    sorted enough for "largest" to mean anything. See `topSpendingCategory`.
        let slices = byCategory(txs)
        if let top = topSpendingCategory(slices) {
            tips.append(Tip(
                title: "Найбільша стаття",
                body: String(format: L10n.t("%@ — %d%% усіх витрат за %d міс.", language),
                             top.name, Int((top.share * 100).rounded()), allMonths.count)))
        }

        // 2. The month that most exceeded its own income. Months with no
        //    income at all are skipped: "spent more than nothing" is not news.
        let overspends = allMonths.compactMap { month -> (MonthKey, Int)? in
            let t = totals(inMonth(txs, month))
            guard t.income > 0, t.spent > t.income else { return nil }
            return (month, t.spent - t.income)
        }
        if let worst = overspends.max(by: { $0.1 < $1.1 }) {
            let t = totals(inMonth(txs, worst.0))
            tips.append(Tip(
                title: "Місяць понад дохід",
                body: String(format: L10n.t("%@: витрати %@ проти доходу %@.", language),
                             worst.0.title, t.spent.uah, t.income.uah)))
        }

        // 3. The most frequent merchant, with its average cheque. `isSetAside`
        //    for the same reason the two tips above inherit it from `totals`
        //    and `byCategory`: a jar is not a seller, and «Найчастіший
        //    продавець — Банка, у середньому 5 000 ₴» is a sentence about
        //    nobody.
        let expenses = txs.filter { $0.kind == .expense && !isSetAside($0) }
        let counts = Dictionary(grouping: expenses) { MerchantKey.normalize($0.merchant) }
        if let (_, rows) = counts.max(by: {
            $0.value.count != $1.value.count ? $0.value.count < $1.value.count
                                             : $0.key > $1.key      // stable tie-break
        }), rows.count > 1 {
            let total = rows.reduce(0) { $0 + abs($1.amount) }
            let perMonth = Double(rows.count) / Double(allMonths.count)
            tips.append(Tip(
                title: "Найчастіший продавець",
                body: String(format: L10n.t("%@ — %.1f рази на місяць, у середньому %@", language),
                             rows[0].merchant, perMonth, (total / rows.count).uah)))
        }
        return tips
    }
}

/// **Which source's numbers a screen is about.** Board #101.
///
/// The statistics tab summed every bank together, so a person with a personal
/// card and a household one could not ask about either. This is the scope,
/// and it lives here rather than in the view because it has to be applied in
/// three places that must not drift: what the charts sum, and what each of the
/// two drill-throughs lists when a slice is tapped.
///
/// Ids, not names, for the same reason `FeedFilter.banks` holds ids: a bank
/// can be renamed and its rows keep pointing at the same key.
enum StatsSource: Hashable {
    case all
    case bank(String)
    /// A bank AND a card. The bank is carried even though a suffix is nearly
    /// unique, because it is not guaranteed to be: two banks can mask two
    /// different cards to the same four digits, and a chart that silently
    /// summed both would be wrong in a way nothing on screen could show.
    case card(bank: String, suffix: String)
}

extension Derived {
    static func bySource(_ txs: [Transaction], _ source: StatsSource) -> [Transaction] {
        switch source {
        case .all:
            return txs
        case .bank(let id):
            return txs.filter { $0.bankId == id }
        case .card(let id, let suffix):
            return txs.filter { $0.bankId == id && $0.cardSuffix == suffix }
        }
    }

    /// Every scope worth offering, in the order it is offered: everything, then
    /// each bank, then that bank's cards.
    ///
    /// **A level that would select the same rows as the one above it is not
    /// offered.** Two menu entries that do the same thing invite a person to
    /// wonder which is which, and there is no answer.
    ///
    /// So: one bank is not listed, because `.all` already IS that bank. A bank
    /// with one card lists no card, because the bank already IS that card.
    /// Both fall out of the same rule and both were found by a test rather
    /// than by reasoning — the first version listed the sole bank.
    static func sourceOptions(_ txs: [Transaction], _ banks: [Bank]) -> [StatsSource] {
        let grouped = Dictionary(grouping: txs, by: \.bankId)
        let ids = grouped.keys.sorted { BankMark.bank($0, banks) < BankMark.bank($1, banks) }
        var out: [StatsSource] = [.all]
        for id in ids {
            if ids.count > 1 { out.append(.bank(id)) }
            let cards = Set(grouped[id, default: []].map(\.cardSuffix))
                .filter { !$0.isEmpty }.sorted()
            if cards.count > 1 { out += cards.map { .card(bank: id, suffix: $0) } }
        }
        return out
    }
}

/// Feed filters. Empty sets mean "no constraint on this dimension" rather than
/// "match nothing" — an empty filter must show everything, which is what makes
/// clearing the sheet restore the list.
struct FeedFilter: Equatable {
    var categories: Set<String> = []
    var cards: Set<String> = []
    var kinds: Set<TxKind> = []
    /// Bank **ids**, not display names. Board #99.
    ///
    /// A name can change — `applyAccounts` rewrites what the bank calls
    /// itself — while `Transaction.bankId` keeps pointing at the same key, so
    /// a filter holding names would quietly stop matching its own rows.
    ///
    /// This dimension is also the one that does not depend on card identity:
    /// «5*99» from a letter and «*2299» from a statement are two spellings of
    /// one card, but they carry the SAME `bankId`, so «show me ПриватБанк»
    /// catches both without anything having to reconcile them.
    var banks: Set<String> = []

    /// Board #110. **An `Optional`, not a `Set` like the four above it.**
    ///
    /// Receipt presence is tri-state — any, with, without — and as a set it
    /// would have a fifth state meaning the same as the empty one: choosing
    /// BOTH «З чеком» and «Без чека» selects every row, which is what choosing
    /// neither already does. Board #101's rule, in a different place: a level
    /// that selects the same rows as the one above it is not offered. The two
    /// rows behave as radio buttons and clear on a second tap.
    var receipts: ReceiptPresence?

    var isEmpty: Bool {
        categories.isEmpty && cards.isEmpty && kinds.isEmpty && banks.isEmpty
            && receipts == nil
    }

    /// The chips above the feed.
    ///
    /// **Takes the banks and a language, neither defaulted.** Three of the four
    /// dimensions are the person's data — a category name, a card suffix, a
    /// bank's own name — and are shown as they are. The fourth is copy:
    /// `TxKind.title` is «Витрати», the catalogue has translated it since board
    /// #85, and this returned the Ukrainian while `FeedView` drew it through
    /// `Text(verbatim:)` — beside a filter sheet whose own rows read
    /// "Spending". Board #96's guards look inside one file at a time and this
    /// defect is spread across two.
    func chips(_ allBanks: [Bank], _ language: AppLanguage) -> [String] {
        Category.alphabetical(Array(categories))
            + banks.map { BankMark.bank($0, allBanks) }.sorted()
            + cards.sorted()
            + kinds.sorted { $0.rawValue < $1.rawValue }.map { L10n.t($0.title, language) }
            // Copy, like the kind above it and unlike the three data
            // dimensions — so it goes through `L10n.t` here, at the source.
            // This is exactly where board #99 found «Витрати» being shipped to
            // a reader whose filter sheet said "Spending".
            + [receipts].compactMap { $0 }.map { L10n.t($0.title, language) }
    }
}

/// Board #110 — whether a purchase carries a fiscal receipt.
enum ReceiptPresence: String, Hashable, CaseIterable {
    case with, without

    var title: String {
        switch self {
        case .with: return "З чеком"
        case .without: return "Без чека"
        }
    }

    /// `receiptId != nil` is the whole test, and that is safe rather than
    /// convenient: `detachReceipt` and the re-attach path both CLEAR the id
    /// (`AppStore+Receipts.swift:37, 218`), so a row pointing at a receipt that
    /// no longer exists is not a state this app can reach. Were it reachable,
    /// «З чеком» would list rows with nothing behind them — and `Derived`
    /// computes from `[Transaction]` and nothing else, so it could not check.
    func matches(_ tx: Transaction) -> Bool {
        switch self {
        case .with: return tx.receiptId != nil
        case .without: return tx.receiptId == nil
        }
    }
}

extension TxKind {
    var title: String {
        switch self {
        case .expense: return "Витрати"
        case .income: return "Надходження"
        case .transfer: return "Перекази"
        }
    }
}

extension Derived {
    static func apply(_ filter: FeedFilter, to txs: [Transaction]) -> [Transaction] {
        txs.filter { tx in
            (filter.categories.isEmpty || filter.categories.contains(tx.category))
            && (filter.banks.isEmpty || filter.banks.contains(tx.bankId))
            && (filter.cards.isEmpty || filter.cards.contains(tx.cardSuffix))
            && (filter.kinds.isEmpty || filter.kinds.contains(tx.kind))
            && (filter.receipts?.matches(tx) ?? true)
        }
    }

    /// Board #110. How many of these purchases **could** carry a fiscal receipt
    /// and do not — the number that makes «Без чека» a to-do rather than a
    /// filter.
    ///
    /// **Expenses only, and money set aside excluded.** A transfer between your
    /// own cards and an arrival never have a receipt and never will; counting
    /// them would fill a to-do with rows nobody can act on, and on this repo's
    /// demo seed the transfer-heavy months would be mostly that. Savings goes
    /// for the same reason `totals` drops it — putting money aside is not a
    /// purchase and has no receipt to find.
    static func withoutReceipt(_ txs: [Transaction]) -> Int {
        txs.filter { $0.kind == .expense && !isSetAside($0) && $0.receiptId == nil }.count
    }
}

// MARK: fuel

extension Derived {
    /// One receipt line read as a fill-up: which grade, how many litres, at
    /// what price. `date` is the TRANSACTION's date, not the receipt's
    /// `fiscalTime` — the transaction's date is what every other screen
    /// sorts and filters by, and a receipt scanned days after the pump
    /// (or attached to a transaction from a different day) must not jump
    /// the log to the scan date.
    struct FillUp: Identifiable, Equatable {
        var id: UUID
        var date: Date
        var station: String
        var grade: String
        var litres: Double
        var pricePerLitre: Int   // minor units
        var total: Int           // minor units
    }

    struct FuelSummary: Equatable {
        var litres: Double
        var total: Int            // minor units
        var averagePerLitre: Int  // minor units, WEIGHTED: total ÷ litres, rounded
    }

    /// Every fuel line among `txs`' attached receipts. Only a transaction
    /// that actually points at a receipt (`receiptId`) contributes — a
    /// receipt sitting unattached in `receipts` (a scanner sample the owner
    /// never matched to a card charge) is not a fill-up, it is a scan with
    /// nowhere to file its date. Within an attached receipt, only items
    /// whose name `FuelGrade.parse`s are kept: a fuel receipt can carry a
    /// non-fuel line (a car wash, a bottle of water) alongside the fuel
    /// one, and that line must not become a fill-up with a nil grade.
    ///
    /// Order follows `txs`, then `receipt.items` — the order the caller
    /// passed in, undisturbed; nothing here claims a sort order the brief
    /// does not specify.
    static func fillUps(_ txs: [Transaction], receipts: [Receipt]) -> [FillUp] {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter TRAPS on
        // a duplicate key. Nothing today can hand this two receipts with one
        // id — `attach` removes any same-id record before appending — but
        // `Derived` is the pure arithmetic every screen reads without
        // checking, and a crash is a worse answer than an arbitrary-but-
        // deterministic pick. First one wins.
        let byId = Dictionary(receipts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fills: [FillUp] = []
        for tx in txs {
            guard let receiptId = tx.receiptId, let receipt = byId[receiptId] else { continue }
            for item in receipt.items {
                guard let grade = FuelGrade.parse(item.name) else { continue }
                fills.append(FillUp(id: item.id, date: tx.date, station: receipt.displaySeller,
                                    grade: grade, litres: item.qty,
                                    pricePerLitre: item.price, total: item.sum))
            }
        }
        return fills
    }

    /// nil for an empty list, so the caller hides the whole card rather than
    /// render one with a zero in it. `averagePerLitre` is the WEIGHTED
    /// average — total money over total litres — not the mean of the
    /// per-fill prices: a 5-litre top-up and a 45-litre fill do not carry
    /// equal weight in what the owner actually paid per litre overall.
    static func fuelSummary(_ fills: [FillUp]) -> FuelSummary? {
        guard !fills.isEmpty else { return nil }
        let litres = fills.reduce(0.0) { $0 + $1.litres }
        let total = fills.reduce(0) { $0 + $1.total }
        let averagePerLitre = litres > 0 ? Int((Double(total) / litres).rounded()) : 0
        return FuelSummary(litres: litres, total: total, averagePerLitre: averagePerLitre)
    }
}
