import Foundation

/// Every figure the budget screens show, computed from `[Transaction]`,
/// a `Budget` and the current instant — nothing else. Same discipline as
/// `Derived`: pure functions, so the arithmetic is tested in milliseconds.
///
/// `now` is a parameter rather than `Date()` so a test can stand in August
/// without the suite changing behaviour when the calendar rolls over.
enum BudgetMath {

    /// What the owner *earns*, derived from what their categories SAY rather
    /// than from what they are called. A 10 000 ₴ gift from a relative and a
    /// 200 ₴ taxi refund are both `.income` rows, and neither is a salary to
    /// plan against.
    ///
    /// Board #94. It was a hardcoded set of three Ukrainian names, and that is
    /// why renaming «Зарплата» — one tap in Налаштування → Категорії — dropped
    /// a person's salary out of their own income base, with nothing on screen
    /// to say the whole plan had just re-based.
    static func earnedCategories(_ categories: [Category]) -> Set<String> {
        Set(categories.filter { $0.resolvedKind == .earned }.map(\.name))
    }

    /// Where an income row lands before a human says otherwise. It MUST be a
    /// member of `earnedCategories`: `income(_:includeGifts: false)` counts
    /// only those, so a default outside the set makes every synced income row
    /// worth zero to the budget and the default plan divides by nothing.
    static let defaultIncomeCategory = "Інші надходження"

    /// Everything an income row is allowed to be called, in the order the
    /// picker offers them — most common first, not alphabetical.
    ///
    /// It is the earned categories plus «Подарунки», which is deliberately NOT
    /// earned: a gift is money in that no plan should be built on. Anything
    /// outside this list on an `.income` row means Головна (which reads the
    /// sign of the amount) and Бюджет (which reads the category) are counting
    /// different things.
    ///
    /// A refund is the one exception, and it is not an exception to this list
    /// — a refund keeps the category of the purchase it cancels, and the
    /// picker asks for that separately. See `CategoryPurpose.income`.
    /// The order the picker has always offered the seeded names in — most
    /// common first, not alphabetical. It decides ORDER, never membership: a
    /// name here that no category claims simply does not appear.
    static let canonicalIncomeOrder = ["Зарплата", "Стипендія", "Подарунки", "Інші надходження"]

    /// Everything an income row is allowed to be called. Seeded names first in
    /// the canonical order above — it is a vocabulary people learn by position
    /// — then whatever this person has added, alphabetically, because there is
    /// no other order to prefer among names the app has never seen.
    static func incomeCategories(_ categories: [Category]) -> [String] {
        let names = Set(categories
            .filter { $0.resolvedKind == .earned || $0.resolvedKind == .unearned }
            .map(\.name))
        let head = canonicalIncomeOrder.filter(names.contains)
        return head + Category.alphabetical(Array(names.subtracting(head)))
    }

    /// Kyiv months with data, oldest first, excluding the month `now` is in.
    /// A month still being lived has no business in an average of months.
    static func completeMonths(_ txs: [Transaction], now: Date) -> [MonthKey] {
        let current = MonthKey(now)
        return Derived.months(txs).filter { $0 < current }
    }

    /// `categories` has no default, deliberately: a default would let a call
    /// site keep the old, seed-only answer silently, which is the exact bug
    /// board #94 exists to remove.
    static func income(_ txs: [Transaction], includeGifts: Bool,
                       categories: [Category]) -> Int {
        let earned = earnedCategories(categories)
        return txs.filter { $0.kind == .income }
                  .filter { includeGifts || earned.contains($0.category) }
                  .reduce(0) { $0 + abs($1.amount) }
    }

    struct Average: Equatable {
        var asked: Int      // months the chip offered
        var used: Int       // months that actually existed
        var perMonth: Int   // minor units, >= 0
    }

    /// The chip's caption, split off the arithmetic when board #85 gave the
    /// app a language. `monthlyIncome` below wants the NUMBER and nothing
    /// else, and threading a language through a pure sum so that a string it
    /// discards can be built would have been the wrong shape — the caption is
    /// the only part that has an opinion about language.

    /// Averages the most recent `months` complete months. When fewer exist the
    /// label says so and the divisor is what was found — dividing 5 months of
    /// income by 12 would quietly halve the user's plan.
    static func label(for average: Average, _ language: AppLanguage) -> String {
        let over = over(average.asked, language)
        // `String(format: L10n.t(...))`, the shape `Derived` uses: these
        // sentences are assembled outside any view, so there is no
        // `LocalizedStringKey` literal for the catalogue to match — the
        // translation has to happen here or not at all.
        guard average.used > 0 else {
            return String(format: L10n.t("%@ — даних ще немає", language), over)
        }
        guard average.used == average.asked else {
            return String(format: L10n.t("%@ даних є лише за %d — %@", language),
                          over, average.used, unbroken(average.perMonth))
        }
        // Two figures and a dash: nothing here is a word, so nothing needs one.
        return "\(over) — \(unbroken(average.perMonth))"
    }

    static func average(_ txs: [Transaction], months asked: Int, now: Date,
                        includeGifts: Bool, categories: [Category]) -> Average {
        let window = Array(completeMonths(txs, now: now).suffix(asked))
        guard !window.isEmpty else { return Average(asked: asked, used: 0, perMonth: 0) }
        let total = window.reduce(0) { $0 + income(Derived.inMonth(txs, $1), includeGifts: includeGifts,
                                             categories: categories) }
        return Average(asked: asked, used: window.count, perMonth: total / window.count)
    }

    /// The sum, with the space before «₴» made non-breaking.
    ///
    /// `.uah` joins them with a plain space, which is right on every screen
    /// where the figure fits on one line. These rows are the one place long
    /// enough to wrap — «За 12 місяців даних є лише за 7 — 36 280» broke
    /// exactly there, leaving «₴» alone on the second line, which reads as a
    /// typo. Now the whole sum moves down together instead.
    private static func unbroken(_ amount: Int) -> String {
        amount.uah.replacingOccurrences(of: " ₴", with: "\u{00A0}₴")
    }

    /// «За 3 місяці». Board #23: these rows read «3 міс · є лише 1 · 0 ₴» —
    /// a debug print, in a list whose whole job is to let somebody decide
    /// which number is their real income. They are full-width rows, not
    /// chips, so there was never a width reason for the shorthand.
    private static func over(_ months: Int, _ language: AppLanguage) -> String {
        "За \(Plural.months(months, language))"
    }

    /// The ₴ figure a plan's percentages are percentages *of*.
    /// Board #114: **scoped here, not by the caller.** A filter every caller
    /// has to remember is one a caller forgets, and the one that forgot would
    /// measure a bank-scoped plan against every bank's income.
    ///
    /// `.fixed` is deliberately untouched by the scope: a number somebody
    /// typed is the number they meant, and quietly shrinking it because they
    /// later scoped the plan would change an answer they gave.
    static func monthlyIncome(_ budget: Budget, txs: [Transaction], now: Date,
                              categories: [Category]) -> Int {
        switch budget.incomeBase {
        case .fixed(let amount):
            return amount
        case .average(let months, let includeGifts):
            return average(budget.scoped(txs), months: months, now: now,
                           includeGifts: includeGifts,
                           categories: categories).perMonth
        }
    }

    /// The one line that is not spent on. Named once here because three
    /// screens and two mutations have to agree on the spelling.
    ///
    /// It is also the answer for a jar top-up (board #6): money that left the
    /// card and is still the owner's. `Derived` therefore keeps a row in this
    /// category out of every spending figure — see `Derived.totals`, which is
    /// what makes the two ways of recording a top-up produce the same numbers.
    static let savingsCategory = "Заощадження"

    /// Cash. Named here for the same reason `savingsCategory` is: the picker
    /// offers it, the seed ships it and `PrivatMapper` suggests it, and a
    /// typo in any one of the three would quietly create a second category.
    ///
    /// Unlike savings this is ORDINARY spending, and that is the whole point
    /// of board #6: the moment money becomes cash is the last moment the app
    /// can see it, so that is where it counts as spent.
    static let cashCategory = "Готівка"

    struct PlanRow: Identifiable, Equatable {
        var category: String
        var percent: Double
        var planned: Int    // minor units
        var actual: Int     // minor units, >= 0
        var isSavings: Bool
        /// Over plan for a spending line; UNDER plan for savings.
        var offPlan: Bool
        /// Of the income base — the same denominator `planned` used, so the
        /// bar's tick and its fill are comparable (D4).
        var share: Double
        var id: String { category }
    }

    struct Report: Equatable {
        var income: Int
        var rows: [PlanRow]
        var unplanned: [Derived.CategorySlice]
        var unplannedTotal: Int
    }

    static func report(_ budget: Budget, txs: [Transaction], month: MonthKey, now: Date,
                       categories: [Category]) -> Report {
        let base = monthlyIncome(budget, txs: txs, now: now, categories: categories)
        // Board #114. Scoped ONCE, at the top, so every figure below — planned,
        // actual, unplanned, drift — is about the same set of rows. Scoping
        // some of them and not others is how a report ends up unable to add up.
        let rows = Derived.inMonth(budget.scoped(txs), month)
        let spend = Dictionary(grouping: rows.filter { $0.kind == .expense }, by: \.category)
            .mapValues { $0.reduce(0) { $0 + abs($1.amount) } }
        // Transfers are already excluded here — `Derived.totals` skips them.
        let realised = Derived.totals(rows)

        let planRows = budget.lines.map { line -> PlanRow in
            // Rounded, not truncated: an exact ₴ figure the user typed
            // arrives here as a fractional percent, and integer division
            // would floor it a kopeck below what the editor showed them.
            let planned = Int((Double(base) * line.percent / 100).rounded())
            let isSavings = line.category == savingsCategory
            // Savings is the exception to D4's single denominator: what was
            // saved is a fact about the month that happened, not a share of
            // the plan's assumed income.
            let actual = isSavings ? max(0, realised.income - realised.spent)
                                   : (spend[line.category] ?? 0)
            return PlanRow(category: line.category,
                           percent: line.percent,
                           planned: planned,
                           actual: actual,
                           isSavings: isSavings,
                           offPlan: isSavings ? actual < planned : actual > planned,
                           share: base > 0 ? Double(actual) / Double(base) : 0)
        }

        let planned = Set(budget.lines.map(\.category))
        let unplanned = Derived.byCategory(rows).filter { !planned.contains($0.name) }
        return Report(income: base,
                      rows: planRows,
                      unplanned: unplanned,
                      unplannedTotal: unplanned.reduce(0) { $0 + $1.sum })
    }

    /// One decimal, Ukrainian comma. `String(format:)` is C-locale, so the
    /// separator is swapped explicitly rather than left to the device.
    static func percentText(_ share: Double) -> String {
        String(format: "%.1f", share * 100).replacingOccurrences(of: ".", with: ",") + "%"
    }

    /// A PLANNED percent, which — unlike an actual share — is usually whole.
    /// «30%» when it is, «10,7%» when the user set the line by its ₴ amount.
    /// Always writing one decimal would put «30,0%» on every untouched line.
    ///
    /// `String(format:)` rather than `Int()`: the editor leaves the percent
    /// field unclamped on purpose, and converting an absurd typed value to
    /// `Int` would trap rather than render.
    static func planPercentText(_ percent: Double) -> String {
        let shown = (percent * 10).rounded() / 10
        if shown == shown.rounded() { return String(format: "%.0f", shown) + "%" }
        return String(format: "%.1f", shown).replacingOccurrences(of: ".", with: ",") + "%"
    }

    /// The ₴ a line plans, in whole hryvnia — what the editor's amount field
    /// shows. `income` is minor units, so the divisor is 100 (percent) × 100
    /// (kopecks per hryvnia).
    static func plannedMajor(percent: Double, income: Int) -> Int {
        Int((Double(income) * percent / 10_000).rounded())
    }

    /// The inverse: the percentage that makes a line plan exactly `major` ₴.
    /// Nil when the base is zero — no percentage of nothing is 5 000 ₴, and
    /// the caller must keep the percent it had rather than divide by it.
    static func percentFor(major: Int, income: Int) -> Double? {
        guard income > 0 else { return nil }
        return Double(major) * 10_000 / Double(income)
    }

    /// The footer's precision: up to two decimals, trailing zero trimmed.
    /// One decimal is not enough here. A plan totalling 99,99% is genuinely
    /// incomplete and save stays disabled, but rounded to a tenth it reads
    /// «Розподілено 100% · залишилось 0%» — a footer claiming the plan is
    /// done beside a button refusing to save it. Rows and drift copy keep
    /// `planPercentText`, where a hundredth of a percent is noise.
    static func allocationPercentText(_ percent: Double) -> String {
        let shown = (percent * 100).rounded() / 100
        if shown == shown.rounded() { return String(format: "%.0f", shown) + "%" }
        let text = String(format: "%.2f", shown)
        return (text.hasSuffix("0") ? String(text.dropLast()) : text)
            .replacingOccurrences(of: ".", with: ",") + "%"
    }

    /// What is wrong with this line, in words, or nil if nothing is.
    ///
    /// The category name is quoted rather than declined: the spec's example
    /// reads «на продукти», the genitive, and there is no way to produce that
    /// for 39 user-editable names — several of them multi-word — without a
    /// grammar engine we are not writing (D3).
    static func driftText(_ row: PlanRow, _ language: AppLanguage) -> String? {
        guard row.offPlan else { return nil }
        if row.isSavings {
            return String(format: L10n.t("Залишилось %@ із запланованих %@.", language),
                          row.actual.uah, row.planned.uah)
        }
        // One format string rather than three concatenated fragments: a
        // translator needs the whole sentence to reorder it, and the pieces
        // «замість запланованих» and «більше» mean nothing apart.
        return String(format: L10n.t("«%@» — вже %@ замість запланованих %@, на %@ більше.", language),
                      row.category, percentText(row.share),
                      planPercentText(row.percent), (row.actual - row.planned).uah)
    }

    /// The line that has drifted furthest in money — the one Home shows.
    /// Money, not percentage points: a 2% miss on rent is worth more attention
    /// than a 40% miss on a line that was 200 ₴ to begin with.
    static func worstDrift(_ report: Report) -> PlanRow? {
        report.rows.filter(\.offPlan).max { abs($0.actual - $0.planned) < abs($1.actual - $1.planned) }
    }

    /// Non-nil only when `tx` is what took its line past the plan — running
    /// the category's spend in date order, the total was at-or-under the
    /// plan just before `tx` and over it once `tx` is included.
    ///
    /// Comparing the whole month with and without `tx` (rather than a
    /// running total) is not enough: when two rows are each under the plan
    /// alone but over it together, removing *either* one drops the month
    /// back under plan, so that test credits both instead of the one that
    /// actually crossed the line first.
    ///
    /// The order is `(date, id)`, not date alone. Bank exports stamp whole
    /// batches with one instant — the shipped seed has 13 same-instant
    /// same-category groups — and a strict `date <` comparison puts each
    /// member of such a group *after* every other, so every one of them sees
    /// the full group total as "before" and none of them ever qualifies as
    /// the tipper. A total order breaks the tie arbitrarily but consistently,
    /// so exactly one row in the group is credited, and it is the same row on
    /// every call.
    static func pushedOverPlan(_ tx: Transaction, budget: Budget, txs: [Transaction],
                               now: Date, categories: [Category]) -> PlanRow? {
        guard tx.kind == .expense else { return nil }
        // Board #114. A purchase on a bank this plan is not about cannot push
        // that plan over — and saying it did would be the loudest possible
        // way to get a scope wrong, since this is what raises the alert.
        guard budget.scoped([tx]).count == 1 else { return nil }
        let month = MonthKey(tx.date)
        let current = report(budget, txs: txs, month: month, now: now,
                             categories: categories)
        guard let row = current.rows.first(where: { $0.category == tx.category }),
              !row.isSavings else { return nil }
        let ordered = Derived.inMonth(budget.scoped(txs), month)
            .filter { $0.category == tx.category && $0.kind == .expense }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        guard let i = ordered.firstIndex(where: { $0.id == tx.id }) else { return nil }
        let before = ordered[..<i].reduce(0) { $0 + abs($1.amount) }
        let after = before + abs(tx.amount)
        guard before <= row.planned, after > row.planned else { return nil }
        return row
    }

    static func allocated(_ lines: [Budget.Line]) -> Double { lines.reduce(0) { $0 + $1.percent } }

    /// Complete when the lines allocate the whole income — with a hryvnia of
    /// slack per line, which is exactly what rounding can cost and no more.
    ///
    /// Exact percentage equality is the wrong test once a line can be set by
    /// its ₴ figure. An income base of 46 697,47 ₴ cannot be split into whole
    /// hryvnia at all: the kopecks have nowhere to go, so every plan typed as
    /// amounts lands ~0,47 ₴ short, and `== 100` would leave Save permanently
    /// disabled under a footer reading «залишилось 0,01%». Mixing a typed
    /// amount with typed percentages misses by a hryvnia or two for the same
    /// reason. Both are the ordinary path, not a corner.
    ///
    /// The slack is money-shaped rather than a fixed percentage because a
    /// percentage means different money at different incomes: 0,01% is 4,67 ₴
    /// on this owner's base and 10 копійок on a 1 000 ₴ one. A plan 500 ₴
    /// short is still short at either.
    ///
    /// With no income to measure against, the slack falls back to a hundredth
    /// of a percent — enough to absorb binary-floating-point noise in the sum
    /// and nothing else.
    static func isComplete(_ lines: [Budget.Line], income: Int) -> Bool {
        guard !lines.isEmpty else { return false }
        let slack = income > 0 ? Double(lines.count) * 10_000 / Double(income) : 0.01
        return abs(allocated(lines) - 100) <= slack
    }

    /// Three states, because "залишилось −5%" is not a sentence anyone reads.
    static func allocationText(_ lines: [Budget.Line], income: Int,
                               _ language: AppLanguage) -> String {
        let total = allocated(lines)
        // Asks `isComplete` rather than re-testing the total, so the footer
        // can never read «Розподілено 100%» beside a disabled save button.
        if isComplete(lines, income: income) { return L10n.t("Розподілено 100%", language) }
        if total < 100 {
            return String(format: L10n.t("Розподілено %@ · залишилось %@", language),
                          allocationPercentText(total), allocationPercentText(100 - total))
        }
        return String(format: L10n.t("Розподілено %@ · на %@ більше", language),
                      allocationPercentText(total), allocationPercentText(total - 100))
    }
}
