import SwiftUI

/// Picks what the plan's percentages are percentages *of*. Every chip carries
/// its own computed figure, which is the whole point: a 12-month average that
/// includes two thin months at the start of the data reads visibly lower than
/// a 3-month one, and the user decides which is their real income rather than
/// the app deciding for them.
struct IncomeBaseView: View {
    let base: IncomeBase
    var onPick: (IncomeBase) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var useAverage: Bool
    @State private var months: Int
    @State private var includeGifts: Bool
    @State private var fixedText: String

    private static let offered = [1, 2, 3, 6, 12]

    init(base: IncomeBase, onPick: @escaping (IncomeBase) -> Void) {
        self.base = base
        self.onPick = onPick
        switch base {
        case .average(let m, let gifts):
            _useAverage = State(initialValue: true)
            _months = State(initialValue: m)
            _includeGifts = State(initialValue: gifts)
            _fixedText = State(initialValue: "")
        case .fixed(let amount):
            _useAverage = State(initialValue: false)
            _months = State(initialValue: 3)
            _includeGifts = State(initialValue: false)
            _fixedText = State(initialValue: String(amount / 100))
        }
    }

    /// What was typed, in minor units. A 17-digit entry parses to a perfectly
    /// valid `Int` and then *traps* on `× 100`, taking the app down with it —
    /// so the multiply reports its overflow rather than trapping, and a sum
    /// that cannot be represented falls back to 0, which `canSave` refuses.
    private var fixedMinorUnits: Int {
        guard let hryvnia = Int(fixedText), hryvnia >= 0 else { return 0 }
        let (minor, overflowed) = hryvnia.multipliedReportingOverflow(by: 100)
        return overflowed ? 0 : minor
    }

    private var picked: IncomeBase {
        useAverage ? .average(months: months, includeGifts: includeGifts)
                   : .fixed(fixedMinorUnits)
    }

    private var canSave: Bool {
        if useAverage { return true }
        return fixedMinorUnits > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $useAverage) {
                        Text("Середній дохід").tag(true)
                        Text("Своя сума").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("income.mode")

                    if useAverage { averageSection } else { fixedSection }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            // `.numberPad` has no return key, so a drag is the only way off
            // the field — same reason `Banks/TokenView` carries this.
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle("Дохід")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Готово") { onPick(picked); dismiss() }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("income.save")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("income.title")
        }
    }

    private var averageSection: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.offered, id: \.self) { n in
                        let avg = BudgetMath.average(store.transactions, months: n,
                                                     now: Date(), includeGifts: includeGifts,
                                                     categories: store.categories)
                        Button { months = n } label: {
                            HStack {
                                Text(BudgetMath.label(for: avg, store.settings.languageChoice))
                                    .font(Theme.font(16, months == n ? .semibold : .regular))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if months == n {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.green)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("income.chip.\(n)")
                    }
                }
            }
            Card {
                Toggle(isOn: $includeGifts) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Враховувати подарунки та перекази")
                            .font(Theme.font(16)).foregroundStyle(Theme.ink)
                        Text("Без цього рахуються лише зарплата, стипендія та інші надходження.")
                            .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .tint(Theme.green)
                .accessibilityIdentifier("income.gifts")
            }
        }
    }

    private var fixedSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Сума на місяць, ₴").font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                TextField("49 000", text: $fixedText)
                    .keyboardType(.numberPad)
                    .font(Theme.font(24, .bold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("income.custom")
            }
        }
    }
}
