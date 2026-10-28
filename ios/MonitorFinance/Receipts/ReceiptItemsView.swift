import SwiftUI

/// A receipt's line items, and nothing around them. Reused verbatim in two
/// places — the detail screen's receipt card, and the expanded feed row — so
/// it assumes neither: no navigation, no fixed width, no `Card` of its own.
/// The caller decides the chrome; this decides only the rows.
///
/// Task 5: `editable` turns on a per-line PRODUCT GROUP button and a confirm
/// footer. Defaults to `false` so the detail card, which passes neither
/// argument, is unchanged — only the feed's expanded row opts in.
struct ReceiptItemsView: View {
    let receipt: Receipt
    var editable = false

    @Environment(AppStore.self) private var store
    @State private var picking: UUID?
    /// Non-nil right after a confirm was refused — `SplitMath.Outcome
    /// .receiptExceedsPurchase`, the receipt's own items summing past the
    /// purchase. Cleared on the next successful confirm; never cleared just
    /// because a picker sheet closed, so the message survives a group edit
    /// until the human tries again.
    @State private var refusal: String?

    /// The one visible difference between "a receipt with goods" and "a receipt
    /// recognised, no goods" — the state every real on-device scan produces.
    /// A constant so a test can assert on the copy the view actually renders.
    static let emptyText = "Чек розпізнано, товари з'являться після синхронізації"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if receipt.items.isEmpty {
                // The honest state for a real QR scanned on a device: the
                // mock decoder only knows the bundled samples, so anything
                // else comes back with the fiscal totals but no goods. Not
                // an error — no clay, no warning glyph.
                Text(LocalizedStringKey(Self.emptyText))
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    // `receipt.empty`, not `detail.receipt.empty`: this view is
                    // shared by the detail card and the expanded feed row, so a
                    // `detail.*` name renders on Стрічка too — and detail's own
                    // "the goods arrived" assertion would then go red for the
                    // wrong reason the moment a feed row below it was expanded
                    // over an item-less receipt.
                    .accessibilityIdentifier("receipt.empty")
            } else {
                ForEach(receipt.items) { item in
                    row(item)
                }
                if editable {
                    footer
                }
            }
        }
        // Attached here rather than on a leaf: `sheet(item:)` needs exactly
        // one presenter, and this view has no `Card` or navigation chrome of
        // its own to hang it from either place it is embedded.
        .sheet(item: Binding(get: { picking.map(Identified.init) },
                             set: { picking = $0?.id })) { target in
            // `item:` is the line's own name — what a group created here
            // learns its keyword from. Board #184.
            ProductGroupPicker(selected: currentGroup(for: target.id),
                               item: itemName(for: target.id)) { name in
                store.setItemGroup(target.id, on: receipt.id, to: name)
            }
        }
    }

    /// The item's own drafted group when it has one — the same field
    /// `SplitMath.build` prefers — else the keyword guess. What the trailing
    /// button shows, and what the picker opens pre-checked on.
    private func currentGroup(for itemId: UUID) -> String? {
        guard let item = receipt.items.first(where: { $0.id == itemId }) else { return nil }
        return item.category ?? ProductGuess.group(for: item.name, in: store.productGroups)
    }

    /// The line's own product name, for the picker's create row to learn a
    /// keyword from. Empty when the item has gone — a group created from
    /// nothing simply gets no keyword, which is better than refusing to open.
    private func itemName(for itemId: UUID) -> String {
        receipt.items.first(where: { $0.id == itemId })?.name ?? ""
    }

    private func row(_ item: Receipt.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.font(15, .medium)).foregroundStyle(Theme.ink)
                // Only when the quantity says something the sum alone does
                // not — "1 ×" in front of every single-unit line would be
                // noise, not information.
                if item.qty != 1 {
                    Text("\(Self.qty(item.qty)) × \(item.price.uahExact)")
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.sum.uahExact)
                    .font(Theme.font(15, .medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: true, vertical: false)
                // A trailing button under the sum, offered only when
                // editable — the detail card's read-only receipt never
                // grows one. Shows the item's own drafted group when it has
                // one, else the keyword guess, so the human confirms or
                // corrects a real answer rather than a blank.
                if editable {
                    Button {
                        picking = item.id
                    } label: {
                        Text(currentGroup(for: item.id) ?? ProductGuess.other)
                            .font(Theme.font(13, .medium)).foregroundStyle(Theme.green)
                    }
                    .buttonStyle(.plain)
                    // Keyed by the ITEM's id, not the receipt's — one receipt
                    // has many items, each with its own group to confirm.
                    .accessibilityIdentifier("receipt.item.group.\(item.id.uuidString)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both leaves keyed by the RECEIPT's id, the same way each item row
    /// above is keyed by its item's. Feed rows expand independently — two
    /// expanded receipts sit in the accessibility tree at once — so a bare
    /// `receipt.confirm` named two different buttons, and a query for it
    /// resolved to whichever one the tree happened to list first. That is
    /// the failure mode this repo has lost assertions to before: the test
    /// finds *a* control, taps it, and reports on a screen it never touched.
    /// The mismatch as it stands, without anybody having pressed anything.
    ///
    /// **Board #80 made this necessary.** `refusal` only ever appeared as an
    /// answer to a tap, which was fine while the only way to reach a mismatch
    /// was to cause one. A hold that settles BELOW its receipt's own items
    /// creates one while nobody is looking — the sync clears the splits and
    /// the screen went on offering «Підтвердити» as though it would work.
    ///
    /// Computed rather than stored: it is a fact about the current amount and
    /// the current receipt, and a copy of it would be one more thing to keep
    /// in step with a background sync.
    ///
    /// The decision itself is `AppStore.splitMismatch(forReceipt:)` — as a
    /// private property here it was untestable, and a mutation making it fire
    /// on every receipt passed the entire suite.
    private var standingMismatch: String? {
        store.splitMismatch(forReceipt: receipt.id)
            .map { Self.refusalText($0, store.settings.languageChoice) }
    }

    /// One wording for both paths, so the message a settled hold produces and
    /// the message a tap produces cannot drift apart.
    static func refusalText(_ by: Int, _ language: AppLanguage) -> String {
        String(format: L10n.t("Чек більший за покупку на %@ — не можемо розподілити", language),
               by.uahExact)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The tap's answer wins when there is one: it is the more recent
            // fact, and after a successful confirm it is deliberately nil.
            if let refusal = refusal ?? standingMismatch {
                // `verbatim`: `refusalText` translates at the source, where
                // the ₴ figure is substituted into the format.
                Text(verbatim: refusal)
                    .font(Theme.font(13)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("receipt.splitRefused.\(receipt.id.uuidString)")
            }
            PrimaryButton(title: "Підтвердити") { confirm() }
                .accessibilityIdentifier("receipt.confirm.\(receipt.id.uuidString)")
        }
        .padding(.top, 4)
    }

    /// `confirmSplits` answers `.ok([])` in two situations that look
    /// identical from its return value alone: a receipt that genuinely has
    /// no items, and "no transaction or receipt to work from". This is the
    /// one caller that can race that second case for real — the row can sit
    /// expanded in the feed while the receipt is detached from the detail
    /// screen underneath it — so the transaction is resolved HERE first, and
    /// finding none reports nothing rather than a confirmation that never
    /// happened.
    private func confirm() {
        guard let id = store.transactions.first(where: { $0.receiptId == receipt.id })?.id else {
            return
        }
        switch store.confirmSplits(for: id) {
        case .ok:
            refusal = nil
        case .receiptExceedsPurchase(let by):
            refusal = Self.refusalText(by, store.settings.languageChoice)
        }
    }

    /// `sheet(item:)` needs an Identifiable; a bare UUID is not one.
    private struct Identified: Identifiable { let id: UUID }

    /// `qty` is a `Double` so a whole unit still reads "1", never "1.0", and a
    /// weighed item reads "1,24" with the Ukrainian comma rather than a dot.
    private static let qtyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        // Explicit, not the device's: a formatter left on the system locale
        // re-derives everything the two lines below do not pin (grouping size,
        // digits) from whatever region the phone is set to.
        f.locale = L10n.formatting.locale
        f.decimalSeparator = ","
        f.groupingSeparator = " "
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// Widened from `private` — Task 9's fuel card in `StatsView` needs the
    /// SAME litre spelling the item row above uses (`10,53 ×` there,
    /// `10,53 л` there): one formatter, not a second one that could drift
    /// from this one. If a third caller ever needs it, move this and
    /// `qtyFormatter` to `Theme.swift` beside `uahExact` — not before.
    static func qty(_ value: Double) -> String {
        qtyFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

#Preview {
    let receipt = Receipt(
        id: UUID(), scannedAt: Date(), registerNumber: "4000123456", documentNumber: "1000000001",
        // An INVENTED seller. Never a merchant from `demo.json` — see the
        // privacy rule, and the pytest guard that now enforces it.
        fiscalTime: Date(), fiscalSum: 15000, sellerName: "Магазин «Затишок»",
        items: [
            Receipt.Item(id: UUID(), name: "Хліб український", qty: 1, price: 3200, sum: 3200, category: nil),
            Receipt.Item(id: UUID(), name: "Яблука", qty: 1.24, price: 4500, sum: 5580, category: nil),
        ])
    return ReceiptItemsView(receipt: receipt)
        .padding()
        .background(Theme.bg)
}
