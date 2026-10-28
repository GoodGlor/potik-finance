import SwiftUI

/// Розібрати's two receipt cards (A5/D2): the ONLY two questions a receipt can
/// leave for a person, per `ReceiptCard`'s own doc comment on
/// `AppStore+Receipts.swift`. A receipt still waiting on its goods, or still
/// inside its retry window, is never a card and never rendered here.
struct ReceiptQueueCard: View {
    let card: ReceiptCard
    @Environment(AppStore.self) private var store
    @State private var picking = false
    /// Board #185's sheet — the item sorter, opened from the queue instead of
    /// from a transaction the person would have to find again in the feed.
    @State private var sorting = false

    private var receipt: Receipt {
        switch card {
        case .noPurchase(let receipt): return receipt
        case .notPublished(let receipt): return receipt
        case .itemsWaiting(let receipt): return receipt
        }
    }

    var body: some View {
        Card {
            Text(receipt.displaySeller).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text(receipt.fiscalSum.uahExact).font(Theme.font(22, .bold)).foregroundStyle(Theme.ink)
            switch card {
            case .noPurchase:
                Text("Не знайшли покупку, до якої підходить цей чек.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                actions {
                    Button("Вибрати покупку") { picking = true }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("queue.receipt.pick.\(receipt.id.uuidString)")
                }
            case .notPublished:
                Text("Досі не опублікували в кабінеті ДПС — спробуємо ще раз.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                actions {
                    Button("Спробувати ще раз") { store.retryNow(receipt.id, now: Date()) }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("queue.receipt.retry.\(receipt.id.uuidString)")
                }
            case .itemsWaiting:
                // Board #185. The count, not «є товари»: how much work this is
                // decides whether somebody opens it now or after dinner, and a
                // card that will not say is one they open to find out.
                Text("Товари з чека чекають — \(Plural.products(receipt.items.count, store.settings.languageChoice)).")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                actions {
                    Button("Розібрати товари") { sorting = true }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("queue.receipt.sort.\(receipt.id.uuidString)")
                }
            }
        }
        // `.contain` first, THEN the identifier — the pattern this codebase
        // repeats everywhere a card carries live buttons beneath it
        // (`detail.receipt`, `scanner.title`, `feed.title`…): a bare
        // identifier on a container stamps every descendant and swallows
        // the buttons underneath it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.receipt.\(receipt.id.uuidString)")
        .sheet(isPresented: $picking) {
            ReceiptPurchasePicker(receipt: receipt) { txId in
                store.attachManually(receipt.id, to: txId)
            }
        }
        // Board #185. `ReceiptItemsView(editable:)` unchanged and unwrapped:
        // it already is the item sorter, group picker and «Підтвердити»
        // included, and it is the same one the feed's expanded row shows. A
        // second implementation here would be a second thing to keep correct
        // and would drift the first time either changed.
        // Presented BY the card, which has a consequence worth naming: once
        // «Підтвердити» writes the splits this receipt leaves `receiptCards`,
        // SwiftUI tears this view down, and the sheet closes with it. That
        // reads correctly — sorting the goods closes the sheet you sorted them
        // in — so «Готово» is the OTHER exit: opened it, changed your mind.
        .sheet(isPresented: $sorting) {
            NavigationStack {
                ScrollView {
                    Card { ReceiptItemsView(receipt: receipt, editable: true) }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .navigationTitle("Товари з чека")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // `ToolbarItem`, not a bare `Button`: a bare one is placed
                    // by SwiftUI in a wrapper that does not carry the modifier
                    // through, and the identifier never reaches the tree —
                    // found by a UI test that could see the sheet and not its
                    // own dismiss button.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Готово") { sorting = false }
                            .accessibilityIdentifier("queue.receipt.sortDone")
                    }
                }
            }
            // `.contain` FIRST, then the identifier — the same pattern this
            // file already uses on the card above, and for the same reason. A
            // bare identifier on a container stamps every descendant: it
            // swallowed «Готово», which a UI test then could not find on a
            // sheet it could see.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.receipt.sorter")
        }
    }

    /// The one row shared by both cards: the card's own live action, on the
    /// left, and delete on the right.
    private func actions(@ViewBuilder primary: () -> some View) -> some View {
        HStack(spacing: 18) {
            primary()
            Spacer(minLength: 8)
            Button("Видалити") { store.deleteReceipt(receipt.id) }
                .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                .frame(minHeight: 44)
                .accessibilityIdentifier("queue.receipt.delete.\(receipt.id.uuidString)")
        }
    }
}

/// "Which purchase?" — the manual pick behind a `.noPurchase` card.
/// `ReceiptMatch.candidates` first (nearest-in-time, sum-exact — the same
/// list `sole` itself already tried and failed to narrow to one), then every
/// other unclaimed expense so a sum that disagrees is still reachable:
/// `AppStore.attachManually` tolerates that on purpose (A6), and a list that
/// only ever offered exact sums could never exercise it.
struct ReceiptPurchasePicker: View {
    let receipt: Receipt
    var onPick: (Transaction.ID) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [Transaction] { ReceiptMatch.candidates(for: receipt, in: store.transactions) }

    private var rest: [Transaction] {
        let already = Set(candidates.map(\.id))
        return store.transactions
            .filter { $0.amount < 0 && $0.receiptId == nil && !already.contains($0.id) }
            .sorted {
                abs($0.date.timeIntervalSince(receipt.fiscalTime)) < abs($1.date.timeIntervalSince(receipt.fiscalTime))
            }
    }

    private var rows: [Transaction] { Derived.search(candidates + rest, query) }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    Text("Немає покупок без чека").font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { tx in
                        Button {
                            onPick(tx.id)
                            dismiss()
                        } label: {
                            TransactionRow(tx)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("queue.receipt.pickRow.\(tx.id.uuidString)")
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Продавець або категорія")
            .navigationTitle("Яка це покупка?")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.receipt.pickList")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
            }
        }
    }
}
