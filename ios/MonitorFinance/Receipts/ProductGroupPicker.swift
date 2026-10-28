import SwiftUI

/// The PRODUCT GROUP picker — what was bought, never `Transaction.category`
/// (where the money went). Modelled on `Categories/CategoryPicker.swift`'s
/// shape (search field, list, dismiss-on-pick) but deliberately not reusing
/// it: that one lists SPENDING categories, the wrong namespace entirely.
struct ProductGroupPicker: View {
    let selected: String?
    /// The receipt line this picker was opened for. Not shown — it is what a
    /// newly created group learns its keyword from, so the next «Coca-Cola»
    /// places itself instead of being picked by hand forever. Board #184.
    var item: String = ""
    var onPick: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// `store.productGroups` order, unfiltered or filtered by substring —
    /// never re-sorted. The store's own order puts «Інше» last on purpose;
    /// an alphabetical sort (as `CategoryPicker` does for spending
    /// categories) would move it into the middle of the list instead.
    private var matches: [ProductGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.productGroups }
        return store.productGroups.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { group in
                    row(group)
                }
                if let name = creatable {
                    Section { createRow(name) }
                }
            }
            .searchable(text: $query, prompt: "Пошук товарної групи")
            .navigationTitle("Товарна група")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("groupPicker.list")
            .toolbar {
                Button("Скасувати") { dismiss() }.accessibilityIdentifier("groupPicker.cancel")
            }
        }
    }

    /// What the search field would create, or nil when it would create
    /// nothing. Trimmed, and suppressed once an existing group already carries
    /// that name — offering «Створити «Ліки»» under a visible «Ліки» row is an
    /// offer to make a duplicate, and `addProductGroup` would fold it anyway.
    /// `CategoryPicker` reaches the same conclusion for spending categories.
    private var creatable: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let taken = store.productGroups.contains {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        return taken ? nil : trimmed
    }

    /// The row board #184 is about. `addProductGroup` returns the stored name
    /// so the pick reports what was actually saved rather than what was typed
    /// — they differ when a name folds into a group that already existed.
    private func createRow(_ name: String) -> some View {
        Button {
            guard let stored = store.addProductGroup(name, from: item) else { return }
            onPick(stored)
            dismiss()
        } label: {
            Label("Створити «\(name)»", systemImage: "plus.circle")
                .foregroundStyle(Theme.green)
        }
        .accessibilityIdentifier("groupPicker.create")
    }

    private func row(_ group: ProductGroup) -> some View {
        Button {
            onPick(group.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(group.name).foregroundStyle(Theme.ink)
                Spacer()
                if group.name == selected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.green)
                }
            }
        }
        .accessibilityIdentifier("groupPicker.\(group.name)")
    }
}
