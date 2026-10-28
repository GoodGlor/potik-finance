import SwiftUI

/// One card per merchant, biggest first. The store owns the queue, so the
/// badge, the Home card and this screen cannot disagree — there is nothing to
/// keep in sync.
struct QueueView: View {
    var onDone: () -> Void
    @Environment(AppStore.self) private var store
    @State private var showAll = false
    @State private var picking: MerchantGroup?
    /// Board #103. Selection mode, and what is in it — **group ids**, not
    /// indices: the list re-sorts as cards leave it, and an index would start
    /// pointing at whatever moved up.
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pickingBulk = false
    @State private var scanning = false
    /// **Text AND whether it can be taken back. Board #185.**
    ///
    /// It was a bare `String?` and every toast carried «Скасувати», because
    /// every toast was a categorization. Board #185 added one that is not —
    /// «чек додано» — and on that toast the undo button would have called
    /// `undoLast()` and silently reverted the PREVIOUS card the person
    /// answered. Not a no-op: a wrong, invisible one, on the app's most-used
    /// screen, reachable by tapping a button that says it cancels the thing
    /// just done.
    @State private var toast: Toast?
    @State private var toastWork: DispatchWorkItem?

    /// What this session started with, for «3 з 11» and for the done screen.
    /// Captured on first appearance so the denominator does not shrink as the
    /// user works through the queue — and RAISED, never lowered, when a sync
    /// lands mid-session. See `QueueView.raised`.
    @State private var start: Baseline?

    /// Two scales, because the two places that count down are asking different
    /// questions. Progress is «3 з 11» in CARDS — the unit the screen is in,
    /// one card answered is one step. The done screen congratulates in
    /// PURCHASES, because "you sorted 66 purchases" is what was actually
    /// achieved and «12 запитань» is not a thing anybody set out to do.
    ///
    /// One value would have made one of them lie the moment board #8 moved
    /// the badge to cards.
    struct Baseline: Equatable {
        var cards: Int
        var rows: Int
    }

    /// One line at the bottom of the queue, and whether it can be taken back.
    /// Board #185 — see `toast` for what a bare `String?` cost.
    struct Toast: Equatable {
        var text: String
        /// `false` for a toast that only REPORTS. `undoLast()` pops whatever
        /// is on the undo stack, which for a non-categorization toast is the
        /// previous card — so this is not "a button that does nothing", it is
        /// the difference between an undo and a wrong one.
        var undoable: Bool
    }

    /// A5: the receipt cards a person still has to answer — see
    /// `AppStore.receiptCards`'s own doc comment for exactly which two
    /// situations qualify.
    private var receiptCards: [ReceiptCard] { store.receiptCards() }

    var body: some View {
        // Built ONCE per render and handed down (board #8). `pendingGroups`
        // walks every transaction, normalizes each pending merchant, tallies
        // the suggestion chips and sorts the result; it was being asked for
        // five times in this body — twice to pick a branch, once for the list,
        // twice more in the footer — and `queuedGroups` builds it again on top
        // of that. Six full passes to draw one screen.
        let all = store.pendingGroups
        let shown = showAll ? all : AppStore.capped(all)
        let receipts = receiptCards
        // The screen counts what the screen is showing, rather than asking the
        // store for `queueCardCount` and walking every pending row a second
        // time to get the same integer. That the two agree is not a hope —
        // `pendingCardCount` and `pendingGroups.count` are pinned equal by
        // `testTheCardCountIsExactlyTheNumberOfCardsTheScreenWouldShow`, and
        // both sides add the same receipt cards.
        let cards = all.count + receipts.count
        return NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if all.isEmpty && receipts.isEmpty && store.transactions.isEmpty {
                        emptyWaitingScreen
                    } else if all.isEmpty && receipts.isEmpty {
                        doneScreen
                    } else {
                        list(all: all, shown: shown, receipts: receipts)
                    }
                }
                if let toast { toastBar(toast) }
            }
            .background(Theme.bg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.title")
            .navigationTitle("Розібрати")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Self.progressText(start: start?.cards, remaining: cards,
                                           store.settings.languageChoice))
                        .font(Theme.font(15, .medium))
                        .foregroundStyle(Theme.inkSoft)
                        .accessibilityIdentifier("queue.progress")
                }
                // D2: the one scanner in the app, here because Розібрати is
                // already the screen for "things the app needs you to
                // answer" — a fiscal QR carries no purchase to point back
                // at, so there is no per-purchase button to offer any more.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { scanning = true } label: {
                        Image(systemName: "qrcode.viewfinder").foregroundStyle(Theme.green)
                    }
                    .accessibilityIdentifier("queue.scan")
                }
                // Board #103. Offered only when there is more than one card to
                // pick from — a selection mode over a single card is one extra
                // tap for the same answer.
                if all.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selecting ? "Готово" : "Вибрати") { toggleSelecting() }
                            .font(Theme.font(15, .semibold)).foregroundStyle(Theme.green)
                            .accessibilityIdentifier("queue.select")
                    }
                }
            }
            .sheet(item: $picking) { group in
                // The group carries the kind — income and expense are already
                // separate cards for the same merchant — so the picker can be
                // told what it is answering about.
                CategoryPicker(selected: nil,
                               purpose: group.kind == .income ? .income : .expense) { choice in
                    apply(group, choice)
                    picking = nil
                }
            }
            .sheet(isPresented: $pickingBulk) {
                // The kind the selection is fixed to — the same value the
                // single-card path reads off its group, and the reason a mixed
                // selection is impossible: there would be no answer to give here.
                CategoryPicker(selected: nil,
                               purpose: selectionKind(in: store.pendingGroups) == .income
                               ? .income : .expense) { choice in
                    applyBulk(choice)
                    pickingBulk = false
                }
            }
            .sheet(isPresented: $scanning) {
                ScannerView { check in
                    let receipt = store.scan(check, now: Date())
                    scanning = false
                    // Board #185. **Told once, and not asked to wait.** The
                    // owner named this as the hard part: for a purchase made
                    // minutes ago, «the receipt is not published yet» is the
                    // NORMAL state and can persist for hours. A person who
                    // scans and then sees nothing happen concludes the scan
                    // failed — so the app says what it is doing, once, and
                    // then gets out of the way.
                    //
                    // Only when the goods really are still coming: a rescan of
                    // a receipt whose items already landed would otherwise
                    // promise a wait that is already over.
                    if receipt.isWaitingForItems {
                        show(L10n.t("Чек додано. Товари з'являться тут, коли ДПС їх опублікує.",
                                    store.settings.languageChoice))
                    }
                }
            }
            .onAppear { start = Self.raised(start, cards: cards, rows: store.pendingRowCount) }
            // A background sync landing while this screen is open is what made
            // progress read «−3 з 12». The baseline only ever grows, so the
            // new cards join the denominator instead of driving the numerator
            // below zero — see `raised`.
            //
            // Watching the local `cards` rather than `store.queueCardCount`:
            // the two are equal, and `onChange` re-evaluates its value on
            // every render, so naming the store's would walk every pending row
            // again on each one.
            .onChange(of: cards) {
                start = Self.raised(start, cards: cards, rows: store.pendingRowCount)
            }
            .onDisappear { toastWork?.cancel() }
        }
    }

    /// The baseline after a look at what is on screen now. **It only grows.**
    ///
    /// Board #8's second half: `startCount` was captured once, on first
    /// appearance, and a background sync landing while the screen was open
    /// added cards the denominator had never heard of — so «2 з 12» became
    /// «−3 з 12», a progress line reading backwards through zero. Lowering it
    /// instead would be worse in the other direction: the numerator would
    /// count answers the person did not give.
    ///
    /// Both scales are raised together and independently: a sync that brings
    /// twenty new purchases on three cards moves both, by different amounts.
    ///
    /// **What it deliberately does not do** is remember what was already
    /// answered. Drain 61 cards, then have 5 arrive, and the line reads «56 з
    /// 61» rather than «61 з 66» — the baseline is the most ever pending at
    /// one time, not the session's running total. That is the behaviour the
    /// old code had too; the card asked for the negative to go, and a true
    /// cumulative counter needs state this does not keep. Worth revisiting if
    /// anyone works a queue long enough to notice.
    static func raised(_ start: Baseline?, cards: Int, rows: Int) -> Baseline {
        guard let start else { return Baseline(cards: cards, rows: rows) }
        return Baseline(cards: max(start.cards, cards), rows: max(start.rows, rows))
    }

    /// «3 з 11». **Cannot go negative by construction**, which is why the
    /// `max` is here as well as in `raised`: `raised` runs from `onAppear` and
    /// `onChange`, and a render can happen between a store mutation and the
    /// `onChange` that observes it. Clamping only the numerator would have
    /// been the wrong fix — it would read «0 з 12» with fifteen cards on
    /// screen, hiding the lie in the denominator instead of removing it.
    /// The language has **no default**: this is shown through `Text(…)`, which
    /// means the result is a plain `String` taking SwiftUI's verbatim overload,
    /// so «з» can only become "of" if it is translated here. A default argument
    /// is how the one call site would have gone on silently reading Ukrainian.
    static func progressText(start: Int?, remaining: Int, _ language: AppLanguage) -> String {
        let total = max(start ?? remaining, remaining)
        return String(format: L10n.t("%lld з %lld", language), total - remaining, total)
    }

    /// «3 покупки · 1 240 ₴», «1 надходження · +2 500 ₴», «18 березня · 5 550 ₴».
    ///
    /// **Board #9: a salary is not a purchase.** The queue folds income and
    /// expense into separate cards for the same merchant — `MerchantGroup`
    /// splits on kind precisely so the two are answered independently — and
    /// then described both of them with the same word and the same unsigned
    /// figure. The demo's «Тестове надходження» card read «1 покупка · 2 500 ₴»
    /// for money arriving.
    ///
    /// **Only income is signed.** A queue card's `total` is a magnitude —
    /// `groups` sums `abs(amount)` — and it is a SUM, not a ledger entry, so
    /// it does not want the feed's signed treatment on all sixty-one cards. A
    /// «−» on every expense is a column of noise that distinguishes nothing;
    /// the «+» earns its place by being the exception, which is exactly the
    /// thing a person scanning the queue needs to spot.
    ///
    /// A static, so the wording and the plural agreement are assertable
    /// without a simulator.
    static func subtitle(for group: MerchantGroup, _ language: AppLanguage) -> String {
        // A per-transaction card says WHICH purchase it is asking about; a
        // merchant card says how many it answers for. Thirty-five card-to-card
        // transfers all reading «1 покупка · 500 ₴» would be indistinguishable
        // from one another.
        let amount = amountText(for: group)
        guard let date = group.date else {
            let count = group.kind == .income
                ? Plural.incomes(group.count, language) : Plural.purchases(group.count, language)
            return "\(count) · \(amount)"
        }
        return "\(FeedView.dayTitle(date)) · \(amount)"
    }

    /// The words the card's second line shows: how many purchases it answers
    /// for, or — for a generic merchant, which gets a card per row — when.
    /// Board #9's decision, with the amount lifted out of it.
    static func countText(for group: MerchantGroup, _ language: AppLanguage) -> String {
        guard let date = group.date else {
            return group.kind == .income
                ? Plural.incomes(group.count, language) : Plural.purchases(group.count, language)
        }
        return FeedView.dayTitle(date)
    }

    /// «3 покупки · monobank · *1234» — what the card is asking about and
    /// where it came from, on one line. Board #104.
    ///
    /// The bank half is omitted rather than left as a dangling separator when
    /// a group has no bank to name.
    static func provenance(for group: MerchantGroup, _ banks: [Bank],
                           _ language: AppLanguage) -> String {
        let words = countText(for: group, language)
        let mark = BankMark.group(bankIds: group.bankIds, suffixes: group.cardSuffixes,
                                  banks, language)
        return mark.isEmpty ? words : "\(words) · \(mark)"
    }

    /// **The money, on its own so it can be COLOURED. Board #104.**
    ///
    /// Board #9's sign convention is unchanged and is still asserted: «+» on
    /// an arrival, and NO minus on a purchase — the magnitude is the number.
    /// What changes is that the sign is no longer the only thing saying which
    /// direction this is. On the card it now sits in its own element, tinted
    /// the way the feed tints an amount, because «where are the expenses and
    /// where are the arrivals» was not answerable at a glance from a single
    /// «+» buried in a grey line.
    static func amountText(for group: MerchantGroup) -> String {
        group.kind == .income ? "+" + group.total.uah : group.total.uah
    }

    private func list(all: [MerchantGroup], shown: [MerchantGroup],
                      receipts: [ReceiptCard]) -> some View {
        // Once per render, not once per card — see `selectionKind(in:)`.
        let kind = selectionKind(in: all)
        return ScrollView {
            VStack(spacing: 14) {
                // The two receipt cards, above the merchant groups: each one
                // is a question only a person can answer, unlike a group
                // card, which the app has already sorted — it is only
                // waiting on a category.
                ForEach(receipts) { card in
                    ReceiptQueueCard(card: card)
                }
                ForEach(shown) { group in
                    Card {
                        Button {
                            // Board #103: while selecting, a card's tap picks
                            // it rather than answering it. One gesture with two
                            // meanings is acceptable here and nowhere else,
                            // because the mode is visible — a checkbox on every
                            // card and a bar across the bottom.
                            if selecting { toggle(group) } else { picking = group }
                        } label: {
                            // Board #9: the card was a plain white rectangle
                            // with nothing on it to say it did anything. Every
                            // other row-shaped button in this app — a bank, a
                            // category, a plan line, a rule — ends in this
                            // chevron, so the queue was the one screen whose
                            // core gesture had no name. A chevron rather than
                            // a «Вибрати категорію» button (the card offered
                            // either): the app already says "this opens
                            // something" this way five times over, and a
                            // second button would compete with the green
                            // «Так, …» chip directly below it — which board
                            // #14 has since made a filled button, so the two
                            // would have competed harder still.
                            HStack(spacing: 12) {
                                if selecting {
                                    // Decorative: the Button's own label already
                                    // says what this row is, and SwiftUI hands
                                    // a merged label the image's SELECTED
                                    // trait — the same trap board #14's chip
                                    // documents one screen down.
                                    Image(systemName: selected.contains(group.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(selected.contains(group.id)
                                                         ? Theme.green : Theme.inkMuted)
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.merchant).font(Theme.font(17, .semibold))
                                        .foregroundStyle(Theme.ink)
                                    // How many (or when), then where from —
                                    // ONE line, the way the feed's own
                                    // subtitle puts a category beside a time.
                                    //
                                    // It was two lines first, and that made
                                    // every card a line taller: 30 cards of
                                    // extra height put the queue's own reveal
                                    // helper past its swipe budget and failed
                                    // a test that had nothing to do with this.
                                    // Compact is also simply better here.
                                    //
                                    // `BankMark` is the same function the feed
                                    // row uses, so the two screens cannot name
                                    // one bank two ways.
                                    Text(verbatim: Self.provenance(
                                            for: group, store.banks,
                                            store.settings.languageChoice))
                                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                                        .lineLimit(1)
                                        .accessibilityIdentifier("queue.mark.\(group.id)")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Tinted the way the feed tints an amount, so
                                // an arrival and a purchase are told apart
                                // without reading the sign.
                                Text(verbatim: Self.amountText(for: group))
                                    .fixedSize()
                                    .font(Theme.font(16, .semibold))
                                    .foregroundStyle(group.kind == .income ? Theme.green : Theme.ink)
                                    .accessibilityIdentifier("queue.amount.\(group.id)")
                                // The chevron says "this opens something", so
                                // it goes while selecting — a tap then opens
                                // nothing.
                                if !selecting {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.inkMuted)
                                }
                            }
                            // `maxWidth: .infinity` widens the FRAME, not the
                            // hit area, so without this a tap to the right of
                            // a short merchant name lands on nothing.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // **A selection is ONE kind.** Board #103's corruption
                        // vector, closed on screen: with an expense picked, the
                        // income cards stop responding and say so by fading.
                        // A merchant's income and its expenses are separate
                        // cards precisely because one category across
                        // directions is how a spending category lands on a
                        // salary. `confirmGroups` refuses a mixed selection
                        // again, so the rule survives a screen that forgets.
                        .disabled(selecting && !canSelect(group, kind))
                        .opacity(selecting && !canSelect(group, kind) ? 0.35 : 1)
                        // `group.id`, not `group.key`. The key is the merchant
                        // alone, and the queue renders more than one card per
                        // merchant in two different ways: a `GenericMerchant`
                        // gets one card PER ROW — thirty-five of them for the
                        // demo seed's biggest card-to-card transfer family —
                        // and any merchant that both paid and charged gets an
                        // income card beside its expense one. Both collided
                        // on a single identifier,
                        // so `firstMatch` picked whichever the tree yielded
                        // first and a test naming a specific card got a
                        // different one without failing. `id` is the identity
                        // SwiftUI already keys the `ForEach` on; the
                        // accessibility tree now agrees with it.
                        .accessibilityIdentifier("queue.group.\(group.id)")

                        // Board #14: this was «Приват: Продукти» in green text
                        // on a pale wash — the shape of a LABEL, on the one
                        // control in the queue that answers a card outright.
                        // It is now filled, and it says what tapping it does.
                        //
                        // The «Приват» attribution went with the restyle, and
                        // the mapping is why: the word here is no longer the
                        // bank's — `PrivatMapper` translates «Ресторани, кафе,
                        // бари» into the app's «Кафе та ресторани» — so
                        // crediting PrivatBank for it would be quoting a bank
                        // that said something else. The chip still appears
                        // ONLY on rows PrivatBank sent (`MerchantGroup.suggestion`).
                        if let suggestion = group.suggestion {
                            Button { accept(group) } label: {
                                HStack(spacing: 6) {
                                    // Decorative, and it has to be said out
                                    // loud: SwiftUI gives an `Image(systemName:
                                    // "checkmark")` the SELECTED trait, and a
                                    // merged Button label inherits it. The
                                    // accessibility tree read
                                    // «Так, Кредит, selected, button» — a
                                    // screen reader announcing that this
                                    // category is ALREADY the answer, on the
                                    // one control whose entire job is to
                                    // become the answer. Dumped, not guessed.
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .accessibilityHidden(true)
                                    Text("Так, \(suggestion)")
                                        .font(Theme.font(14, .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Theme.green, in: Capsule())
                                // The capsule IS the button; without this the
                                // corners are dead and a filled control that
                                // ignores a tap near its edge reads as broken.
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("queue.suggest.\(group.id)")
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        // A pinned footer, not a trailing card: the cap buries the rest of a
        // deep backlog rather than asking about it, and that has to be said
        // out loud somewhere the user does not have to scroll a long list to
        // find — the 30th card can sit well below the fold on a real backlog.
        // `safeAreaInset` keeps the last card from hiding behind it too.
        .safeAreaInset(edge: .bottom) {
            // While selecting, what you have picked matters more than an
            // explanation of the 30-card cap, so the bar replaces the footer
            // rather than stacking a third thing above the tab bar.
            if selecting {
                selectionBar(all)
            } else if !showAll && all.count > AppStore.queueCap {
                coverageFooter(all)
            }
        }
    }

    /// The kind every selected card shares, or `nil` when nothing is selected
    /// and any kind is still available.
    ///
    /// **Takes the group list rather than reading `store.pendingGroups`.**
    /// Board #105 found the first version doing the latter: `canSelect` calls
    /// this, and `canSelect` is evaluated TWICE PER CARD inside the `ForEach` —
    /// so on a 30-card screen a single render in selection mode walked all 772
    /// transactions, normalized every pending merchant and sorted the result
    /// **sixty times**. Board #8 established this exact rule for this exact
    /// screen, in this file's own comments: build the list once per render and
    /// hand it down. It took an hour to break. `tests/test_ios_render_cost.py`
    /// now watches it.
    private func selectionKind(in groups: [MerchantGroup]) -> TxKind? {
        groups.first { selected.contains($0.id) }?.kind
    }

    private func canSelect(_ group: MerchantGroup, _ kind: TxKind?) -> Bool {
        kind.map { $0 == group.kind } ?? true
    }

    private func toggle(_ group: MerchantGroup) {
        if selected.contains(group.id) { selected.remove(group.id) }
        else { selected.insert(group.id) }
    }

    private func toggleSelecting() {
        selecting.toggle()
        // Cleared on the way OUT as well as in: leaving the mode with cards
        // still ticked would bring them back on the next «Вибрати», answered by
        // a decision the person made minutes ago and cannot see.
        selected = []
    }

    private func selectionBar(_ all: [MerchantGroup]) -> some View {
        HStack(spacing: 14) {
            // «0 карток» is a count where an instruction belongs: looked at on
            // a simulator, the empty state of a mode should say what the mode
            // wants, not report that nothing has happened yet.
            //
            // Two branches rather than one `Text(someString)`: the prompt is
            // COPY and needs the catalogue, the count is assembled by `Plural`
            // and is already in the right language. Both carry the same
            // identifier and the same raw-number value — a test asserts on
            // arithmetic either way, and `0` still means nothing is picked.
            Group {
                if selected.isEmpty {
                    Text("Виберіть картки")
                } else {
                    Text(verbatim: Plural.cards(selected.count, store.settings.languageChoice))
                }
            }
            .font(Theme.font(15, .medium)).foregroundStyle(Theme.inkSoft)
            .accessibilityIdentifier("queue.selectedCount")
            // The raw number, so a test asserts on arithmetic. A `String`
            // variable, not `"\(n)"` — an interpolated literal takes the
            // LocalizedStringKey overload, which GROUPS the digits (#109).
            .accessibilityValue(String(selected.count))
            Spacer(minLength: 8)
            Button("Категорія") { pickingBulk = true }
                .font(Theme.font(16, .semibold))
                .foregroundStyle(selected.isEmpty ? Theme.inkMuted : .white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(selected.isEmpty ? Theme.hair : Theme.green, in: Capsule())
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("queue.bulkCategory")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 0.5) }
    }

    private func applyBulk(_ choice: CategoryChoice) {
        // «Переказ між своїми» is not offered in bulk: it retypes rows to
        // `.transfer` and writes a transfer rule per merchant, and a batch of
        // that is a much larger claim than a batch of «these are all cafés».
        // `CategoryPicker` can return it, so this refuses rather than assuming.
        guard case .category(let name) = choice else { return }
        let groups = store.pendingGroups.filter { selected.contains($0.id) }
        let count = groups.count
        let changed = store.confirmGroups(groups, as: name)
        guard changed > 0 else { return }
        selecting = false
        selected = []
        // Assembled the way `apply` above assembles its own: the counts come
        // from `Plural`, which carries both languages, and the category name is
        // the person's data. The arrow and the dot are punctuation, so there is
        // nothing here for a catalogue to hold.
        let language = store.settings.languageChoice
        show("\(Plural.cards(count, language)) → \(name)"
             + " · \(Plural.purchases(changed, language))")
    }

    /// «72%» — a figure, not copy, which is why it is interpolated into the
    /// sentence rather than spelled into the key.
    static func share(_ groups: [MerchantGroup]) -> String {
        "\(Int((AppStore.coverageShare(groups) * 100).rounded()))%"
    }

    /// Takes the groups the body already built — naming a bare `all` in here
    /// resolved to SIMD's `all`, which is a compile error and not the value it
    /// looks like.
    private func coverageFooter(_ groups: [MerchantGroup]) -> some View {
        VStack(spacing: 8) {
            // «карток», not «магазинів»: a transfer gets a card of its own,
            // so the first thirty are no longer thirty shops.
            // ONE interpolated literal, not two joined by `+`. Concatenation
            // produces a `String`, which takes `Text`'s verbatim overload and
            // renders Ukrainian however good the catalogue is — and the two
            // halves are not separately translatable anyway. The percent sign
            // travels inside the interpolated value so the key carries no bare
            // `%` for the formatter to read as a specifier.
            Text("Перші \(AppStore.queueCap) карток — це \(Self.share(groups)) ваших витрат.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("queue.coverage")
            Button("Показати всі \(groups.count)") { showAll = true }
                .font(Theme.font(15, .semibold)).foregroundStyle(Theme.green)
                .accessibilityIdentifier("queue.showAll")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    /// Before `doneScreen`: an empty app has nothing to congratulate anyone
    /// for. «Усе розібрано» is a reward for finishing a backlog — this app
    /// never had one to begin with.
    private var emptyWaitingScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Card {
                Text("Поки нічого розбирати.")
                    .font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("queue.empty.waiting")
                SyncStatusView()
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneScreen: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light)).foregroundStyle(Theme.green)
            // The screen's marker, on its headline. It belonged on the `VStack`
            // below as a `.contain` container until this task drained the queue
            // for the first time and found it absent from the tree: `queue.title`
            // on the `ZStack` above is itself a SYNTHESISED container, and a
            // second synthesised container nested inside one is dropped —
            // «Усе розібрано» and `queue.done` both surfaced, their parent did
            // not. (`detail.receipt` nests fine because its parent marker sits
            // on a real `ScrollView`, not on a synthesised container.) A leaf
            // cannot be dropped and cannot stamp its name over its siblings.
            Text("Усе розібрано").font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("queue.doneScreen")
            // `rows`, not `cards`: what a person did was sort purchases, and
            // one card can carry twenty of them. Counting this in the badge's
            // unit would have quietly turned «Ви розібрали 66 покупок» into
            // «Ви розібрали 12 покупок» the moment board #8 moved the badge —
            // the same figure under the same word, meaning something else.
            if let total = start?.rows, total > 0 {
                // Accusative: «розібрали» governs its object, so «1 покупку» —
                // the nominative helper every other call site wants was
                // shipping «Ви розібрали 1 покупка» here. Board #182.
                Text("Ви розібрали \(Plural.purchasesAccusative(total, store.settings.languageChoice)).")
                    .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            PrimaryButton(title: "На головну", action: onDone)
                .accessibilityIdentifier("queue.done")
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No identifier here on purpose. A bare one would have nothing of its
        // own to attach to and would be pushed onto every descendant instead,
        // overwriting "queue.done" on the button above; and the
        // `.accessibilityElement(children: .contain)` that used to hold it off
        // bought a container that never reached the tree at all. The name now
        // lives on the headline. See the comment there.
    }

    /// **The toast FOLLOWS the appearance; it does not invert against it.**
    /// Board #182, and the owner's own words: white ground and dark letters in
    /// the light theme, dark ground and light letters in the dark one.
    ///
    /// It used to be drawn on `Theme.ink` — a text colour, near-white in dark
    /// appearance — under a fixed `.white`, which measured **1.14:1** and made
    /// the whole toast unreadable on a dark phone. Inverting the ink would
    /// have made it legible; taking the ordinary card pair makes it legible
    /// AND the colour the person asked for.
    ///
    /// The three tokens move together and none of them is optional:
    ///
    /// - `Theme.card` under `Theme.ink` is the pair every other surface in the
    ///   app already uses, measured at 12.96:1 and 13.63:1.
    /// - **«Скасувати» has to leave `greenWash`.** That wash was chosen to sit
    ///   on the dark pill; on a card it measures 1.16:1 and would have traded
    ///   an unreadable message for an unreadable button. `Theme.green` is the
    ///   app's action colour and the pair every other green control on a card
    ///   already is.
    /// - **The border and shadow are what make it a toast at all.** `card`
    ///   against `bg` is 1.09:1 in light appearance, and this bar floats over
    ///   a list of cards in that same colour — without an edge it reads as one
    ///   more row rather than as something transient with an undo in it. Same
    ///   treatment as `Card`, a little heavier because this one floats.
    private func toastBar(_ toast: Toast) -> some View {
        HStack(spacing: 14) {
            // `verbatim`: the undo labels are assembled and translated in
            // `AppStore+Queue` through `L10n.t`.
            Text(verbatim: toast.text).font(Theme.font(15)).foregroundStyle(Theme.ink).lineLimit(2)
            Spacer(minLength: 8)
            if toast.undoable {
                Button("Скасувати") {
                    store.undoLast()
                    cancelToast()
                }
                .font(Theme.font(15, .semibold)).foregroundStyle(Theme.green)
                .accessibilityIdentifier("queue.undo")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            // `inkMuted` and not `hair`: a hairline is for separating rows
            // that are ALREADY on different grounds, and it measures 1.25:1
            // on a card — on this bar, which is the same colour as the cards
            // it floats over, it was a border only in principle. `inkMuted`
            // is 3.33:1 in light and 5.40:1 in dark, clearing the 3.0 a UI
            // boundary is held to in both.
            //
            // `allowsHitTesting(false)`: an overlay is hit-testable, and this
            // one covers the whole bar — including «Скасувати». The undo is
            // the only control here and it has five seconds to be tappable.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.inkMuted, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .shadow(color: Theme.cardShadow, radius: 16, y: 6)
        .padding(.horizontal, 18).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func apply(_ group: MerchantGroup, _ choice: CategoryChoice) {
        let changed = store.confirmGroup(group, as: choice)
        // Not "· ще N": the cascaded rows are folded into the same tap that
        // resolved the row in hand — the group IS the merchant's whole
        // backlog — so there is nothing left behind to report separately.
        let suffix = changed > 1 ? " · \(Plural.purchases(changed, store.settings.languageChoice))" : ""
        switch choice {
        case .category(let name):
            show("\(group.merchant) → \(name)\(suffix)")
        case .notAnExpense:
            // `toastBar` is `Text(verbatim:)` on purpose — the undo labels
            // `AppStore+Queue` writes are already translated when they arrive.
            // This call site assembles its own, so it owes the same `L10n.t`.
            // A merchant and a category name are data and stay as they are.
            show(String(format: L10n.t("%@ — переказ між своїми", store.settings.languageChoice),
                        group.merchant) + suffix)
        }
    }

    private func accept(_ group: MerchantGroup) {
        guard let suggestion = group.suggestion else { return }
        let changed = store.acceptSuggestion(group)
        let suffix = changed > 1 ? " · \(Plural.purchases(changed, store.settings.languageChoice))" : ""
        show("\(group.merchant) → \(suggestion)\(suffix)")
    }

    /// One toast at a time, five seconds, and the previous one's timer is
    /// cancelled — otherwise a fast worker's second confirmation is dismissed
    /// by the first one's expiry, taking its undo with it.
    private func show(_ text: String, undoable: Bool = true) {
        toastWork?.cancel()
        withAnimation { toast = Toast(text: text, undoable: undoable) }
        let work = DispatchWorkItem { withAnimation { toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func cancelToast() {
        toastWork?.cancel()
        toastWork = nil
        withAnimation { toast = nil }
    }
}
