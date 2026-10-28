import SwiftUI

/// Edits the lines. Save is refused until the percentages total exactly 100 —
/// a plan that adds to 90% is not a plan with 10% spare, it is a plan whose
/// author was interrupted.
struct PercentEditorView: View {
    let budget: Budget?
    var onSave: (Budget) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var incomeBase: IncomeBase
    @State private var lines: [Budget.Line]
    @State private var pickingCategoryFor: UUID?
    @State private var addingCategory = false
    @State private var editingIncome = false
    /// Non-nil right after a category pick was refused for already being on
    /// the plan — `CategoryPicker` dismisses unconditionally on `onPick`, so
    /// without this the sheet closing looks identical to the pick succeeding.
    @State private var refusedCategory: String?

    init(budget: Budget?, onSave: @escaping (Budget) -> Void) {
        self.budget = budget
        self.onSave = onSave
        let start = budget ?? Budget.starter()
        _incomeBase = State(initialValue: start.incomeBase)
        _lines = State(initialValue: start.lines)
    }

    private var income: Int {
        BudgetMath.monthlyIncome(Budget(incomeBase: incomeBase, lines: lines),
                                 txs: store.transactions, now: Date(),
                                 categories: store.categories)
    }

    private var complete: Bool { BudgetMath.isComplete(lines, income: income) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if budget == nil {
                        Text("Це лише приклад, з якого зручно почати — змініть під себе.")
                            .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("editor.starterNote")
                    }

                    if let refusedCategory {
                        Text("«\(refusedCategory)» вже є у плані — змініть відсоток наявного рядка.")
                            .font(Theme.font(14)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("editor.duplicateNote")
                    }

                    Button { editingIncome = true } label: {
                        Card {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Дохід на місяць")
                                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                                    Text(income.uah)
                                        .font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("editor.income")

                    ForEach($lines) { $line in
                        lineCard($line)
                    }

                    Button { addingCategory = true } label: {
                        Card {
                            HStack {
                                Image(systemName: "plus")
                                Text("Додати статтю").font(Theme.font(16, .medium))
                                Spacer()
                            }
                            .foregroundStyle(Theme.green)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("editor.addLine")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            // Neither `.numberPad` nor `.decimalPad` has a return key, so a
            // drag is the only way off the percent and ₴ fields — same reason
            // `Banks/TokenView` carries this.
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle("План")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .sheet(isPresented: $editingIncome) {
                IncomeBaseView(base: incomeBase) { incomeBase = $0 }
            }
            .sheet(isPresented: $addingCategory) {
                CategoryPicker(selected: nil, purpose: .planLine) { picked in
                    switch picked {
                    case .notAnExpense:
                        // unreachable: `.planLine` names a BUDGET LINE,
                        // and a budget line cannot be "not an expense", so
                        // that row is never rendered.
                        break
                    case .category(let name):
                        // A brand-new line naming a category the plan already
                        // has would collide with that line's accessibility
                        // identifiers (`editor.percentField.<category>`,
                        // `editor.delete.<category>`) and double-count the
                        // category's own percent input — so the pick is
                        // refused, not silently: `CategoryPicker` dismisses
                        // unconditionally, so `refusedCategory` is what tells
                        // the user the tap did nothing.
                        guard !lines.contains(where: { $0.category == name }) else {
                            refusedCategory = name
                            return
                        }
                        refusedCategory = nil
                        // 1, not 0: the spec's range starts at 1, and a saved
                        // 0% line marks every single purchase in that
                        // category as over plan.
                        lines.append(.init(id: UUID(), category: name, percent: 1))
                    }
                }
            }
            .sheet(item: Binding(get: { pickingCategoryFor.map(Identified.init) },
                                 set: { pickingCategoryFor = $0?.id })) { target in
                CategoryPicker(selected: lines.first { $0.id == target.id }?.category,
                               purpose: .planLine) { picked in
                    switch picked {
                    case .notAnExpense:
                        // unreachable: `.planLine` names a BUDGET LINE,
                        // and a budget line cannot be "not an expense", so
                        // that row is never rendered.
                        break
                    case .category(let name):
                        guard let i = lines.firstIndex(where: { $0.id == target.id }) else { return }
                        // Retargeting a line onto a category another line
                        // already owns would produce two rows sharing one
                        // category — the same identifier collision the
                        // add-line guard above avoids, plus a plan that
                        // silently forgets one line's percent. Refused rather
                        // than merged: merging would discard whichever line's
                        // percent lost the coin flip, and that is a bigger
                        // surprise than the tap doing nothing.
                        guard !lines.contains(where: { $0.id != target.id && $0.category == name })
                        else {
                            refusedCategory = name
                            return
                        }
                        refusedCategory = nil
                        lines[i].category = name
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.title")
        }
    }

    /// `sheet(item:)` needs an Identifiable; a bare UUID is not one.
    private struct Identified: Identifiable { let id: UUID }

    /// The line's planned sum in whole ₴, as a two-way view onto its
    /// percentage — which stays the stored truth, so the plan still totals
    /// 100% and still tracks the income base when the average moves.
    ///
    /// Writes are refused when the base is zero (no data yet, or a fixed base
    /// of 0): the conversion divides by it. The field is `.disabled` in that
    /// state too, so this guard is the belt to that view's braces.
    private func amount(_ line: Binding<Budget.Line>) -> Binding<Int> {
        Binding(
            get: { BudgetMath.plannedMajor(percent: line.wrappedValue.percent, income: income) },
            set: { major in
                guard let percent = BudgetMath.percentFor(major: major, income: income) else { return }
                line.wrappedValue.percent = percent
            }
        )
    }

    private func lineCard(_ line: Binding<Budget.Line>) -> some View {
        Card {
            VStack(spacing: 8) {
                HStack {
                    Button { pickingCategoryFor = line.wrappedValue.id } label: {
                        Text(line.wrappedValue.category)
                            .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        lines.removeAll { $0.id == line.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("editor.delete.\(line.wrappedValue.category)")
                }
                HStack(spacing: 6) {
                    // The spec asks for a stepper AND direct entry. The
                    // stepper alone would make "set this to 45" forty-five
                    // taps, and is the only affordance a UI test can drive
                    // to an exact value in reasonable time.
                    //
                    // At most one decimal shown. The stored value carries
                    // more (an exact ₴ amount rarely lands on a tenth of a
                    // percent), so committing an edit HERE snaps the line to
                    // what is displayed — which is the honest reading of
                    // "I set this line to 10,7%".
                    TextField("", value: line.percent,
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .font(Theme.font(20, .bold)).foregroundStyle(Theme.ink)
                        .frame(minWidth: 46, alignment: .leading)
                        .accessibilityIdentifier("editor.percentField.\(line.wrappedValue.category)")
                    Text("%").font(Theme.font(20, .bold)).foregroundStyle(Theme.ink)
                    // Whole percents, and it SNAPS: from 10,7% up is 11%, not
                    // 11,7%. This is the coarse affordance — the two text
                    // fields either side of it are the fine ones, and a
                    // stepper that lands on 11,7% serves nobody. Clamped
                    // 1...100 per the spec; both text fields are left
                    // unclamped on purpose, because clamping mid-typing makes
                    // "30" untypeable — the "3" would be committed first.
                    Stepper("") {
                        line.wrappedValue.percent = min(100, line.wrappedValue.percent.rounded(.down) + 1)
                    } onDecrement: {
                        line.wrappedValue.percent = max(1, line.wrappedValue.percent.rounded(.up) - 1)
                    }
                        .labelsHidden()
                        .accessibilityIdentifier("editor.stepper.\(line.wrappedValue.category)")
                    // The same line from the other end. One whole percent is
                    // ~467 ₴ on this owner's income, so a plan that could only
                    // be set in whole percents could not express "5 000 ₴ for
                    // groceries" at all.
                    TextField("", value: amount(line), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(income <= 0)
                        .accessibilityIdentifier("editor.amountField.\(line.wrappedValue.category)")
                    Text("₴").font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        // No identifier on this Card: it is a plain VStack, not a Button or
        // an `.accessibilityElement(children: .contain)` container, so a
        // bare identifier here would smother `editor.delete.<category>`,
        // `editor.percentField.<category>` and `editor.stepper.<category>`
        // beneath it rather than living alongside them. Nothing queries
        // `editor.row.<category>` — it was dead weight that broke live ids.
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(BudgetMath.allocationText(lines, income: income, store.settings.languageChoice))
                .font(Theme.font(15, .medium))
                .foregroundStyle(complete ? Theme.green : Theme.clay)
                .accessibilityIdentifier("editor.total")
            PrimaryButton(title: "Зберегти") {
                onSave(Budget(incomeBase: incomeBase, lines: lines))
                dismiss()
            }
            .disabled(!complete)
            .opacity(complete ? 1 : 0.4)
            .accessibilityIdentifier("editor.save")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .background(Theme.bg)
    }
}
