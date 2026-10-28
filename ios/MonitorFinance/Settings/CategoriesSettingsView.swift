import SwiftUI

/// Rename, merge and delete. Merge is deliberately expressed as "rename onto an
/// existing name" in the store, so there is one code path and no way for the
/// two to disagree about what happens to the rules.
struct CategoriesSettingsView: View {
    /// Only so «Правила» below can push. Everything else on this screen acts on
    /// the store in place.
    @Binding var path: [SettingsRoute]
    @Environment(AppStore.self) private var store
    @State private var renaming: String?
    @State private var draft = ""
    @State private var deleting: String?
    @State private var choosingIconFor: String?

    private var names: [String] { Category.alphabetical(store.categories.map(\.name)) }

    private func count(_ name: String) -> Int {
        store.transactions.filter { $0.category == name }.count
    }


    var body: some View {
        List {
            // First, above the categories themselves: a wrong rule is the
            // thing on this screen a person arrives wanting to undo, and it
            // was the one thing they could not (board #11). The count is what
            // says the screen has anything on it.
            Section {
                Button { path.append(.rules) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 17)).foregroundStyle(Theme.green).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Правила").foregroundStyle(Theme.ink)
                            Text("Продавці, яких додаток розбирає сам")
                                .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        Text("\(store.rules.count)")
                            .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.open.rules")
            }
            ForEach(names, id: \.self) { name in
                // Tapping the row chooses the icon (board #61). Rename and
                // delete stay on the swipe: they were there first, they are
                // the destructive pair, and a tap that renamed would be the
                // wrong thing to reach by accident.
                Button { choosingIconFor = name } label: {
                    HStack(spacing: 12) {
                        CategorySwatch(name, size: 24, cornerRadius: 6)
                        Text(name).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        // `fixedSize`: the count is the shorter half and the one
                        // that stops making sense when it truncates — «12 опера…»
                        // is worse than a shortened category name beside it.
                        // Board #94, and only when it is NOT spending:
                        // nineteen rows reading «Витрата» say nothing, while
                        // the two that say «Дохід» say everything.
                        if let kind = kindOf(name), kind != .spending {
                            Text(kind.title)
                                .font(Theme.font(12, .medium)).foregroundStyle(Theme.green)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.greenWash, in: Capsule())
                                .fixedSize()
                        }
                        Text(Plural.operations(count(name), store.settings.languageChoice))
                            .font(Theme.font(14)).foregroundStyle(Theme.inkMuted).fixedSize()
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.categories.row.\(name)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = name } label: { Text("Видалити") }
                        .accessibilityIdentifier("settings.categories.delete.\(name)")
                    Button { renaming = name; draft = name } label: { Text("Перейменувати") }
                        .tint(Theme.green)
                        .accessibilityIdentifier("settings.categories.rename.\(name)")
                }
            }
        }
        .navigationTitle("Категорії")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.categories")
        // Same `Binding(get:set:)` idiom as the alert and the dialog below —
        // one optional holds both "is it open" and "which category".
        .sheet(isPresented: Binding(get: { choosingIconFor != nil },
                                    set: { if !$0 { choosingIconFor = nil } })) {
            if let name = choosingIconFor { CategoryIconPicker(category: name) }
        }
        .alert("Нова назва", isPresented: Binding(get: { renaming != nil },
                                                  set: { if !$0 { renaming = nil } })) {
            TextField("Назва", text: $draft).accessibilityIdentifier("settings.categories.field")
            Button("Скасувати", role: .cancel) { renaming = nil }
            Button("Зберегти") {
                if let old = renaming { store.renameCategory(old, to: draft) }
                renaming = nil
            }
            .accessibilityIdentifier("settings.categories.renameSave")
        } message: {
            // Renaming onto an existing name merges. Saying so up front is the
            // difference between a feature and a surprise.
            Text("Якщо така категорія вже є, дві об'єднаються в одну.")
        }
        .confirmationDialog("Видалити категорію?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Видалити", role: .destructive) {
                if let name = deleting { store.deleteCategory(name) }
                deleting = nil
            }
            .accessibilityIdentifier("settings.categories.deleteConfirm")
            Button("Скасувати", role: .cancel) { deleting = nil }
        } message: {
            // `.map { … } ?? ""` produces a `String`, which took `Text`'s
            // verbatim overload — so the catalogue's translation of this line
            // sat unread while an English reader saw Ukrainian. `Plural`
            // carries the count so the one hardcoded «операцій» stops being
            // wrong for 1 and 2 as well.
            Text(verbatim: deleting.map(deleteMessage) ?? "")
        }
    }

    /// Translated here, not at the `Text`: `Plural.operations` returns a
    /// finished phrase, so by the time the sentence exists there is no literal
    /// left for the catalogue to match. `«Інше»` is a category name — the
    /// person's data — and stays as it is in both languages.
    private func deleteMessage(_ name: String) -> String {
        let language = store.settings.languageChoice
        return String(format: L10n.t("%@ перейдуть до «Інше».", language),
                      Plural.operations(count(name), language))
    }

    private func kindOf(_ name: String) -> CategoryKind? {
        store.categories.first { $0.name == name }?.resolvedKind
    }

}
