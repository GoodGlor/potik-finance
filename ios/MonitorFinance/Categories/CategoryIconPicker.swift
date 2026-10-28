import SwiftUI

/// Everything about one category that is not its name: the icon it wears
/// (board #61) and what it means to the budget (board #94).
///
/// **It lives in Налаштування → Категорії, not in the create flow.** A new
/// category is created from `CategoryPicker` by one tap on «Створити «X»»,
/// which then immediately answers the question the person actually opened that
/// screen to answer — what category is this purchase. Putting an icon grid in
/// the middle of that is a second question nobody asked, at the worst possible
/// moment. The category gets the generic label and can be given a real icon
/// on the screen that exists for looking after categories.
struct CategoryIconPicker: View {
    let category: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    /// Board #94, and it belongs on THIS sheet: the doc above already calls
    /// this "the screen that exists for looking after categories", the row's
    /// tap already opens it, and a third trailing swipe action beside rename
    /// and delete would have hidden the control behind a gesture — one that a
    /// full swipe turns into a delete.
    ///
    /// The consequence is a standing line, not a confirmation dialog. A
    /// segmented control applies on the tap, and a sheet asking "are you
    /// sure" after every tap of a three-way choice teaches people to tap
    /// through it. A warning that is always on screen is read before the
    /// decision rather than after it.
    /// `BudgetMath.defaultIncomeCategory` — where every mapper puts income
    /// it has not been told about. Its kind is not a choice.
    private var isDefaultIncome: Bool { category == BudgetMath.defaultIncomeCategory }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тип категорії")
                .font(Theme.font(14, .semibold)).foregroundStyle(Theme.inkMuted)
            Picker("Тип категорії", selection: Binding(
                get: { store.categories.first { $0.name == category }?.resolvedKind ?? .spending },
                set: { store.setCategoryKind(category, $0) })) {
                    ForEach(CategoryKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isDefaultIncome)
                .accessibilityIdentifier("category.kind")
            // Disabled with a REASON, never a control that quietly ignores the
            // tap: `setCategoryKind` refuses this one, and a segmented control
            // that springs back with no explanation is how a person concludes
            // the app is broken.
            Text(isDefaultIncome
                 ? "Сюди потрапляють усі надходження, які додаток ще не розібрав, тому це завжди дохід."
                 : "Дохід перерахується за всі місяці, а не лише за наступні.")
                .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 4)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // The swatch itself, at the size the feed draws it, so the
                    // choice is judged against the thing it will actually be:
                    // an icon on THIS category's wash, not a glyph on a grid.
                    HStack(spacing: 12) {
                        CategorySwatch(category, size: 40, cornerRadius: 12)
                        Text(category).font(Theme.font(18, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("icons.preview")

                    kindPicker

                    ForEach(CategoryIcon.groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LocalizedStringKey(group.title))
                                .font(Theme.font(14, .semibold)).foregroundStyle(Theme.inkMuted)
                            LazyVGrid(columns: Self.columns, spacing: 12) {
                                ForEach(group.icons, id: \.self) { cell($0) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            // «Категорія», not «Значок»: board #94 put the kind on this sheet
            // too, and a title naming one of the two things a screen does is
            // how somebody decides the other one is not there.
            .navigationTitle("Категорія")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("icons.sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .accessibilityIdentifier("icons.done")
                }
            }
        }
    }

    /// **Selection is green, not the category's own wash.** Tinting the chosen
    /// cell with the category's colour was the first version, and #57's guard
    /// refused it — correctly. That guard says only `CategorySwatch` turns an
    /// index into a colour, and the alternative was to widen its exemption
    /// list for a screen that is not drawing a swatch at all.
    ///
    /// Green is also what selection means everywhere else in this app, and the
    /// preview above already shows the icon on the real wash — which is the
    /// thing being judged. The grid's job is only to say which cell is current.
    private func cell(_ icon: String) -> some View {
        let chosen = store.iconName(for: category) == icon
        return Button {
            store.setIcon(icon, for: category)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(chosen ? Theme.green : Theme.inkSoft)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(chosen ? Theme.greenWash : Theme.card)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
        .accessibilityIdentifier("icons.cell.\(icon)")
    }
}

extension CategoryKind {
    /// «Подарунок», singular, because it labels ONE category — «Подарунки» is
    /// the seeded category's own NAME and would read as a reference to it.
    var title: LocalizedStringKey {
        switch self {
        case .spending: "Витрата"
        case .earned: "Дохід"
        case .unearned: "Подарунок"
        }
    }
}
