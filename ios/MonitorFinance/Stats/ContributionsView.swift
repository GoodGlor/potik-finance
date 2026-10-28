import SwiftUI

/// A push from the stats screen's «За чеками» mode into what actually made up
/// one PRODUCT GROUP slice — the receipts-namespace counterpart to
/// `CategoryDrill`, which does the same job for the spending-category
/// namespace. A Hashable value rather than a String so it can be a
/// `navigationDestination(for:)` route and carry the PERIOD the slice came
/// from.
///
/// A `Derived.DateWindow`, not an optional `MonthKey` like `CategoryDrill`.
/// The two destinations read a missing value differently and that is what
/// made the month version wrong here: `CategoryDrill(month: nil)` opens
/// `FeedView`, which falls back to its own newest month and shows ONE month,
/// while a nil here means the whole dataset. So in «Тиждень» — where a month
/// cannot describe the period at all — the drill listed all eight months
/// under a slice that summed seven days. A window says exactly what
/// `StatsView` summed, in every scope it offers.
struct ContributionDrill: Hashable {
    var group: String
    /// nil = no period filter, the whole dataset. Only «Рік» sends that,
    /// and «Рік» IS the whole dataset.
    var window: Derived.DateWindow?
    /// Board #101 — the same reason the window travels: the list must be about
    /// the rows the slice summed.
    var source: StatsSource = .all
}

/// What, inside one product group, was actually bought: every `Derived.Contribution`
/// row, largest first, name atop, merchant and date beneath it, amount to the
/// right — the same layout `TransactionRow` uses for name / subtitle / amount.
///
/// Flat rather than day-sectioned like the feed: a group's contributions
/// come from different transactions on different days, and `byProductGroup`'s
/// point is what was bought, not when.
struct ContributionsView: View {
    @Environment(AppStore.self) private var store
    let group: String
    let window: Derived.DateWindow?
    var source: StatsSource = .all

    private var transactions: [Transaction] {
        Derived.inWindow(Derived.bySource(store.transactions, source), window)
    }
    private var rows: [Derived.Contribution] { Derived.contributions(transactions, to: group) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if rows.isEmpty {
                    Text("Немає покупок у цій групі")
                        .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                        .accessibilityIdentifier("contributions.empty")
                } else {
                    Card {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.name)
                                        .font(Theme.font(16, .semibold))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                        .accessibilityIdentifier("stats.contribution.\(index)")
                                    Text("\(row.merchant) · \(Self.dateTitle(row.date))")
                                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(row.amount.uahExact)
                                    .font(Theme.font(16, .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize()
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contributions.title")
    }

    static func dateTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = .kyiv; f.timeZone = .kyiv
        f.locale = L10n.formatting.locale
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }
}
