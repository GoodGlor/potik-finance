import SwiftUI

/// Board #109 — choosing a month, rather than stepping to it.
///
/// The feed has always shown one month at a time, but only the chevrons could
/// change it: eight months of history meant up to seven taps to reach one, with
/// nothing on screen saying which months existed at all.
///
/// **A sheet, not a `Menu`.** Board #101 measured that a `Menu` containing a
/// `Picker` never opens under XCUITest — the label taps and nothing happens,
/// which leaves "the control exists" as the only assertion a test can make, and
/// that is precisely the assertion that still passes when the control does
/// nothing. `FeedFilterSheet` is the shape this screen already proves works.
struct FeedMonthSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Already summed by the caller, from the rows the feed is actually
    /// showing minus its month cut — so a row promising 12 345 ₴ opens a feed
    /// showing 12 345 ₴, filters and search included.
    let rows: [Derived.MonthRow]
    /// The month on screen now. Not `months.last`: the feed's default is the
    /// newest month with data, and this has to tick whatever is actually shown.
    let current: MonthKey
    var onPick: (MonthKey) -> Void

    /// The calendar month, which is not necessarily the newest one with data —
    /// on a frozen dataset it is not, and on a real phone at the start of a
    /// month it is not either until the first purchase lands.
    private var thisMonth: MonthKey { MonthKey(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { onPick(row.month); dismiss() } label: { line(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("feed.month.\(row.month.description)")
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.hair).padding(.leading, 20)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Theme.bg)
            .navigationTitle("Місяць")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .accessibilityIdentifier("feed.months.done")
                }
            }
        }
    }

    private func line(_ row: Derived.MonthRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // `verbatim`: `MonthKey.title` is a formatted date that already
                // followed the chosen language through `L10n.formatting`, and a
                // plain `Text(someString)` would take this overload anyway —
                // worth saying out loud rather than relying on.
                Text(verbatim: row.month.title)
                    .font(Theme.font(17, .semibold))
                    .foregroundStyle(row.count == 0 ? Theme.inkMuted : Theme.ink)
                Text(verbatim: Self.summary(row, store.settings.languageChoice))
                    .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            // The note, then the tick — a month can be both, and the tick is
            // the one that has to sit at the trailing edge where the eye runs
            // down the column looking for it.
            if row.month == thisMonth {
                Text("цей місяць")
                    .font(Theme.font(13)).foregroundStyle(Theme.green)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.green)
                .opacity(row.month == current ? 1 : 0)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    /// «114 операцій · 12 345 ₴», or just the count when the month holds no
    /// spending — a bare «0 ₴» beside a month full of income and transfers
    /// reads as a broken figure rather than as an accurate one.
    static func summary(_ row: Derived.MonthRow, _ language: AppLanguage) -> String {
        let counted = Plural.operations(row.count, language)
        guard row.spent > 0 else { return counted }
        return "\(counted) · \(row.spent.uahExact)"
    }
}
