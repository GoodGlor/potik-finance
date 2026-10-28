import SwiftUI

struct ImportSummaryView: View {
    @Environment(AppStore.self) private var store
    let summary: ImportSummary
    /// `LocalizedStringKey` for the same reason `PrimaryButton.title` is:
    /// both callers pass a literal («Готово», «Далі»), and a `String` here
    /// would take the non-localising overload one layer down.
    var buttonTitle: LocalizedStringKey
    var onContinue: () -> Void

    private static let day: DateFormatter = {
        let f = DateFormatter()
        // Purely numeric — dd.MM.yyyy reads the same in both languages, so
        // there is nothing here for the interface language to change.
        f.locale = Locale(identifier: "uk_UA")
        f.timeZone = PrivatStatementParser.kyiv
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 40, weight: .light)).foregroundStyle(Theme.green)
                        Text("Виписку імпортовано")
                            .font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("import.summary")
                        Text(countsLine).font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                        if let period = summary.period {
                            // `period` spans only the surviving UAH rows, not
                            // the file's own span — a foreign-currency row at
                            // either edge of the statement narrows it. The
                            // label says so, rather than implying this is the
                            // statement's own period.
                            Text("Період імпортованих операцій: \(Self.day.string(from: period.lowerBound)) – \(Self.day.string(from: period.upperBound))")
                                .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                        }
                        if !summary.cardSuffixes.isEmpty {
                            Text("Картки: \(summary.cardSuffixes.joined(separator: ", "))")
                                .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                        }
                        if summary.skippedNonUAH > 0 {
                            Text("\(Plural.operationsAccusative(summary.skippedNonUAH, store.settings.languageChoice)) в іншій валюті пропущено — застосунок рахує лише гривню.")
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            PrimaryButton(title: buttonTitle, action: onContinue)
                .accessibilityIdentifier("import.done")
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden()
    }

    /// `LocalizedStringKey`, not `String`: assembled in the view, so the
    /// interpolation becomes `%lld` in the key and SwiftUI substitutes it
    /// after the lookup. As a `String` it took `Text`'s verbatim overload and
    /// stayed Ukrainian.
    private var countsLine: LocalizedStringKey {
        summary.merged > 0
            ? "Нових операцій: \(summary.imported), оновлено: \(summary.merged)."
            : "Нових операцій: \(summary.imported)."
    }
}
