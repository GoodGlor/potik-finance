import Foundation

/// Merchant names arrive from bank statement text: inconsistent case, stray
/// padding. Everything that compares two merchants goes through here so the
/// queue, the rules and the cascade cannot disagree about what "same merchant"
/// means.
///
/// `precomposedStringWithCanonicalMapping` matters for Ukrainian: `й` and `ї`
/// can arrive either precomposed or as a base letter plus a combining mark,
/// and those are different strings to `==` while being the same word to a
/// human. The Python side's `normalize_key()` makes the same promise.
enum MerchantKey {
    static func normalize(_ merchant: String) -> String {
        merchant
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// What one undoable action changed. Rows are captured whole, before the
/// change, so undo is a restore rather than an inverse operation — an inverse
/// would have to know how to un-cascade, and would drift from `confirm` the
/// first time `confirm` grew a case.
///
/// Captured whole, but PUT BACK selectively — see `undoLast`. Every producer
/// here (`confirm`, `setCategory`, `markNotAnExpense`, `setNotAnExpense`)
/// writes exactly `category`, `resolution` and/or `kind`
/// and nothing else, so those fields are all this entry owns. Writing the
/// whole snapshot back would also revert
/// whatever an unrelated screen changed on the same row in between —
/// `receiptId` and `splits`, both of which the receipts screens edit
/// independently.
///
/// `kind` joined the owned set alongside `category`/`resolution` when
/// `markNotAnExpense` was added: without it, undoing «Це не витрата» would
/// leave the row typed `.transfer` with its category restored — a state
/// visible nowhere and wrong everywhere.
struct UndoEntry {
    /// **Internal, and never shown.** No view reads it — the queue's toast
    /// composes its own sentence, in the chosen language, from what the action
    /// returned. Keep it that way: a `Text(entry.label)` would take the
    /// verbatim overload and ship these Ukrainian strings to an English
    /// reader, which is board #96's defect with a new source.
    var label: String
    var rows: [Transaction]     // the rows exactly as they were

    /// Whether this action touched `rules` at all. This is NOT the same as
    /// `ruleBefore == nil`: `setNotAnExpense` touches no rule, while a
    /// first-ever confirmation touches the rules and had none before.
    /// Collapsing the two makes undoing a rule-less action delete whatever rule
    /// that merchant already had.
    var touchedRule: Bool
    /// **Every rule this merchant had**, board #81 — not the single one the
    /// action replaced.
    ///
    /// A merchant can now hold a rule for its expenses and another for its
    /// income, and two of the three rule-writing branches do not touch exactly
    /// one of them: `markNotAnExpense`, contradicted, clears the lot. Snapshot
    /// and restore the merchant's whole table and undo is exact whatever the
    /// branch did, with no third field saying which scopes were in play.
    /// Restoring a rule the action never touched is a no-op by construction.
    ///
    /// Empty is a real value: a first-ever confirmation had none before, which
    /// is why `touchedRule` is still a separate flag.
    var rulesBefore: [Rule]
    /// **Plural since board #103.** One entry can now stand for a sweep across
    /// several merchants — the bulk answer is one action and must undo as one —
    /// and every single-merchant producer simply passes a one-element array.
    var merchantKeys: [String]
}

/// One merchant's undecided rows, asked about together. A merchant with a
/// single purchase renders exactly as the old per-purchase card did.
struct MerchantGroup: Identifiable, Equatable {
    var key: String
    var merchant: String
    var kind: TxKind
    var count: Int
    /// Absolute, so ordering is by money regardless of sign.
    var total: Int
    var rowIds: [Transaction.ID]
    /// **Which banks and cards this card's rows came from. Board #104.**
    ///
    /// Plural, and that is not defensiveness: a group is a merchant AND a
    /// kind, never a card, so the same shop paid from two cards is ONE
    /// question with one answer — and a person being asked it should be able
    /// to see that it spans two. The seed has such groups.
    ///
    /// Sorted and unique, so the mark a card shows does not depend on which
    /// row happened to be read first.
    var bankIds: [String] = []
    var cardSuffixes: [String] = []
    /// The one-tap answer this card offers, when its rows brought a bank
    /// category. Set ONLY from rows whose `bankId` is `PrivatMapper.bankId`
    /// — the chip is an answer the app is willing to stand behind, and it can
    /// only stand behind a guess it knows the provenance of.
    ///
    /// Do not weaken that to "any row with suggestions": the bundled seed
    /// ships 66 **monobank** rows carrying a legacy three-category
    /// `suggestions` array, and the first version of this chip credited
    /// PrivatBank for every one of them.
    ///
    /// **Already translated** into the app's vocabulary by
    /// `PrivatMapper.suggestion(for:)` — board #14. What is stored on the row
    /// is the bank's own word; what reaches this property is a category the
    /// app already has, so accepting the chip creates nothing.
    var suggestion: String?
    /// Set only on a per-transaction card (a `GenericMerchant`), where the
    /// date is what tells two otherwise identical «На картку» rows apart.
    /// `nil` on an ordinary merchant card, which spans many dates.
    var date: Date?
    /// The row a per-transaction card stands for. Part of the identity, so
    /// thirty-five «На картку» cards are thirty-five cards and not one
    /// SwiftUI keeps re-using.
    var rowId: Transaction.ID?

    var id: String {
        let base = key + "|" + kind.rawValue
        guard let rowId else { return base }
        return base + "|" + rowId.uuidString
    }
}

extension AppStore {

    // MARK: reading

    /// Caps GROUPS, not rows. "30 rows in the last 7 days" made sense when
    /// history ended on a known date; after a backfill it would hide a year
    /// behind an arbitrary line.
    static let queueCap = 30

    /// Which card a pending row belongs to — **the one definition**, board #8.
    ///
    /// It used to be spelled inline inside `groups` below, and the moment
    /// anything else needed to know how many cards the queue has, that rule
    /// would have been written a second time. Two spellings of "same card" is
    /// exactly how the badge came to say 12 while the screen showed 4: the
    /// badge counted rows because counting cards meant re-deriving this, and
    /// nobody wanted two copies of it. `pendingCardCount` now calls this, and
    /// `testTheCardCountIsExactlyTheNumberOfCardsTheScreenWouldShow` fails if
    /// the two ever disagree.
    ///
    /// A generic merchant gets one card per ROW. Folding those by name would
    /// offer a single tap that answers for all of them, and the answer is only
    /// ever true of one — see `GenericMerchant`.
    static func cardId(for tx: Transaction) -> String {
        cardId(key: MerchantKey.normalize(tx.merchant),
               generic: GenericMerchant.matches(tx.merchant), tx: tx)
    }

    /// The shape itself, for a caller that has already worked out the key and
    /// whether the merchant is generic. `groups` has both in hand, and the
    /// convenience above would otherwise make it normalize the merchant and
    /// run the predicate a second time on every pending row.
    static func cardId(key: String, generic: Bool, tx: Transaction) -> String {
        let base = key + "|" + tx.kind.rawValue
        return generic ? base + "|" + tx.id.uuidString : base
    }

    /// Every `.pending` row, folded into one card per merchant. A rule the
    /// user already taught resolves a row at ingest (see `AppStore+Sync`), so
    /// nothing that arrives here is a merchant the app is silently guessing
    /// about — it is asking because it genuinely does not know.
    static func groups(_ txs: [Transaction]) -> [MerchantGroup] {
        var buckets: [String: MerchantGroup] = [:]
        var newestSeen: [String: Date] = [:]
        var tallies: [String: [String: Int]] = [:]
        for tx in txs where tx.resolution == .pending {
            let key = MerchantKey.normalize(tx.merchant)
            let generic = GenericMerchant.matches(tx.merchant)
            // Bucketing by `cardId` is what splits a generic merchant into one
            // card per row; everything below then runs unchanged.
            let id = cardId(key: key, generic: generic, tx: tx)
            if var group = buckets[id] {
                group.count += 1
                group.total += abs(tx.amount)
                group.rowIds.append(tx.id)
                if !group.bankIds.contains(tx.bankId) {
                    group.bankIds = (group.bankIds + [tx.bankId]).sorted()
                }
                if !tx.cardSuffix.isEmpty, !group.cardSuffixes.contains(tx.cardSuffix) {
                    group.cardSuffixes = (group.cardSuffixes + [tx.cardSuffix]).sorted()
                }
                // The display name follows the most recent row, so the queue
                // shows the merchant as the bank most recently wrote it.
                if tx.date > (newestSeen[id] ?? .distantPast) {
                    group.merchant = tx.merchant
                    newestSeen[id] = tx.date
                }
                buckets[id] = group
            } else {
                buckets[id] = MerchantGroup(key: key, merchant: tx.merchant, kind: tx.kind,
                                            count: 1, total: abs(tx.amount), rowIds: [tx.id],
                                            bankIds: [tx.bankId],
                                            cardSuffixes: tx.cardSuffix.isEmpty ? [] : [tx.cardSuffix],
                                            date: generic ? tx.date : nil,
                                            rowId: generic ? tx.id : nil)
                newestSeen[id] = tx.date
            }
            // Only a statement import earns the chip. The seed ships 66
            // monobank rows carrying a legacy three-category `suggestions`
            // array, and without this check every one of them offers a
            // PrivatBank guess on a monobank purchase — visible to anyone
            // with seed data before their first sync.
            //
            // **The translation happens here** (board #14), not at import:
            // the stored word is the bank's own, so the chip is the last
            // moment before Privat's vocabulary would become the app's. A
            // word with no honest one-tap answer returns nil and the group
            // simply gets no chip. Translating BEFORE the tally also merges
            // two statement words that mean one category into one count,
            // rather than letting them out-vote each other.
            if tx.bankId == PrivatMapper.bankId,
               let raw = tx.suggestions.first,
               let hint = PrivatMapper.suggestion(for: raw) {
                tallies[id, default: [:]][hint, default: 0] += 1
            }
        }
        // The map below resolves each group's suggestion chip from its
        // tally; unrelated to the ordering that follows.
        return buckets.map { id, group in
            var group = group
            group.suggestion = tallies[id]?.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key
            return group
        }
        // Money first; `id` breaks ties so the order cannot change between
        // launches — a dictionary's iteration order is not stable.
        //
        // `id`, not `key`: per-transaction cards share a merchant, so two
        // transfers of the same amount have the SAME key, the comparator
        // returns false both ways, and their order falls back to exactly the
        // dictionary iteration this line exists to defend against. `id`
        // carries the row, so it is unique per card.
        .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
    }

    /// Every group, biggest first — no date window. With backfilled history a
    /// window would hide a year of purchases behind an arbitrary line.
    var pendingGroups: [MerchantGroup] { AppStore.groups(transactions) }

    /// The first `queueCap` of a group list — what the screen actually shows.
    ///
    /// A static so the screen can cap the list it has already built instead of
    /// building a second one, and still cap it the same way this does.
    static func capped(_ groups: [MerchantGroup]) -> [MerchantGroup] {
        Array(groups.prefix(queueCap))
    }

    var queuedGroups: [MerchantGroup] { AppStore.capped(pendingGroups) }

    /// What the shown groups are worth against everything still undecided.
    /// Computed, never written: 69% is the owner's number, not everyone's.
    ///
    /// Takes the groups rather than reaching for them, for the reason `capped`
    /// above is a static: as a property reading `pendingGroups` and
    /// `queuedGroups` it built the whole group list TWICE, on a screen that
    /// had already built it — and it is called from a footer that only appears
    /// on a backlog deep enough for the cost to be worth caring about.
    static func coverageShare(_ groups: [MerchantGroup]) -> Double {
        let all = groups.reduce(0) { $0 + $1.total }
        guard all > 0 else { return 0 }
        return Double(capped(groups).reduce(0) { $0 + $1.total }) / Double(all)
    }

    var coverageShare: Double { AppStore.coverageShare(pendingGroups) }

    /// Rows still awaiting an answer. **Not the badge** — it was called
    /// `badgeCount` until board #8, and a property named for a thing it is no
    /// longer is how a screen ends up disagreeing with itself.
    ///
    /// Still the honest count of PURCHASES left, which is what Home's second
    /// number and the done screen's «Ви розібрали N покупок» are about: one
    /// card can carry twenty of these, and "how much of my spending is
    /// unsorted" is a different question from "how many taps is that".
    ///
    /// A legacy `.skipped` row is excluded, and that is still the right answer
    /// — skipping was a decision, and a count that keeps counting decisions the
    /// user already made is nagging. Board #26 removed the way to make one; see
    /// `Resolution.skipped` for why the case itself stayed.
    var pendingRowCount: Int { transactions.filter { $0.resolution == .pending }.count }

    /// How many merchant cards the queue would show — the same unit the screen
    /// is in, board #8.
    ///
    /// **Counted through `cardId`, never re-derived**, so this and
    /// `pendingGroups.count` cannot drift apart. That equality is the whole
    /// point of the property and is pinned by a test.
    ///
    /// A `Set` of ids rather than `pendingGroups.count`: this is read on every
    /// render of the tab bar and of Головна, neither of which wants the cards
    /// themselves. `groups` additionally tallies each card's total, tracks its
    /// newest row, resolves a suggestion chip and then sorts the lot — all of
    /// it thrown away to arrive at an integer.
    var pendingCardCount: Int {
        var ids = Set<String>()
        for tx in transactions where tx.resolution == .pending {
            ids.insert(AppStore.cardId(for: tx))
        }
        return ids.count
    }

    /// **The badge, and the number every screen counts in** (board #8): every
    /// card the queue is asking about, merchant cards and receipt questions
    /// together.
    ///
    /// The receipt cards are in it because the queue already treats them as
    /// blocking — `doneScreen` refuses to appear while one is up. A badge that
    /// counted only merchant groups would read 0 with a question sitting on
    /// screen, which is a fourth number disagreeing rather than a fix.
    var queueCardCount: Int { pendingCardCount + receiptCards().count }

    // MARK: confirming

    /// Resolve one row, write the merchant rule, and apply that rule to every
    /// other row of the same merchant that is still `.pending`. Returns how
    /// many rows changed, so the caller can say "Ще 4 покупки NovaPay → Послуги".
    ///
    /// `source` is only ever read by the Debug categorization log — it names
    /// which affordance the person used, which the log cannot infer from the
    /// rows alone.
    @discardableResult
    func confirm(_ id: Transaction.ID, as category: String,
                 source: CategorizationSource = .queueConfirm) -> Int {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return 0 }
        let key = MerchantKey.normalize(transactions[index].merchant)
        // Captured before the mutation below: `markNotAnExpense` retypes the
        // row in hand to `.transfer`, and `confirm` never does, but reading
        // it from a local keeps this identical in shape to that function's
        // own `kind` capture.
        let kind = transactions[index].kind
        // Board #81: the rule that governs THIS kind, not whichever rule for
        // this merchant happened to be written first. Everything below —
        // `contradicts`, `broaden`, the undo snapshot — is about the answer
        // this tap is replacing, and for a merchant that both pays and charges
        // that is one of two.
        let ruleBefore = rules.governing(key, kind: kind)
        // The merchant's whole rule table, for the undo entry. Captured here,
        // before any branch below writes — see `UndoEntry.rulesBefore`.
        let rulesBefore = rules.filter { $0.merchantKey == key }

        // Contradicting an answer already given FOR THIS KIND means the
        // merchant genuinely spans categories (Rozetka, «На картку»). The rule
        // stops answering and starts asking — and never cascades again.
        //
        // Scoped, since board #81. It used to compare against any rule for the
        // merchant, so answering «Зарплата» for an income and «Послуги» for an
        // expense read as a person contradicting themselves and threw both
        // answers away. They are two facts about two kinds of row, and the
        // rule table can now hold both.
        let contradicts = ruleBefore.map { $0.category != nil && $0.category != category } ?? false
        let wasAmbiguous = ruleBefore?.ambiguous ?? false

        var touched: [Transaction] = [transactions[index]]
        transactions[index].category = category
        transactions[index].resolution = .user

        // A generic merchant answers for THIS purchase and nothing else: no
        // rule to apply next time, and no cascade over its siblings. Its name
        // does not say what was bought, so an answer about one row is not an
        // answer about the merchant — see `GenericMerchant`.
        if GenericMerchant.matches(transactions[index].merchant) {
            pushUndo(label: "\(transactions[index].merchant) → \(category)",
                     rows: touched, touchedRule: false, rulesBefore: [], keys: [key])
            note(source, rows: touched, choice: .category(category))
            persist()
            return touched.count
        }

        // The scope of the rule this call actually writes, captured for the
        // undo entry (board #81). Withdrawing by merchant alone would take the
        // merchant's other rule with it, and the two branches below do not
        // write the same scope: an ambiguous marker is unscoped, a taught
        // category is scoped to the kind that taught it.
        if contradicts || wasAmbiguous {
            // **At the contradicted rule's own scope, not at `nil`.** Board
            // #81's first cut wrote the marker unscoped and left the scoped
            // rule it was meant to overrule sitting beside it — where
            // `governing` preferred it, being the more specific of the two,
            // and the merchant carried on auto-typing exactly as before. The
            // marker has to replace the answer it contradicts, which means
            // occupying its key.
            upsertRule(Rule(merchantKey: key, category: nil, ambiguous: true,
                            scope: ruleBefore?.scope))
        } else {
            // An UNSCOPED rule that already gives this answer stays unscoped
            // rather than gaining a scoped twin beside it. Since board #81
            // that is all this can mean: `governing` returns either the rule
            // for this exact kind — where `scope == kind`, so `broaden` is
            // false — or the merchant's `nil`-scope rule, which covers this
            // kind already and should not be narrowed or duplicated.
            //
            // The case this comment used to describe is now handled by the key
            // itself. Two DIFFERENT categories on two kinds no longer collide:
            // they are two rules, which is board #81.
            // The same answer already given for the OTHER kind broadens to one
            // unscoped rule rather than standing up a second scoped one beside
            // it. Two rules per merchant is what board #81 makes possible, not
            // what it makes desirable: «Маркет → Техніка для витрат» and
            // «Маркет → Техніка для надходжень» are two rows on the rules
            // screen saying one thing, and «Маркет → Техніка» says it once.
            //
            // Read across every scope, not just `ruleBefore`: `governing` hands
            // back the rule for THIS kind, which is precisely the one that does
            // not exist in the case being broadened.
            let sameAnswerElsewhere = rules.contains {
                $0.merchantKey == key && $0.scope != kind
                    && !$0.ambiguous && $0.category == category
            }
            if sameAnswerElsewhere {
                rules.removeAll { $0.merchantKey == key }
                rules.append(Rule(merchantKey: key, category: category,
                                  ambiguous: false, scope: nil))
            } else {
                upsertRule(Rule(merchantKey: key, category: category,
                                ambiguous: false, scope: kind))
            }
            // `.pending` AND the same `kind`: a merchant's income and its
            // expenses are independent decisions — `MerchantGroup` splits on
            // kind for exactly this reason — so answering one must never
            // silently resolve, and withdraw from the queue, a still-
            // `.pending` row of the OTHER kind. Without the kind term this
            // cascade would stamp a spending category onto a salary that was
            // never shown to the user.
            for i in transactions.indices
            where i != index
                && transactions[i].resolution == .pending
                && transactions[i].kind == kind
                && MerchantKey.normalize(transactions[i].merchant) == key {
                touched.append(transactions[i])
                transactions[i].category = category
                // .rule, not .user: the person answered about one purchase,
                // and the rule answered for the rest. Detail screens say so.
                transactions[i].resolution = .rule
            }
        }

        pushUndo(label: "\(transactions[index].merchant) → \(category)",
                 rows: touched, touchedRule: true, rulesBefore: rulesBefore, keys: [key])
        note(source, rows: touched, choice: .category(category))
        persist()
        return touched.count
    }

    /// The detail screen's edit: this row, nothing else, no rule. Choosing a
    /// category for one purchase is not a statement about the merchant.
    func setCategory(_ id: Transaction.ID, to category: String) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        let before = transactions[index]
        transactions[index].category = category
        transactions[index].resolution = .user
        // Naming a category says this money went somewhere, so a row that was
        // typed `.transfer` stops being one.
        //
        // This is the repair path board #6 leaves the rows it declined to
        // migrate: the withdrawals and jar top-ups answered under the old,
        // wider «Це не витрата». Without this line the repair silently fails
        // in the worst possible way — the detail screen shows «Готівка», the
        // row LOOKS answered, and `Derived` still excludes every kopeck of it
        // from spending because the kind never moved. The person would have to
        // notice that a number they cannot see did not change.
        //
        // By the sign, not by the picker's `purpose`: a positive transfer
        // given a spending category is money coming back, and Головна reads
        // income off the sign.
        if before.kind == .transfer {
            transactions[index].kind = before.amount > 0 ? .income : .expense
        }
        pushUndo(label: "\(before.merchant) → \(category)", rows: [before],
                 touchedRule: false, rulesBefore: [],
                 keys: [MerchantKey.normalize(before.merchant)])
        // A row that already had an answer is being CORRECTED, which is a
        // different example from one being answered for the first time — and
        // the more informative of the two, since it is the person telling the
        // app it was wrong.
        note(before.resolution == .pending ? .detailEdit : .correction,
             rows: [before], choice: .category(category))
        persist()
    }

    // MARK: board #100 — the same correction, applied to the backlog

    /// Rows that are the same merchant and the same KIND as `anchor`, already
    /// answered, and answered differently.
    ///
    /// **Same merchant AND same kind**, which is `confirm`'s cascade key and
    /// board #81's rule key. Merchant alone is the tempting looser rule and it
    /// is the one that stamps a spending category onto a salary — a merchant
    /// that both pays and charges holds two independent answers, which is the
    /// whole reason `MerchantGroup` splits on kind. **MCC is not used**: it is
    /// stored and read by nothing, and `Transaction.mcc`'s own doc says
    /// nothing may read it as a category until a card says how. This is not
    /// that card.
    ///
    /// A `.transfer` row can never be caught by this: `setCategory` retypes
    /// the row it edits out of `.transfer`, so the kind term excludes them,
    /// and a bulk edit must not quietly turn transfers into spending.
    private func siblingsDisagreeing(with anchor: Transaction) -> [Int] {
        guard !anchor.category.isEmpty else { return [] }
        let key = MerchantKey.normalize(anchor.merchant)
        return transactions.indices.filter { i in
            transactions[i].id != anchor.id
                && transactions[i].kind == anchor.kind
                && transactions[i].category != anchor.category
                && MerchantKey.normalize(transactions[i].merchant) == key
        }
    }

    /// How many other rows the offer would change. Zero means no offer.
    func othersDisagreeing(with id: Transaction.ID) -> Int {
        guard let tx = transactions.first(where: { $0.id == id }) else { return 0 }
        return siblingsDisagreeing(with: tx).count
    }

    /// Give every disagreeing sibling the anchor's category.
    ///
    /// **No rule is written, deliberately.** «Завжди відносити …» sits on the
    /// same screen and does exactly that, with its own copy about what happens
    /// when a merchant's answers contradict. Two controls on one screen that
    /// both teach rules, worded differently, is how a person stops being able
    /// to predict either. This one is about the BACKLOG; the toggle is about
    /// what happens next. The copy says which.
    ///
    /// `.user`, not `.rule`: the person decided these, and no rule exists to
    /// point at. A detail screen reading «за правилом» beside a Правила screen
    /// that lists no such rule is a contradiction this app already has one of.
    ///
    /// ONE undo entry holding every touched row — `undoLast` restores them
    /// together, so a mis-tap on twelve rows costs one tap to reverse.
    @discardableResult
    func applyCategoryToSimilar(_ id: Transaction.ID) -> Int {
        guard let anchor = transactions.first(where: { $0.id == id }) else { return 0 }
        let indices = siblingsDisagreeing(with: anchor)
        guard !indices.isEmpty else { return 0 }

        var touched: [Transaction] = []
        for i in indices {
            touched.append(transactions[i])
            transactions[i].category = anchor.category
            transactions[i].resolution = .user
        }
        pushUndo(label: String(format: L10n.t("%@ → %@", L10n.formatting),
                               anchor.merchant, anchor.category),
                 rows: touched, touchedRule: false, rulesBefore: [],
                 keys: [MerchantKey.normalize(anchor.merchant)])
        // `.cascade`, not N corrections: the person made ONE decision and it
        // reached these rows. `setCategory` already logged that decision as a
        // `.correction`; logging twelve more would tell a trainer the person
        // looked at twelve purchases when they looked at one.
        note(.cascade, rows: touched, choice: .category(anchor.category))
        persist()
        return touched.count
    }

    /// The detail screen's «Переказ між своїми картками»: this row, nothing
    /// else, no rule — the exact promise `setCategory` above makes, kept for
    /// the answer sitting one row above it in the same picker.
    ///
    /// It did not keep that promise until board #13. The detail screen called
    /// `markNotAnExpense`, which is the QUEUE's mutation: it cascaded to every
    /// pending row of the merchant and taught a `.transfer` rule that types
    /// every future row of that merchant at ingest. The queue at least says so
    /// out loud — it shows a toast reading «X — переказ між своїми · ще N» with
    /// an undo beside it. Detail showed nothing at all, so one tap on a single
    /// purchase could silently withdraw a merchant's whole backlog from the
    /// queue and every one of its future rows from spending, and the only
    /// evidence was a number somewhere else getting smaller.
    ///
    /// **Teaching a transfer rule is then not reachable from this screen at
    /// all**, and that is the intended end state rather than a gap: the
    /// «Завжди відносити…» toggle below is a sentence about a category, and it
    /// goes inert the moment this clears one. The one rule in this app that
    /// can silently remove a merchant's future rows from every spending figure
    /// is taught in the one place that shows a toast and an undo while doing
    /// it. A category rule, which cannot do that, is still one tap away here.
    func setNotAnExpense(_ id: Transaction.ID) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        let before = transactions[index]
        transactions[index].kind = .transfer
        transactions[index].category = ""
        transactions[index].resolution = .user
        pushUndo(label: String(format: L10n.t("%@ — переказ між своїми", L10n.formatting),
                              before.merchant), rows: [before],
                 touchedRule: false, rulesBefore: [],
                 keys: [MerchantKey.normalize(before.merchant)])
        // The same `.correction` derivation `setCategory` makes, for the same
        // reason: overruling an answer the app already had is a more
        // informative training example than answering a blank row.
        note(before.resolution == .pending ? .detailEdit : .correction,
             rows: [before], choice: .notAnExpense)
        persist()
    }

    // MARK: not an expense

    /// «Переказ між своїми картками» — money that left one of the owner's
    /// accounts and arrived in another. Cascades by merchant exactly as a
    /// category confirmation does, so each is answered once.
    ///
    /// **It used to mean more than that** (board #6): the row read «Це не
    /// витрата» and bundled ATM cash, jar top-ups and payments to other people
    /// in with own-card transfers. Only the last of those is genuinely outside
    /// spending — with two banks connected the same 5 000 ₴ otherwise inflates
    /// expenses on one side and income on the other — and every other use made
    /// a person's spending read low with nothing on screen to say why. Cash is
    /// now `BudgetMath.cashCategory`, a jar is `BudgetMath.savingsCategory`
    /// (which `Derived` keeps out of spending, so it costs nothing to record
    /// honestly), and a P2P payment is whatever it bought.
    ///
    /// **Rows already typed `.transfer` are left exactly as they are.** The
    /// data does not say which of them were own-card transfers and which were
    /// cash under the old wording, so a migration could only guess, and it
    /// would guess by rewriting months of a person's confirmed history with no
    /// undo and no way to see what changed. The narrower copy stops NEW rows
    /// being answered this way; the old ones stay until their owner reopens
    /// one. A transfer RULE taught under the old wording is the part that
    /// keeps acting — `GenericMerchant` already refuses to apply one for an
    /// ATM or a transfer, and the rest is now visible and repairable in
    /// Налаштування → Категорії → «Правила» (board #11), which is what that
    /// migration decision was waiting on.
    ///
    /// The cascade predicate is copied verbatim from `confirm` above,
    /// deliberately not re-derived: `.pending` only. A row the user already
    /// confirmed by hand — `.user` — or already settled by a rule — `.rule` —
    /// is never touched, the same protection
    /// `testCascadeNeverOverwritesAnAnswerTheUserGaveThemselves` pins for
    /// `confirm`. Without it this cascade would silently flip a purchase the
    /// user settled months ago into a transfer and erase its category.
    ///
    /// `Derived` already excludes `.transfer` from every spending figure, so
    /// no arithmetic changes here.
    @discardableResult
    @MainActor
    func markNotAnExpense(_ id: Transaction.ID,
                          source: CategorizationSource = .queueConfirm) -> Int {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return 0 }
        let key = MerchantKey.normalize(transactions[index].merchant)
        // Captured before the mutation below retypes this row to `.transfer`
        // — the cascade must still match siblings against the kind the
        // group actually was (expense or income), not the kind it is about
        // to become.
        let kind = transactions[index].kind
        // The UNSCOPED rule, because that is the one this function writes and
        // therefore the one undo has to put back. Board #81 made the two
        // different questions: `ruleBefore` is what `upsertRule` will replace,
        // and `contradicted` below is a wider check answering "is there any
        // taught answer here to destroy".
        let rulesBefore = rules.filter { $0.merchantKey == key }

        var touched: [Transaction] = [transactions[index]]
        transactions[index].kind = .transfer
        transactions[index].category = ""
        transactions[index].resolution = .user

        // The same boundary `confirm` draws, and here it also disarms the
        // failure this function's own comment below describes: a mis-tap on
        // «Це не витрата» writing a transfer rule for «На картку» would type
        // EVERY future transfer `.transfer` at ingest, and those rows never
        // reach the queue and never reach a spending figure.
        if GenericMerchant.matches(transactions[index].merchant) {
            pushUndo(label: "Переказ між своїми", rows: touched,
                     touchedRule: false, rulesBefore: [], keys: [key])
            note(source, rows: touched, choice: .notAnExpense)
            persist()
            return touched.count
        }

        // `.pending` AND the same `kind` — identical to `confirm`'s cascade
        // predicate above, for the same reason: an income row and an
        // expense row from the same merchant are independent decisions, and
        // this tap only answered for one of them.
        for i in transactions.indices
        where i != index
            && transactions[i].resolution == .pending
            && transactions[i].kind == kind
            && MerchantKey.normalize(transactions[i].merchant) == key {
            touched.append(transactions[i])
            transactions[i].kind = .transfer
            transactions[i].category = ""
            // .rule, not .user: the person answered about one purchase, and
            // the rule answered for the rest — same distinction `confirm`
            // draws for its own cascade.
            transactions[i].resolution = .rule
        }
        // The same guard `confirm` applies, and for a graver reason. This tap
        // contradicts a taught category rule just as loudly as answering a
        // different category does, and `upsertRule` replaces by merchant key:
        // without the guard, one mis-tap on «Це не витрата» destroyed a rule
        // the user taught weeks ago and left a `scope: nil` transfer rule in
        // its place, so `applyingRule` stamped EVERY future row of that
        // merchant `.transfer` with an empty category at ingest. Those rows
        // never enter the queue and `Derived` excludes them from every
        // spending figure — the user's grocery spending silently reads 0, in
        // every month, forever, and the toast is gone within seconds.
        //
        // Board #11 built the repair (Налаштування → Категорії → «Правила»,
        // and the rule spelled out on the detail screen of any row it
        // decided), so this is no longer unrecoverable. The guard stays: a
        // wrong rule is cheap to prevent and expensive to notice, and nothing
        // sends a person to a settings screen to look for damage they have not
        // been told about.
        //
        // "Ask" is this codebase's safe fallback. The tapped row and its
        // same-kind cascade above still happen either way; only the future
        // auto-typing is withheld.
        //
        // **Every rule for the merchant, not just the unscoped one** (board
        // #81). The rule written below is `scope: nil` and so answers for
        // BOTH kinds; a taught expense category sitting beside it would keep
        // winning for expenses, by `governing`'s precedence, while every
        // income row silently became a transfer. The narrower check would have
        // let exactly the damage this guard exists to prevent through the half
        // of the merchant nobody was looking at.
        let contradicted = rules.contains {
            $0.merchantKey == key && ($0.category != nil || $0.ambiguous)
        }
        if contradicted {
            // Every rule for the merchant goes, and one unscoped marker
            // replaces them. `upsertRule` alone would not do it: it replaces
            // one scope, so a taught expense category would survive beside the
            // marker and — being the more specific rule — keep answering,
            // which is the whole thing this branch exists to stop.
            rules.removeAll { $0.merchantKey == key }
            upsertRule(Rule(merchantKey: key, category: nil, ambiguous: true))
        } else {
            // `scope: nil` — unlike a category rule, a transfer determination
            // is not kind-specific: a merchant that moves money between the
            // owner's own accounts is doing that whichever direction the sign
            // points, so a FUTURE row of the other kind should still inherit
            // it at ingest even though today's cascade, above, only reached
            // the kind actually tapped.
            upsertRule(Rule(merchantKey: key, category: nil, ambiguous: false,
                            kind: .transfer, scope: nil))
        }
        pushUndo(label: "Переказ між своїми", rows: touched,
                 touchedRule: true, rulesBefore: rulesBefore, keys: [key])
        note(source, rows: touched, choice: .notAnExpense)
        persist()
        return touched.count
    }

    /// One tap, every row in the group. Reuses `confirm` / `markNotAnExpense`
    /// on the group's first row so the rule cascade stays in one place.
    @discardableResult
    @MainActor
    func confirmGroup(_ group: MerchantGroup, as choice: CategoryChoice,
                      source: CategorizationSource = .queueConfirm) -> Int {
        guard let first = group.rowIds.first else { return 0 }
        switch choice {
        case .category(let name): return confirm(first, as: name, source: source)
        case .notAnExpense:       return markNotAnExpense(first, source: source)
        }
    }

    /// **Board #103. One category, several cards.** Returns how many rows
    /// changed, so the caller can say «12 покупок → Кафе».
    ///
    /// Draining the demo queue is ~61 taps and an email backfill will be worse;
    /// ten coffee shops should be one gesture. Answering ten cards «Кафе» means
    /// exactly what ten separate confirmations mean — ten merchants, each of
    /// which is a café — so this loops `confirm` rather than reimplementing it.
    /// That keeps contradiction, broadening, ambiguity markers and board #81's
    /// rule scoping in the one place they have ever been tested, and keeps
    /// `confirm` the only function in the app that writes a rule.
    ///
    /// **Refuses a mixed selection.** A merchant's income and its expenses are
    /// separate cards precisely because one category across directions is a
    /// corruption vector — it is how a spending category lands on a salary. The
    /// screen already disables the other kind while a selection stands; this
    /// refuses it again, so the rule survives a screen that forgets.
    @discardableResult
    @MainActor
    func confirmGroups(_ groups: [MerchantGroup], as category: String) -> Int {
        guard !groups.isEmpty, Set(groups.map(\.kind)).count == 1 else { return 0 }
        let keys = Array(Set(groups.map(\.key)))
        // Snapshotted BEFORE the loop, across every merchant in the sweep.
        // `confirm` pushes an entry per call and `pushUndo` caps the stack at
        // one, so ten confirmations would leave an entry that undoes the TENTH
        // merchant and silently abandons nine. A bulk answer is one action and
        // has to undo as one. Four assertions in `QueueBulkTests` fail without
        // the two lines below — measured, by removing them.
        let rowIds = Set(groups.flatMap(\.rowIds))
        let rowsBefore = transactions.filter { rowIds.contains($0.id) }
        let rulesBefore = rules.filter { keys.contains($0.merchantKey) }

        var changed = 0
        for group in groups {
            guard let first = group.rowIds.first else { continue }
            changed += confirm(first, as: category, source: .bulk)
        }
        guard changed > 0 else { return 0 }

        // Replaced, not added to: `undoStack` is one deep by design, and what
        // is on it now is the last merchant's entry, which is not the action
        // anybody took.
        undoStack.removeAll()
        pushUndo(label: "\(groups.count) карток → \(category)", rows: rowsBefore,
                 touchedRule: true, rulesBefore: rulesBefore, keys: keys)
        persist()
        return changed
    }

    /// The chip's one tap: the group confirms through the exact same path the
    /// picker uses — rule learning included.
    ///
    /// `addCategory` stays, and is now almost always a no-op: board #14 put
    /// `PrivatMapper`'s table between the statement and this call, so the name
    /// arriving here is a seeded category in every case the table covers. It
    /// is kept for the case the card explicitly allowed — a statement word
    /// nobody has mapped yet falls through unchanged, and offering it while
    /// refusing to create it would be a button that does nothing.
    @MainActor
    @discardableResult
    func acceptSuggestion(_ group: MerchantGroup) -> Int {
        guard let name = group.suggestion else { return 0 }
        // `.spending`: a suggestion chip carries a statement's own word for a
        // PURCHASE. An income row never reaches the queue's chip path.
        addCategory(name, kind: .spending)
        return confirmGroup(group, as: .category(name), source: .suggestionChip)
    }

    // MARK: rules

    /// Forget one merchant's rule (board #11). The merchant goes back to being
    /// asked about the next time it sends a row.
    ///
    /// **Not one transaction is touched, and that is the whole design.** A rule
    /// decides rows at INGEST and nowhere else — `applyingRule` runs once, as a
    /// row arrives, and the answer it writes is then the row's own. Re-deciding
    /// the rows a rule already settled would mean re-opening months of a
    /// person's history because they tidied one line in Settings, and it would
    /// contradict the merge rule every sync path obeys: once `category`, `kind`
    /// and `resolution` exist, the user owns them. Forgetting is about the
    /// FUTURE. The confirmation dialog says so in as many words.
    ///
    /// **No undo entry is pushed**, and any entry standing for this same
    /// merchant is dropped. The undo stack is the QUEUE's — one entry deep, and
    /// spent by the «Скасувати» on a toast the queue shows for a few seconds.
    /// Pushing one here would arm that button with an action taken on a
    /// different screen, minutes ago, which the person is no longer looking at.
    /// The removal is the sharper half: confirm a merchant in the queue (undo
    /// entry captures `ruleBefore`), walk to Settings, forget that merchant's
    /// rule, come back to a queue tab whose toast is still up, tap «Скасувати»
    /// — and `undoLast` re-appends `ruleBefore`, resurrecting as its older self
    /// the very rule just deleted. Scoped by key, so an undo entry for any
    /// other merchant survives untouched.
    /// Board #81 made this take the rule rather than the merchant. A merchant
    /// can hold two — one for what it pays, one for what it charges — and
    /// «Забути» on one row of Налаштування → Правила must forget the rule that
    /// row is about, not both.
    ///
    /// The undo pruning stays keyed by MERCHANT, deliberately, and does not
    /// narrow with the deletion: an undo entry now restores the merchant's
    /// whole rule table (`rulesBefore`), so an entry for its other rule would
    /// resurrect this one just as surely as one for this rule would.
    func deleteRule(_ rule: Rule) {
        rules.removeAll { $0.merchantKey == rule.merchantKey && $0.scope == rule.scope }
        undoStack.removeAll { $0.merchantKeys.contains(rule.merchantKey) }
        persist()
    }

    // MARK: undo

    /// Restores the rule, and the FIELDS the undone action owns, exactly as
    /// they were. Returns false when there is nothing to undo, so the caller
    /// can hide its toast.
    ///
    /// `category` and `resolution`, not `transactions[i] = row`. The three
    /// producers of an `UndoEntry` — `confirm`, `setCategory`, `skip` —
    /// between them write exactly those two fields, so they are the complete
    /// set this entry may put back. Assigning the whole snapshot also put
    /// back `receiptId` and `splits`, which no queue action ever touched and
    /// which the receipts screens edit on their own: expand a purchase in
    /// the feed, confirm its splits, detach the receipt (which deletes the
    /// receipt record and clears the splits), then undo the unrelated
    /// category decision from before all that — and the splits came back,
    /// describing goods that no longer exist, with `receiptId` pointing at a
    /// deleted receipt. `TransactionRow` shows its disclosure on
    /// `receiptId != nil` while `store.receipt(for:)` returns nil, so the
    /// visible result was a chevron that expands onto nothing.
    @discardableResult
    func undoLast() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        for row in entry.rows {
            if let i = transactions.firstIndex(where: { $0.id == row.id }) {
                transactions[i].category = row.category
                transactions[i].resolution = row.resolution
                transactions[i].kind = row.kind
            }
        }
        // Only actions that wrote a rule may withdraw one. Undoing a skip or a
        // detail edit must leave `rules` exactly as it found them.
        if entry.touchedRule {
            rules.removeAll { entry.merchantKeys.contains($0.merchantKey) }
            rules.append(contentsOf: entry.rulesBefore)
        }
        persist()
        return true
    }

    // MARK: internals

    /// The one tap on the categorization log, so the mutations above carry a
    /// single readable line each instead of a fence. In Release the body is
    /// empty and every call compiles away.
    ///
    /// `rows` are the pre-mutation snapshots the undo entry already captured
    /// — what arrived, not what it became — with the acted-on row first.
    private func note(_ source: CategorizationSource, rows: [Transaction],
                      choice: CategoryChoice) {
#if DEBUG
        // Every path into these mutations is a tap or a `@MainActor` sync
        // commit, so the assumption holds — and if it ever stops holding it
        // traps here, loudly, instead of racing a Debug-only file.
        MainActor.assumeIsolated {
            categorizationLog.record(source, rows: rows, choice: choice)
        }
#endif
    }

    /// Replaces the rule with the SAME merchant and the same scope, board #81.
    ///
    /// Keyed by merchant alone, this was the whole defect: a merchant's income
    /// answer and its expense answer are different facts, and writing one
    /// deleted the other. A `nil`-scope rule is its own entry too — it means
    /// "any kind", which is a third distinct answer and not a wildcard that
    /// absorbs the other two.
    private func upsertRule(_ rule: Rule) {
        rules.removeAll { $0.merchantKey == rule.merchantKey && $0.scope == rule.scope }
        rules.append(rule)
    }

    private func pushUndo(label: String, rows: [Transaction], touchedRule: Bool,
                          rulesBefore: [Rule], keys: [String]) {
        undoStack.append(UndoEntry(label: label, rows: rows, touchedRule: touchedRule,
                                   rulesBefore: rulesBefore, merchantKeys: keys))
        // One action's worth is all any screen offers; an unbounded stack would
        // hold every row of a long queue session in memory for no one.
        if undoStack.count > 1 { undoStack.removeFirst() }
    }
}
