import XCTest
@testable import MonitorFinance

/// Board #11: the rules the app teaches itself, made visible and retractable.
///
/// Until this card a rule could only ever be written. `upsertRule` replaced one,
/// `renameCategory` repointed one, and nothing anywhere removed one — so a
/// wrong answer taught by a single mis-tap in the queue kept deciding that
/// merchant's rows at ingest, silently, for as long as the app was installed.
@MainActor
final class RulesTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private let shop = "Крамниця-Приклад"
    private var shopKey: String { MerchantKey.normalize(shop) }

    private func tx(_ merchant: String, _ day: Int = 1,
                    category: String = "", resolution: Resolution = .pending,
                    kind: TxKind = .expense, amount: Int = -10_000) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!,
                    kind: kind, category: category, merchant: merchant, amount: amount,
                    cardSuffix: "*0000", bankId: "monobank", receiptId: nil, splits: [],
                    resolution: resolution, suggestions: [])
    }

    private func store(_ txs: [Transaction], rules: [Rule] = []) throws -> AppStore {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(), keychain: keychain)
        s.transactions = txs
        s.rules = rules
        return s
    }

    // MARK: deleteRule — the acceptance line

    /// **The card's own acceptance criterion.** Forgetting a rule is a statement
    /// about what happens NEXT; every row the rule already decided keeps the
    /// category, the kind and the resolution it was given.
    ///
    /// The alternative — re-opening those rows — would re-queue months of a
    /// person's history because they tidied one line in Settings, and would
    /// break the merge rule every sync path obeys: once `category`, `kind` and
    /// `resolution` exist, the user owns them.
    func testForgettingARuleLeavesEveryRowItAlreadyDecidedExactlyAsItWas() throws {
        let settled = tx(shop, 1, category: "Продукти", resolution: .rule)
        let byHand = tx(shop, 2, category: "Продукти", resolution: .user)
        let other = tx("Сервіс-Приклад", 3, category: "Послуги", resolution: .rule)
        let s = try store([settled, byHand, other],
                          rules: [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)])

        s.forgetRules(for: shopKey)

        XCTAssertTrue(s.rules.isEmpty)
        XCTAssertEqual(s.transactions.count, 3, "no row may be added or removed")
        for before in [settled, byHand, other] {
            let after = try XCTUnwrap(s.transactions.first { $0.id == before.id })
            XCTAssertEqual(after.category, before.category, before.merchant)
            XCTAssertEqual(after.resolution, before.resolution, before.merchant)
            XCTAssertEqual(after.kind, before.kind, before.merchant)
        }
    }

    /// The other half of the same promise, and the half a person is actually
    /// asking for: the merchant is asked about again. Proven through the ingest
    /// path rather than by re-reading `rules`, because `applyingRule` is the
    /// only thing a rule ever does — a rule removed from the array but still
    /// applied would pass a shallower assertion.
    func testAfterForgettingARuleTheNextRowFromThatMerchantIsAskedAboutAgain() throws {
        let s = try store([], rules: [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)])

        s.ingestRows([tx(shop, 4)])
        XCTAssertEqual(s.transactions.last?.resolution, .rule,
                       "precondition: the rule decides a row while it stands")
        XCTAssertEqual(s.transactions.last?.category, "Продукти")

        s.forgetRules(for: shopKey)
        s.ingestRows([tx(shop, 5)])

        let arrived = try XCTUnwrap(s.transactions.last)
        XCTAssertEqual(arrived.resolution, .pending, "the merchant must go back into the queue")
        XCTAssertEqual(arrived.category, "")
    }

    /// A transfer rule is the one that hides rows from every spending figure —
    /// `applyingRule` types the row `.transfer`, and it then reaches no queue
    /// and no total. Board #6 declined to migrate the rows taught under the old
    /// «Це не витрата» and named this screen as where the RULES become
    /// repairable, so forgetting one has to actually stop the typing.
    func testForgettingATransferRuleStopsFutureRowsBeingTypedAsTransfers() throws {
        let s = try store([], rules: [Rule(merchantKey: shopKey, category: nil, ambiguous: false,
                                           kind: .transfer, scope: nil)])

        s.ingestRows([tx(shop, 4)])
        XCTAssertEqual(s.transactions.last?.kind, .transfer, "precondition: the rule types the row")

        s.forgetRules(for: shopKey)
        s.ingestRows([tx(shop, 5)])

        let arrived = try XCTUnwrap(s.transactions.last)
        XCTAssertEqual(arrived.kind, .expense)
        XCTAssertEqual(arrived.resolution, .pending)
    }

    func testForgettingAMerchantWithNoRuleChangesNothing() throws {
        let s = try store([tx(shop, 1, category: "Продукти", resolution: .rule)],
                          rules: [Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"),
                                       category: "Послуги", ambiguous: false)])
        s.forgetRules(for: shopKey)
        XCTAssertEqual(s.rules.count, 1, "another merchant's rule must survive")
    }

    // MARK: the undo stack

    /// Settings is not the queue, and must not arm the queue's «Скасувати».
    ///
    /// The undo stack is one entry deep and is spent by a toast the queue shows
    /// for a few seconds. An entry pushed from here would hand that button an
    /// action taken on another screen, minutes earlier, which the person is no
    /// longer looking at.
    func testForgettingARulePushesNoUndoEntry() throws {
        let s = try store([tx(shop, 1, category: "Продукти", resolution: .rule)],
                          rules: [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)])
        s.forgetRules(for: shopKey)
        XCTAssertTrue(s.undoStack.isEmpty)
    }

    /// The resurrection this guard exists for. Confirm a merchant in the queue
    /// — the undo entry captures the rule as it was BEFORE — then walk to
    /// Settings and forget that merchant's rule. The queue is a tab, so its
    /// toast can still be on screen when the person comes back; tapping
    /// «Скасувати» re-appends `ruleBefore` and the rule just deleted returns as
    /// its older self, with nothing on screen to explain it.
    func testForgettingARuleDropsAStandingUndoThatWouldBringItBack() throws {
        let older = Rule(merchantKey: shopKey, category: "Кафе та ресторани", ambiguous: false)
        let row = tx(shop, 1)
        let s = try store([row], rules: [older])

        s.confirm(row.id, as: "Продукти")
        XCTAssertEqual(s.undoStack.last?.rulesBefore, [older],
                       "precondition: undo would restore the old rule")

        s.forgetRules(for: shopKey)
        XCTAssertFalse(s.undoLast(), "there must be nothing left to undo for this merchant")
        XCTAssertTrue(s.rules.isEmpty, "the forgotten rule must not come back")
    }

    /// …and scoped by merchant, or forgetting one rule would silently disarm
    /// the undo of an unrelated confirmation the person just made.
    func testForgettingOneRuleLeavesAnotherMerchantsUndoIntact() throws {
        let row = tx("Сервіс-Приклад", 1)
        let s = try store([row], rules: [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)])

        s.confirm(row.id, as: "Послуги")
        s.forgetRules(for: shopKey)

        XCTAssertEqual(s.undoStack.count, 1)
        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.transactions[0].resolution, .pending, "the other merchant's undo still works")
    }

    // MARK: RuleText — one vocabulary for two screens

    func testARuleReadsAsWhateverItActuallyDoes() {
        XCTAssertEqual(RuleText.answer(Rule(merchantKey: "k", category: "Продукти", ambiguous: false)),
                       "Продукти")
        XCTAssertEqual(RuleText.answer(Rule(merchantKey: "k", category: nil, ambiguous: true)),
                       "питаємо щоразу")
        XCTAssertEqual(RuleText.answer(Rule(merchantKey: "k", category: nil, ambiguous: false,
                                            kind: .transfer, scope: nil)),
                       "переказ між своїми картками")
    }

    /// The precedence `applyingRule` reads them in. An ambiguous rule can still
    /// CARRY a category — `upsertRule` writes nil, but a rule decoded from an
    /// older `rules.json` need not — and `applyingRule` bails on `ambiguous`
    /// before it looks at one. Reading them the other way round would promise a
    /// category that will never be applied.
    func testAnAmbiguousRuleCarryingACategoryStillReadsAsAsking() {
        XCTAssertEqual(RuleText.answer(Rule(merchantKey: "k", category: "Продукти", ambiguous: true)),
                       "питаємо щоразу")
    }

    /// A rule with nothing in it decides nothing — `applyingRule` falls through
    /// every branch and returns the row untouched — so it must not render as an
    /// arrow pointing at a blank.
    func testARuleThatDecidesNothingSaysSoRatherThanShowingAnEmptyAnswer() {
        let empty = RuleText.answer(Rule(merchantKey: "k", category: nil, ambiguous: false))
        XCTAssertEqual(empty, "питаємо щоразу")
        XCTAssertFalse(empty.isEmpty)
    }

    /// Two of the five rules the demo ships are refused by `applyingRule`'s
    /// first line, whatever they say. Listing them beside the live ones with
    /// nothing to tell them apart would be a fresh untruth about rules told by
    /// the screen built to end them.
    func testARuleAGenericMerchantCanNeverUseIsMarkedInert() {
        XCTAssertTrue(RuleText.isInert(Rule(merchantKey: MerchantKey.normalize("Переказ-Приклад"),
                                            category: "Продукти", ambiguous: false)))
        XCTAssertTrue(RuleText.isInert(Rule(merchantKey: "*1234", category: nil, ambiguous: true)))
        XCTAssertFalse(RuleText.isInert(Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)))
    }

    /// The stored key is lowercased, and a lowercased shop name is a spelling
    /// nobody's statement contains. Newest row wins, matching how
    /// `AppStore.groups` picks a card's display name.
    func testTheMerchantIsShownAsABankWroteItNotAsTheKeyStoresIt() {
        let rows = [tx("КРАМНИЦЯ-ПРИКЛАД", 1), tx("Крамниця-Приклад", 9)]
        XCTAssertEqual(RuleText.summarise([shopKey], in: rows)[shopKey],
                       RuleText.Summary(name: "Крамниця-Приклад", count: 2))
    }

    /// A rule outlives the rows that taught it — a merchant not seen this year,
    /// a reset that keeps rules. A row with no name at all cannot be forgotten
    /// by someone who cannot tell which rule it is.
    func testAMerchantWithNoRowsLeftStillShowsSomethingToIdentifyIt() {
        XCTAssertEqual(RuleText.summarise([shopKey], in: [])[shopKey],
                       RuleText.Summary(name: shopKey, count: 0))
    }

    /// Every rule answered in ONE pass over the transactions. The obvious
    /// shape — a name lookup and a count, each filtering the whole array, per
    /// row — is quadratic in exactly the direction that hurts: this screen
    /// exists for the person with a year of history and a hundred merchants
    /// answered.
    func testEveryRuleIsSummarisedFromASingleWalkOfTheTransactions() {
        let rows = [tx(shop, 1), tx(shop, 2), tx("Сервіс-Приклад", 3), tx("Інше-Приклад", 4)]
        let facts = RuleText.summarise([shopKey, MerchantKey.normalize("Сервіс-Приклад"),
                                        MerchantKey.normalize("Ніколи-Приклад")], in: rows)
        XCTAssertEqual(facts.count, 3, "every key asked about must come back, rows or not")
        XCTAssertEqual(facts[shopKey]?.count, 2)
        XCTAssertEqual(facts[MerchantKey.normalize("Сервіс-Приклад")]?.count, 1)
        XCTAssertEqual(facts[MerchantKey.normalize("Ніколи-Приклад")]?.count, 0)
        XCTAssertNil(facts[MerchantKey.normalize("Інше-Приклад")],
                     "a merchant with no rule must not be summarised")
    }

    /// Forgetting is the only way out of an ambiguous merchant. `confirm`
    /// refuses to write a rule for one — `wasAmbiguous` keeps it asking — so a
    /// single mis-tap that contradicted an earlier answer marked a merchant
    /// "ask every time" permanently, with the detail toggle inert and nothing
    /// on screen to explain it.
    func testForgettingAnAmbiguousRuleLetsTheMerchantBeAnsweredAgain() throws {
        let row = tx(shop, 1)
        let s = try store([row], rules: [Rule(merchantKey: shopKey, category: nil, ambiguous: true)])

        s.confirm(row.id, as: "Продукти")
        XCTAssertTrue(try XCTUnwrap(s.rules.first).ambiguous,
                      "precondition: answering an ambiguous merchant leaves it ambiguous")

        s.forgetRules(for: shopKey)
        let next = tx(shop, 2)
        s.transactions.append(next)
        s.confirm(next.id, as: "Продукти")

        let taught = try XCTUnwrap(s.rules.first)
        XCTAssertFalse(taught.ambiguous, "a forgotten merchant must be teachable again")
        XCTAssertEqual(taught.category, "Продукти")
    }

    // MARK: what the detail screen offers

    func testTheDetailScreenSpellsOutAStandingRule() {
        let row = tx(shop, 1, category: "Продукти", resolution: .rule)
        let state = TransactionDetailView.ruleState(
            for: row, rule: Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false), .uk)
        XCTAssertEqual(state, .stands("Правило: «\(shop)» → Продукти"))
    }

    /// A generic merchant CAN carry a rule (the demo ships two), so the rule is
    /// reported first and the sentence says it is inert. Leading with the
    /// generic check instead would tell a person there is no rule while one sits
    /// in the table under this merchant's name — unforgettable, because the
    /// screen denied it existed.
    func testAnInertRuleIsStillShownAndStillSaysItIsInert() throws {
        let row = tx("Переказ-Приклад", 1, category: "Продукти")
        let rule = Rule(merchantKey: MerchantKey.normalize("Переказ-Приклад"),
                        category: "Продукти", ambiguous: false)
        guard case .stands(let sentence) = TransactionDetailView.ruleState(for: row, rule: rule, .uk) else {
            return XCTFail("an existing rule must be shown even on a generic merchant")
        }
        XCTAssertTrue(sentence.contains("не діє"), sentence)
    }

    /// `confirm` writes no rule for a generic merchant and returns early, so the
    /// toggle used to report «Правило збережено» over a rule table it had not
    /// touched, then spring back off at the next render.
    func testAMerchantThatCanNeverHaveARuleIsExplainedRatherThanOfferedAToggle() {
        let state = TransactionDetailView.ruleState(for: tx("Переказ-Приклад", 1, category: "Продукти"),
                                                    rule: nil, .uk)
        guard case .cannot(let sentence) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(sentence.contains("питаємо щоразу"), sentence)
    }

    /// «Завжди відносити … до цієї категорії» is a sentence about a category,
    /// and a `.transfer` row has none.
    func testARowWithNoCategoryIsToldWhatToDoFirst() {
        let state = TransactionDetailView.ruleState(for: tx(shop, 1, kind: .transfer), rule: nil, .uk)
        guard case .cannot(let sentence) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(sentence.contains("Спершу оберіть категорію"), sentence)
    }

    /// The invariant the card bought: the toggle exists exactly when tapping it
    /// teaches a rule. It used to exist always and be `.disabled` in three
    /// states it could never leave.
    func testTheToggleIsOfferedOnlyWhenItWouldActuallyTeachSomething() {
        XCTAssertEqual(TransactionDetailView.ruleState(for: tx(shop, 1, category: "Продукти"), rule: nil, .uk),
                       .teachable)
    }

    // MARK: board #81 — a merchant may hold a rule per kind

    /// The identity that makes two rules possible. Keyed by merchant alone,
    /// SwiftUI's `ForEach` sees one id twice and draws one row for two rules,
    /// and all four of the rules screen's accessibility identifiers collide.
    func testARulesIdentityIsItsMerchantAndItsScope() {
        let spending = Rule(merchantKey: shopKey, category: "Техніка", ambiguous: false,
                            scope: .expense)
        let income = Rule(merchantKey: shopKey, category: "Зарплата", ambiguous: false,
                          scope: .income)
        let anyKind = Rule(merchantKey: shopKey, category: "Техніка", ambiguous: false)

        XCTAssertEqual(Set([spending.id, income.id, anyKind.id]).count, 3,
                       "three different answers must be three different rules")
        XCTAssertEqual(anyKind.id, "\(shopKey)|", "an unscoped rule keeps a stable id of its own")
    }

    /// **An unscoped rule still means "any kind".** Every rule already on a
    /// phone is one of these, or scoped and unique, so board #81 needs no
    /// migration — but only if the old shape keeps working untouched.
    func testAnUnscopedRuleStillAnswersForEveryKind() {
        let anyKind = [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)]
        for kind in [TxKind.expense, .income, .transfer] {
            XCTAssertEqual(anyKind.governing(shopKey, kind: kind)?.category, "Продукти",
                           "an unscoped rule answers for \(kind.rawValue)")
        }
    }

    /// Precedence, and why it is not `first(where:)`. `rules` is appended to in
    /// the order a person happened to answer, so array order is not a
    /// specification — the more specific rule has to win by being asked for.
    func testAScopedRuleBeatsAnUnscopedOneWhicheverWasTaughtFirst() {
        let scoped = Rule(merchantKey: shopKey, category: "Техніка", ambiguous: false,
                          scope: .expense)
        let anyKind = Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)

        for table in [[scoped, anyKind], [anyKind, scoped]] {
            XCTAssertEqual(table.governing(shopKey, kind: .expense)?.category, "Техніка",
                           "the rule for this kind wins")
            XCTAssertEqual(table.governing(shopKey, kind: .income)?.category, "Продукти",
                           "and the unscoped one still covers the kinds it does not")
        }
    }

    func testARuleForAnotherMerchantIsNeverGoverning() {
        let mine = [Rule(merchantKey: shopKey, category: "Продукти", ambiguous: false)]
        XCTAssertNil(mine.governing(MerchantKey.normalize("Сервіс-Приклад"), kind: .expense))
    }

    /// «Забути» on one row of Налаштування → Правила forgets that rule. The
    /// merchant's other answer is a different fact and stays.
    func testForgettingOneOfAMerchantsTwoRulesLeavesTheOther() throws {
        let spending = Rule(merchantKey: shopKey, category: "Техніка", ambiguous: false,
                            scope: .expense)
        let income = Rule(merchantKey: shopKey, category: "Зарплата", ambiguous: false,
                          scope: .income)
        let s = try store([], rules: [spending, income])

        s.deleteRule(spending)

        XCTAssertEqual(s.rules, [income], "only the rule the person pointed at")
        XCTAssertEqual(s.rules.governing(shopKey, kind: .income)?.category, "Зарплата")
        XCTAssertNil(s.rules.governing(shopKey, kind: .expense),
                     "and the forgotten one asks again")
    }

    /// Undo restores the merchant's rule table exactly, which is stronger than
    /// "removes the rule it wrote". Keyed by merchant alone, undoing a
    /// confirmation of an expense would have deleted the income answer it
    /// never touched.
    func testUndoingOneKindsConfirmationLeavesTheOtherKindsRuleAlone() throws {
        let income = Rule(merchantKey: shopKey, category: "Зарплата", ambiguous: false,
                          scope: .income)
        let row = tx(shop, 1)
        let s = try store([row], rules: [income])

        s.confirm(row.id, as: "Техніка")
        XCTAssertEqual(s.rules.count, 2, "precondition: the confirmation added a second rule")

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.rules, [income], "the income answer was never part of this action")
    }

    /// What the rules screen says to tell two rows under one merchant apart.
    func testTheScopeNoteNamesTheKindARuleAnswersFor() {
        func note(_ scope: TxKind?) -> String? {
            RuleText.scopeNote(Rule(merchantKey: shopKey, category: "Техніка",
                                    ambiguous: false, scope: scope))
        }
        XCTAssertEqual(note(.expense), "для витрат")
        XCTAssertEqual(note(.income), "для надходжень")
        XCTAssertNil(note(nil), "a rule that answers for everything qualifies nothing")
    }

    /// Every scope note has an English entry, because the qualifier is the only
    /// thing telling two rows apart and a Ukrainian one on an English screen
    /// would read as a bug in the row rather than a missing translation.
    func testEveryScopeNoteIsTranslated() {
        for scope in [TxKind.expense, .income, .transfer] {
            let note = try? XCTUnwrap(
                RuleText.scopeNote(Rule(merchantKey: shopKey, category: "Техніка",
                                        ambiguous: false, scope: scope)))
            XCTAssertNotEqual(L10n.t(note ?? "", .en), note,
                              "«\(note ?? "")» has no English entry")
        }
    }


}

/// Board #81 made `deleteRule` take a rule rather than a merchant, because a
/// merchant can hold two — one for what it pays, one for what it charges.
///
/// Every test above is about a merchant with exactly one rule, and "forget
/// what this merchant taught us" is what they mean. Kept here rather than on
/// `AppStore`: the app has no screen that forgets a merchant wholesale, and
/// adding the convenience to the store would invite one.
@MainActor
extension AppStore {
    func forgetRules(for merchantKey: String) {
        for rule in rules.filter({ $0.merchantKey == merchantKey }) { deleteRule(rule) }
    }
}
