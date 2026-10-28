import XCTest
@testable import MonitorFinance

@MainActor
final class QueueMutationTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func pendingTx(_ merchant: String, _ day: Int = 1, amount: Int = -10_000) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!,
                    kind: .expense, category: "", merchant: merchant, amount: amount,
                    cardSuffix: "*0000", bankId: "monobank", receiptId: nil, splits: [],
                    resolution: .pending, suggestions: ["Продукти", "Послуги", "Інше"])
    }

    /// A store whose transactions are exactly the rows given — the seed's
    /// would drown the assertions.
    private func store(_ txs: [Transaction]) throws -> AppStore {
        let store = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(), keychain: keychain)
        store.transactions = txs
        store.rules = []
        return store
    }

    /// The rows still awaiting an answer — the row-level equivalent of
    /// `AppStore.groups`' membership test, without folding them into cards.
    private func pendingRows(_ s: AppStore) -> [Transaction] {
        s.transactions.filter { $0.resolution == .pending }
    }
    private func pendingCount(_ s: AppStore) -> Int { pendingRows(s).count }

    // MARK: confirm

    /// A merchant already marked ambiguous is answered for ONE row and no
    /// more: the rule stays ambiguous, and the sibling purchase keeps waiting
    /// for its own answer instead of inheriting one.
    ///
    /// This is what the seed does on a cold launch — its only rules belong to
    /// an ambiguous merchant — so it is the branch a first-run user actually
    /// takes, and nothing asserted it until now. Deleting the `wasAmbiguous`
    /// term from `confirm`'s guard leaves every other test in this file green.
    func testConfirmingAnAmbiguousMerchantNeitherCascadesNorSettlesTheRule() throws {
        let one = pendingTx("Сервіс-Приклад", 1)
        let two = pendingTx("Сервіс-Приклад", 2)
        let s = try store([one, two])
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"), category: nil, ambiguous: true)]

        let changed = s.confirm(one.id, as: "Послуги")

        XCTAssertEqual(changed, 1, "an ambiguous merchant answers for one row, not for its siblings")
        XCTAssertEqual(s.transactions.first { $0.id == one.id }?.resolution, .user)
        // The sibling is untouched — still waiting, still uncategorised.
        let sibling = try XCTUnwrap(s.transactions.first { $0.id == two.id })
        XCTAssertEqual(sibling.resolution, .pending)
        XCTAssertEqual(sibling.category, "")
        // …and the rule has not quietly settled on the answer just given.
        XCTAssertEqual(s.rules.count, 1)
        XCTAssertTrue(s.rules[0].ambiguous)
        XCTAssertNil(s.rules[0].category)
    }

    func testConfirmResolvesTheRowAndWritesARule() throws {
        let tx = pendingTx("Сервіс-Приклад")
        let s = try store([tx])
        let changed = s.confirm(tx.id, as: "Послуги")

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(s.transactions[0].category, "Послуги")
        XCTAssertEqual(s.transactions[0].resolution, .user)
        XCTAssertEqual(s.rules.first?.merchantKey, MerchantKey.normalize("Сервіс-Приклад"))
        XCTAssertEqual(s.rules.first?.category, "Послуги")
        XCTAssertFalse(s.rules.first!.ambiguous)
    }

    func testConfirmCascadesToOtherPendingRowsOfTheSameMerchant() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("Сервіс-Приклад", 2),
                    pendingTx("Сервіс-Приклад", 3), pendingTx("Маркет-Приклад", 4)]
        let s = try store(rows)
        let changed = s.confirm(rows[0].id, as: "Послуги")

        XCTAssertEqual(changed, 3, "the confirmed row plus the two other pending Сервіс-Приклад rows")
        XCTAssertEqual(s.transactions.filter { $0.category == "Послуги" }.count, 3)
        XCTAssertEqual(s.transactions.first { $0.merchant == "Маркет-Приклад" }?.resolution, .pending,
                       "a different merchant must not be touched")
        XCTAssertEqual(s.transactions[1].resolution, .rule,
                       "cascaded rows resolved by rule, not by the user directly")
    }

    /// Review finding: a merchant's income and its expenses are independent
    /// decisions — `MerchantGroup` splits on kind for exactly this reason —
    /// so confirming the expense side must never silently resolve, and
    /// withdraw from the queue, a still-`.pending` row of the OTHER kind.
    /// Before this fix a same-merchant salary would be stamped with a
    /// spending category and vanish from the queue without ever being shown.
    func testConfirmingAnExpenseGroupLeavesASameMerchantIncomeRowPending() throws {
        let expense = pendingTx("Продавець", 1)
        var income = pendingTx("Продавець", 2)
        income.kind = .income
        let s = try store([expense, income])

        XCTAssertEqual(s.confirm(expense.id, as: "Продукти"), 1,
                       "the cascade must not reach across kinds")
        let incomeRow = try XCTUnwrap(s.transactions.first { $0.id == income.id })
        XCTAssertEqual(incomeRow.resolution, .pending)
        XCTAssertEqual(incomeRow.category, "",
                       "not silently typed with a spending category")
    }

    /// Merchant matching must not depend on case or stray whitespace, which
    /// bank statement text is full of.
    func testCascadeMatchesMerchantsCaseAndWhitespaceInsensitively() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("  сервіс-приклад ", 2)]
        let s = try store(rows)
        XCTAssertEqual(s.confirm(rows[0].id, as: "Послуги"), 2)
    }

    /// The queue is now exactly the set of `.pending` rows — there is no
    /// window and no separate "currently shown" membership any more — so a
    /// row already settled by an earlier rule (`.rule`) is never re-decided
    /// by a sibling's cascade, whatever its date.
    func testCascadeNeverTouchesAnAlreadyRuleResolvedRow() throws {
        var settled = pendingTx("Сервіс-Приклад", 1)
        settled.resolution = .rule
        settled.category = "Інше"
        let target = pendingTx("Сервіс-Приклад", 2)
        let s = try store([settled, target])

        XCTAssertEqual(s.confirm(target.id, as: "Послуги"), 1)
        XCTAssertEqual(s.transactions[0].category, "Інше",
                       "an already-resolved row is not re-decided by a later cascade")
    }

    /// The other side of the same line: an answer the user gave with their
    /// own hands is never overwritten either. `confirm`'s cascade only ever
    /// touches `.pending` siblings, so both `.rule` and `.user` rows are safe
    /// from it — this pins the `.user` half.
    func testCascadeNeverOverwritesAnAnswerTheUserGaveThemselves() throws {
        var answered = pendingTx("Сервіс-Приклад", 1)
        answered.resolution = .user
        answered.category = "Інше"
        let target = pendingTx("Сервіс-Приклад", 2)
        let s = try store([answered, target])

        XCTAssertEqual(s.confirm(target.id, as: "Послуги"), 1)
        XCTAssertEqual(s.transactions[0].category, "Інше")
        XCTAssertEqual(s.transactions[0].resolution, .user)
    }

    // MARK: ambiguity

    func testContradictingAnEarlierAnswerMarksTheMerchantAmbiguous() throws {
        let first = pendingTx("Крамниця-Приклад", 1)
        let second = pendingTx("Крамниця-Приклад", 2)
        let s = try store([first, second])

        s.confirm(first.id, as: "Продукти")
        // The cascade already resolved `second`; the user reopens it and disagrees.
        s.confirm(second.id, as: "Кредит")

        let rule = s.rules.first { $0.merchantKey == MerchantKey.normalize("Крамниця-Приклад") }
        XCTAssertTrue(rule?.ambiguous == true, "щоразу питати")
        XCTAssertNil(rule?.category, "an ambiguous merchant has no answer to apply")
    }

    func testAnAmbiguousMerchantNeverCascadesAgain() throws {
        // FOUR rows, and two are returned to .pending before the final confirm.
        // With only one pending row the cascade has nothing to grab and the
        // assertion below holds even when ambiguity is ignored — which is
        // exactly how an earlier version of this test passed over a broken
        // implementation.
        let rows = [pendingTx("Крамниця-Приклад", 1), pendingTx("Крамниця-Приклад", 2),
                    pendingTx("Крамниця-Приклад", 3), pendingTx("Крамниця-Приклад", 4)]
        let s = try store(rows)
        s.confirm(rows[0].id, as: "Продукти")
        s.confirm(rows[1].id, as: "Кредит")          // the contradiction — now ambiguous

        for i in [2, 3] {                            // two fresh rows arrive
            s.transactions[i].resolution = .pending
            s.transactions[i].category = ""
        }

        XCTAssertEqual(s.confirm(rows[2].id, as: "Комуналка"), 1,
                       "only the row in hand — an ambiguous merchant is never applied wholesale")
        XCTAssertEqual(s.transactions[3].resolution, .pending,
                       "the other pending row must be left alone for the user to answer")
    }

    // MARK: a row skipped by an older build (board #26)

    /// `skip`/`reopen` are gone — dead code no UI ever called. The stored
    /// VALUE is not: `Resolution.skipped` stays decodable, because removing a
    /// case from a persisted raw-value enum would make one legacy row throw
    /// and `AppStore.init`'s `try?` discard the whole file.
    ///
    /// This is what that row is worth once it lands: still decoded, still not
    /// counted as an open question.
    func testARowSkippedByAnOlderBuildStillLoadsAndIsNotPending() throws {
        var tx = pendingTx("PORTMONE")
        tx.resolution = .skipped
        tx.category = "Послуги"

        let reloaded = try SeedLoader.decoder.decode(
            Transaction.self, from: SeedLoader.encoder.encode(tx))
        XCTAssertEqual(reloaded.resolution, .skipped, "the case must survive a round trip")

        let s = try store([tx])
        XCTAssertTrue(pendingRows(s).isEmpty)
        XCTAssertEqual(s.pendingRowCount, 0,
                       "a decision the user already made must not keep being asked")
        XCTAssertEqual(s.transactions[0].category, "Послуги",
                       "and nothing rewrites it on load")
    }

    // MARK: undo

    func testUndoRestoresEveryRowACascadeTouched() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("Сервіс-Приклад", 2), pendingTx("Сервіс-Приклад", 3)]
        let s = try store(rows)
        s.confirm(rows[0].id, as: "Послуги")
        // 0, not 2: the queue is exactly the `.pending` rows, and the cascade
        // resolves every sibling to `.rule` in the same tap — a merchant is
        // answered once, not asked about again for its other purchases.
        XCTAssertEqual(pendingCount(s), 0)

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(pendingCount(s), 3, "undo puts back all three, not just the confirmed one")
        XCTAssertTrue(s.transactions.allSatisfy { $0.category.isEmpty })
        XCTAssertTrue(s.rules.isEmpty, "the rule the confirmation wrote is withdrawn too")
    }

    func testUndoRestoresAPreviouslyExistingRuleRatherThanDeletingIt() throws {
        let tx = pendingTx("Сервіс-Приклад")
        let s = try store([tx])
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"), category: "Інше", ambiguous: false)]

        s.confirm(tx.id, as: "Послуги")
        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.rules.first?.category, "Інше",
                       "undo restores the prior rule; it does not leave the merchant ruleless")
    }

    /// Undoing an action that never touched `rules` must not delete the rule
    /// that merchant already had. "No rule was involved" and "there was no
    /// rule" are different states, and conflating them loses data.
    /// Was written around `skip`, which board #26 deleted. The claim is not
    /// about skipping: it is that undoing an action which pushed
    /// `touchedRule: false` must leave a rule that was already there alone.
    /// `setNotAnExpense` is the surviving action of that shape — a detail-screen
    /// decision that writes no rule — so the test moved onto it rather than
    /// leaving with the dead code it happened to use.
    func testUndoingARuleLessActionLeavesAnUnrelatedExistingRuleAlone() throws {
        let tx = pendingTx("Сервіс-Приклад")
        let s = try store([tx])
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"),
                        category: "Послуги", ambiguous: false)]

        s.setNotAnExpense(tx.id)
        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.rules.first?.category, "Послуги",
                       "undo must not withdraw a rule the action never wrote")
        XCTAssertEqual(s.rules.count, 1)
    }

    func testUndoOnAnEmptyStackIsFalseAndChangesNothing() throws {
        let s = try store([pendingTx("Сервіс-Приклад")])
        XCTAssertFalse(s.undoLast())
        XCTAssertEqual(pendingCount(s), 1)
    }

    func testUndoIsSingleUsePerAction() throws {
        let tx = pendingTx("Сервіс-Приклад")
        let s = try store([tx])
        s.confirm(tx.id, as: "Послуги")
        XCTAssertTrue(s.undoLast())
        XCTAssertFalse(s.undoLast(), "one undo per action; the stack is now empty")
    }

    /// Was `testSkipIsUndoable`, retargeted for the same reason as the rule
    /// test above: the claim is that a queue decision can be taken back and
    /// puts the row back in the queue, and `setNotAnExpense` is the one that
    /// still exists.
    func testAQueueDecisionIsUndoableAndReturnsTheRow() throws {
        let tx = pendingTx("PORTMONE")
        let s = try store([tx])
        s.setNotAnExpense(tx.id)
        XCTAssertEqual(pendingCount(s), 0, "precondition: the decision took the row out")
        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(pendingCount(s), 1)
    }

    // MARK: detail edits

    func testSetCategoryFromDetailWritesNoRuleAndDoesNotCascade() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("Сервіс-Приклад", 2)]
        let s = try store(rows)
        s.setCategory(rows[0].id, to: "Послуги")

        XCTAssertEqual(s.transactions[0].category, "Послуги")
        XCTAssertEqual(s.transactions[1].resolution, .pending,
                       "editing one row in detail is not a statement about the merchant")
        XCTAssertTrue(s.rules.isEmpty)
    }

    // MARK: «Переказ між своїми картками» from the detail screen (board #13)

    /// The headline. The detail screen used to call the QUEUE's mutation, so
    /// one tap on one purchase cascaded to every pending row of that merchant
    /// and taught a `.transfer` rule — silently, with no toast and nothing on
    /// screen. The queue may do that; it says so. Detail answers for the row
    /// in hand, exactly as `setCategory` beside it always has.
    func testDetailAnswersForThisRowAndNeitherCascadesNorTeaches() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("Сервіс-Приклад", 2),
                    pendingTx("Сервіс-Приклад", 3)]
        let s = try store(rows)

        s.setNotAnExpense(rows[0].id)

        XCTAssertEqual(s.transactions[0].kind, .transfer)
        XCTAssertEqual(s.transactions[0].category, "")
        XCTAssertEqual(s.transactions[0].resolution, .user)
        for i in 1...2 {
            XCTAssertEqual(s.transactions[i].kind, .expense, "sibling \(i) was never asked about")
            XCTAssertEqual(s.transactions[i].resolution, .pending)
        }
        XCTAssertTrue(s.rules.isEmpty, "a rule here types every future row of this merchant")
        XCTAssertEqual(pendingCount(s), 2)
    }

    /// The card's second acceptance line, pinned from this file so the two
    /// paths are compared side by side: the QUEUE still cascades and still
    /// teaches. The fix is a second entry point, not a behaviour change to the
    /// one the queue depends on.
    func testTheQueuePathStillCascadesAndStillTeaches() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1), pendingTx("Сервіс-Приклад", 2),
                    pendingTx("Сервіс-Приклад", 3)]
        let s = try store(rows)

        XCTAssertEqual(s.markNotAnExpense(rows[0].id), 3)
        XCTAssertTrue(s.transactions.allSatisfy { $0.kind == .transfer })
        XCTAssertEqual(s.rules.count, 1)
        XCTAssertEqual(s.rules[0].kind, .transfer)
    }

    /// A rule the user taught weeks ago is not contradicted by one detail
    /// edit. `markNotAnExpense` has a whole paragraph about what happens when
    /// it is; the detail path avoids the question by never touching `rules`.
    func testDetailLeavesAnExistingRuleExactlyAsItFoundIt() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1)]
        let s = try store(rows)
        s.rules = [Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"),
                        category: "Послуги", ambiguous: false)]

        s.setNotAnExpense(rows[0].id)

        XCTAssertEqual(s.rules.count, 1)
        XCTAssertEqual(s.rules[0].category, "Послуги")
        XCTAssertFalse(s.rules[0].ambiguous)
    }

    func testUndoingADetailTransferPutsTheRowBack() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1)]
        let s = try store(rows)
        s.setNotAnExpense(rows[0].id)

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.transactions[0].kind, .expense)
        XCTAssertEqual(s.transactions[0].resolution, .pending)
        XCTAssertEqual(pendingCount(s), 1)
    }

    /// It is the inverse of the repair below, and the pair has to round-trip:
    /// a person who marks a purchase a transfer by mistake and then gives it a
    /// category must end up exactly where they started.
    func testATransferMarkedInDetailCanBeGivenACategoryAgain() throws {
        let rows = [pendingTx("Сервіс-Приклад", 1, amount: -30_000)]
        let s = try store(rows)
        s.setNotAnExpense(rows[0].id)

        s.setCategory(rows[0].id, to: "Послуги")

        XCTAssertEqual(s.transactions[0].kind, .expense)
        XCTAssertEqual(s.transactions[0].category, "Послуги")
        XCTAssertEqual(Derived.totals(s.transactions).spent, 30_000)
    }

    // MARK: the repair path board #6 leaves the rows it did not migrate

    /// Rows answered under the old, wider «Це не витрата» — cash, jars, money
    /// sent to a person — keep the `.transfer` kind they were given; the app
    /// cannot tell which of them were own-card transfers, and guessing means
    /// rewriting months of confirmed history nobody asked it to touch. What it
    /// owes those rows instead is a repair that WORKS: give one a category in
    /// the detail screen and it is spending again.
    ///
    /// The failure this pins is silent, which is why it is pinned: without the
    /// retype the screen shows «Готівка», the row reads as answered, and
    /// `Derived` still throws every kopeck of it away.
    func testGivingATransferACategoryMakesItSpendingAgain() throws {
        var row = pendingTx("Банкомат-Приклад", 1, amount: -200_000)
        row.kind = .transfer
        row.resolution = .user
        let s = try store([row])

        s.setCategory(row.id, to: BudgetMath.cashCategory)

        XCTAssertEqual(s.transactions[0].kind, .expense)
        XCTAssertEqual(s.transactions[0].category, BudgetMath.cashCategory)
        XCTAssertEqual(Derived.totals(s.transactions).spent, 200_000,
                       "the whole point: the money is countable again")
    }

    /// The sign decides, not the picker: a transfer that brought money IN and
    /// is then given a spending category is money coming back, and Головна
    /// reads income off the sign. Typing it `.expense` would make a refund
    /// count as a purchase of the same size.
    func testAnIncomingTransferGivenACategoryBecomesIncomeNotAnExpense() throws {
        var row = pendingTx("Приклад-Повернення", 1, amount: 50_000)
        row.kind = .transfer
        let s = try store([row])

        s.setCategory(row.id, to: "Продукти")

        XCTAssertEqual(s.transactions[0].kind, .income)
        XCTAssertEqual(Derived.totals(s.transactions).spent, 0)
    }

    /// And the guard on the other side: `setCategory` is the ordinary way to
    /// correct any row, so it must not retype the ones that were never
    /// transfers. A salary re-categorised in detail stays income.
    func testCorrectingAnOrdinaryRowLeavesItsKindAlone() throws {
        var salary = pendingTx("Приклад-Дохід", 1, amount: 40_000_00)
        salary.kind = .income
        salary.category = "Зарплата"
        let s = try store([salary, pendingTx("Маркет-Приклад", 2)])

        s.setCategory(salary.id, to: "Інші надходження")
        s.setCategory(s.transactions[1].id, to: "Продукти")

        XCTAssertEqual(s.transactions[0].kind, .income)
        XCTAssertEqual(s.transactions[1].kind, .expense)
    }

    /// Undo puts the kind back with everything else — it is the same five
    /// seconds the queue's undo gives, and a correction that could not be
    /// taken back would be a worse trap than the one it repairs.
    func testUndoingTheRepairRestoresTheTransfer() throws {
        var row = pendingTx("Банкомат-Приклад", 1, amount: -200_000)
        row.kind = .transfer
        let s = try store([row])
        s.setCategory(row.id, to: BudgetMath.cashCategory)

        XCTAssertTrue(s.undoLast())
        XCTAssertEqual(s.transactions[0].kind, .transfer)
        XCTAssertEqual(Derived.totals(s.transactions).spent, 0)
    }

    // MARK: persistence

    func testConfirmSurvivesAReload() throws {
        let repo = MemoryRepository()
        let tx = pendingTx("Сервіс-Приклад")
        let s = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        s.transactions = [tx]
        s.rules = []
        s.confirm(tx.id, as: "Послуги")
        s.persistNow()

        let reloaded = AppStore(repository: repo, seed: try SeedLoader.load(), keychain: keychain)
        XCTAssertEqual(reloaded.transactions.first?.category, "Послуги")
        XCTAssertEqual(reloaded.rules.first?.category, "Послуги")
    }

    // MARK: not an expense

    func testMarkingNotAnExpenseTypesTheRowAsATransfer() throws {
        let s = try store([pendingTx("Переказ на свою картку", amount: -500_000)])
        let changed = s.markNotAnExpense(s.transactions[0].id)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(s.transactions[0].kind, .transfer)
        XCTAssertEqual(s.transactions[0].resolution, .user)
        XCTAssertEqual(s.transactions[0].category, "", "a transfer has no spending category")
    }

    /// The point of doing it by merchant: answered once, never asked again.
    func testItCascadesToEveryRowWithTheSameMerchant() throws {
        let s = try store([pendingTx("Маркет-Приклад", amount: -200_000),
                           pendingTx("маркет-приклад", 2, amount: -100_000),
                           pendingTx("Продавець", 3, amount: -34_000)])
        let changed = s.markNotAnExpense(s.transactions[0].id)
        XCTAssertEqual(changed, 2, "case-insensitively the same merchant")
        XCTAssertEqual(s.transactions.filter { $0.kind == .transfer }.count, 2)
        XCTAssertEqual(s.transactions[2].kind, .expense)
    }

    /// Review finding, `markNotAnExpense`'s half: the cascade predicate is
    /// identical to `confirm`'s, so it must draw the same kind boundary. A
    /// same-merchant income row must stay `.pending` and untouched — «Це не
    /// витрата» on the expense side is not a statement about the income side.
    func testMarkNotAnExpenseLeavesASameMerchantDifferentKindRowPending() throws {
        let expense = pendingTx("Маркет-Приклад", 1)
        var income = pendingTx("Маркет-Приклад", 2)
        income.kind = .income
        let s = try store([expense, income])

        XCTAssertEqual(s.markNotAnExpense(expense.id), 1,
                       "the cascade must not reach across kinds")
        let incomeRow = try XCTUnwrap(s.transactions.first { $0.id == income.id })
        XCTAssertEqual(incomeRow.resolution, .pending)
        XCTAssertEqual(incomeRow.kind, .income, "not silently retyped as a transfer")
    }

    /// Mirrors `testCascadeNeverTouchesAnAlreadyRuleResolvedRow`: an
    /// already-resolved row is not up for re-decision by a later «Це не
    /// витрата» any more than it is by a later category confirmation.
    func testMarkNotAnExpenseDoesNotTouchAnAlreadyRuleResolvedRow() throws {
        var settled = pendingTx("Маркет-Приклад", 1)
        settled.resolution = .rule
        settled.category = "Інше"
        let target = pendingTx("Маркет-Приклад", 2)
        let s = try store([settled, target])

        XCTAssertEqual(s.markNotAnExpense(target.id), 1)
        XCTAssertEqual(s.transactions[0].kind, .expense,
                       "an already-resolved row is not re-typed by a later cascade")
        XCTAssertEqual(s.transactions[0].category, "Інше")
        XCTAssertEqual(s.transactions[0].resolution, .rule)
    }

    /// Mirrors `testCascadeNeverOverwritesAnAnswerTheUserGaveThemselves`: an
    /// answer the user gave with their own hands is never overwritten by a
    /// sibling's cascade, category confirmation or «Це не витрата» alike.
    ///
    /// This is the review finding: `markNotAnExpense`'s cascade originally had
    /// no such guard and would silently flip a purchase the user had already
    /// confirmed by hand into a transfer, erasing its category.
    func testMarkNotAnExpenseNeverOverwritesAnAnswerTheUserGaveThemselves() throws {
        var answered = pendingTx("Маркет-Приклад", 1)
        answered.resolution = .user
        answered.category = "Інше"
        let target = pendingTx("Маркет-Приклад", 2)
        let s = try store([answered, target])

        XCTAssertEqual(s.markNotAnExpense(target.id), 1)
        XCTAssertEqual(s.transactions[0].kind, .expense)
        XCTAssertEqual(s.transactions[0].category, "Інше")
        XCTAssertEqual(s.transactions[0].resolution, .user)
    }

    /// `confirm` distinguishes the row in hand (`.user`) from cascaded
    /// siblings (`.rule`) — "the person answered about one purchase, and the
    /// rule answered for the rest." `markNotAnExpense` must draw the same
    /// distinction: a sibling swept up by the cascade was never looked at.
    func testMarkNotAnExpenseStampsTheTargetUserAndSiblingsRule() throws {
        let target = pendingTx("Маркет-Приклад", 1)
        let sibling = pendingTx("Маркет-Приклад", 2)
        let s = try store([target, sibling])

        XCTAssertEqual(s.markNotAnExpense(target.id), 2)
        XCTAssertEqual(s.transactions[0].resolution, .user, "the row the user tapped")
        XCTAssertEqual(s.transactions[1].resolution, .rule, "the cascaded sibling, not .user")
    }

    /// Closes the mutation-testing gap: every `pendingTx` fixture starts with
    /// an empty category, so a test built only on fresh `pendingTx` rows
    /// cannot tell whether `markNotAnExpense` actually clears `category` or
    /// merely leaves it at its already-empty starting value. Confirming a
    /// real category first, the way `testUndoRestoresTheKindAsWellAsTheCategory`
    /// does, makes the clear observable. `FeedView` renders
    /// `tx.category.isEmpty ? "Без категорії" : tx.category`, so a regression
    /// here would leave a stale category showing on a row already excluded
    /// from spending totals.
    func testMarkingNotAnExpenseClearsAnExistingCategory() throws {
        let s = try store([pendingTx("Переказ", amount: -500_000)])
        _ = s.confirm(s.transactions[0].id, as: "Продукти")
        XCTAssertEqual(s.transactions[0].category, "Продукти")

        _ = s.markNotAnExpense(s.transactions[0].id)
        XCTAssertEqual(s.transactions[0].category, "", "a transfer has no spending category")
    }

    /// The target row's clear (`AppStore+Queue.swift:269`) and the cascade's
    /// clear (`:278`) are two different lines, split apart when the cascade
    /// guard was added. `testMarkingNotAnExpenseClearsAnExistingCategory`
    /// above discriminates only the first — its fixture has no siblings. A
    /// fixture built only from fresh `pendingTx` siblings starts with
    /// `category: ""` already, so it cannot tell the cascade's clear from a
    /// no-op: the sibling here must be `.rule`-resolved with a real category
    /// and cascade-eligible (present in `pending`), the same requirement the
    /// cascade guard itself checks.
    func testTheCascadeAlsoClearsASiblingsExistingCategory() throws {
        let target = pendingTx("Маркет-Приклад", 1)
        // Still `.pending` (the cascade no longer reaches `.rule` rows) but
        // carrying a pre-filled category — the pipeline's guess, exactly as a
        // real `.pending` row ships it — so the cascade's own clear is what
        // is being observed here, not an already-empty starting value.
        var sibling = pendingTx("Маркет-Приклад", 2)
        sibling.category = "Інше"
        let s = try store([target, sibling])

        XCTAssertEqual(s.markNotAnExpense(target.id), 2)
        XCTAssertEqual(s.transactions[1].category, "",
                       "the cascade clears a sibling's category too, not only the tapped row's")
        XCTAssertEqual(s.transactions[1].kind, .transfer)
    }

    /// Extended, not merely renamed: Step 3b (`AppStore+Sync.applyingRule`)
    /// is what makes this test's name true. Before it, a stored `Rule` was
    /// read only to render a suggestion and for undo — nothing applied it to
    /// an incoming row, so the shape assertions below could pass while a
    /// future sync still asked about this merchant again. Now a fresh row
    /// from the same merchant, arriving through `ingest` exactly as a live
    /// sync would deliver it, is proved to inherit the rule.
    func testItStoresARuleSoAFuturePurchaseIsTypedToo() throws {
        let s = try store([pendingTx("Маркет-Приклад", amount: -200_000)])
        _ = s.markNotAnExpense(s.transactions[0].id)
        let rule = s.rules.first { $0.merchantKey == MerchantKey.normalize("Маркет-Приклад") }
        XCTAssertEqual(rule?.kind, .transfer)
        XCTAssertNil(rule?.category)
        XCTAssertEqual(rule?.ambiguous, false)

        // A future purchase from the same merchant, as a live sync would
        // hand it to `ingest`: a brand new row, `.pending`, no category.
        let future = pendingTx("Маркет-Приклад", 2, amount: -50_000)
        s.ingest([future], step: .forward(account: "a1", from: future.date, to: future.date), wasEmpty: false)

        let inherited = try XCTUnwrap(s.transactions.first { $0.id == future.id })
        XCTAssertEqual(inherited.kind, .transfer, "the rule typed it without being asked again")
        XCTAssertEqual(inherited.category, "")
        XCTAssertEqual(inherited.resolution, .rule)
    }

    /// `Derived` excludes `.transfer` from every spending figure, so this is
    /// the whole user-visible payoff.
    func testATransferLeavesTheSpendingTotal() throws {
        let s = try store([pendingTx("Переказ", amount: -500_000),
                           pendingTx("Продавець", 2, amount: -34_000)])
        let before = Derived.totals(s.transactions).spent
        _ = s.markNotAnExpense(s.transactions[0].id)
        XCTAssertEqual(before - Derived.totals(s.transactions).spent, 500_000)
    }

    /// `UndoEntry` restores only the fields its producer owns. Without `kind`
    /// in that set, undo leaves the row a transfer with its category restored —
    /// visible nowhere and wrong everywhere.
    func testUndoRestoresTheKindAsWellAsTheCategory() throws {
        let s = try store([pendingTx("Переказ", amount: -500_000)])
        _ = s.confirm(s.transactions[0].id, as: "Продукти")
        _ = s.markNotAnExpense(s.transactions[0].id)
        s.undoLast()
        XCTAssertEqual(s.transactions[0].kind, .expense)
        XCTAssertEqual(s.transactions[0].category, "Продукти")
    }

    // MARK: the rule table is the user's own work

    /// One mis-tap on «Це не витрата» used to destroy a rule the user taught
    /// weeks ago, unrecoverably.
    ///
    /// `markNotAnExpense` wrote a `scope: nil` transfer rule unconditionally,
    /// and `upsertRule` replaces by merchant key — so the taught category was
    /// gone, and `applyingRule` then stamped EVERY future row of that merchant
    /// `.transfer` with an empty category at ingest. Those rows never enter the
    /// queue and `Derived` excludes them from every spending figure, so the
    /// user's grocery spending quietly reads 0, in every month, forever, and
    /// the toast is gone within seconds. Board #11 made such a rule visible and
    /// repairable in Налаштування → Категорії → «Правила», so it is no longer
    /// unrecoverable — but nothing sends a person there to look for damage they
    /// were never told about, which is why the guard below still earns its
    /// place.
    ///
    /// Two contradictory answers about one merchant mean the same thing here as
    /// they do in `confirm`: stop guessing and ask.
    func testMarkNotAnExpenseDoesNotDestroyATaughtCategoryRule() throws {
        let taught = pendingTx("Крамниця-Приклад", 1, amount: -34_000)
        let s = try store([taught])
        s.confirm(taught.id, as: "Продукти")

        // Weeks later, working the queue quickly, the wrong button.
        let mistake = pendingTx("Крамниця-Приклад", 2, amount: -21_000)
        s.transactions.append(mistake)
        _ = s.markNotAnExpense(mistake.id)

        let key = MerchantKey.normalize("Крамниця-Приклад")
        let rule = try XCTUnwrap(s.rules.first { $0.merchantKey == key })
        XCTAssertTrue(rule.ambiguous, "a contradicted merchant asks; it never auto-types")
        XCTAssertNotEqual(rule.kind, .transfer,
                          "one mis-tap must not convert a taught category rule into a transfer rule")

        // What the user would actually see: the next purchase from that shop,
        // arriving through `ingest` exactly as a live sync delivers it.
        let future = pendingTx("Крамниця-Приклад", 3, amount: -18_000)
        s.ingest([future], step: .forward(account: "a1", from: future.date, to: future.date),
                 wasEmpty: false)
        let arrived = try XCTUnwrap(s.transactions.first { $0.id == future.id })
        XCTAssertEqual(arrived.kind, .expense, "a shop is not a transfer because of one mis-tap")
        XCTAssertEqual(arrived.resolution, .pending, "it must come back and ask")
    }

    /// The uncontradicted path is deliberately unchanged: a merchant the app
    /// knows nothing else about still gets the broad `scope: nil` transfer
    /// rule, because a merchant that moves money between the owner's own
    /// accounts does it in both directions.
    func testMarkNotAnExpenseOnAnUnknownMerchantStillWritesTheBroadTransferRule() throws {
        let s = try store([pendingTx("Маркет-Приклад", amount: -200_000)])
        _ = s.markNotAnExpense(s.transactions[0].id)
        let rule = try XCTUnwrap(
            s.rules.first { $0.merchantKey == MerchantKey.normalize("Маркет-Приклад") })
        XCTAssertEqual(rule.kind, .transfer)
        XCTAssertFalse(rule.ambiguous)
        XCTAssertNil(rule.scope, "a transfer determination is not kind-specific")
    }

    /// A refund is income from a shop the user already taught, and answering
    /// it consistently used to make the app FORGET what it knew.
    ///
    /// Rule: {Маркет-Приклад, «Техніка», scope: .expense}. A refund arrives —
    /// positive amount, so `.income` — and `applyingRule`'s scope guard
    /// correctly declines, leaving it `.pending`. The user confirms that income
    /// group as «Техніка», the same answer as before. `contradicts` is false,
    /// so `confirm` replaced the rule with `scope: .income`, and every future
    /// Маркет-Приклад EXPENSE then failed the scope guard and went back in the
    /// queue.
    ///
    /// One answer that holds for both kinds is a rule for both kinds.
    func testConfirmingTheSameCategoryOnTheOtherKindBroadensTheRuleRatherThanMovingIt() throws {
        let expense = pendingTx("Маркет-Приклад", 1, amount: -120_000)
        let s = try store([expense])
        s.confirm(expense.id, as: "Техніка")

        var refund = pendingTx("Маркет-Приклад", 2, amount: 120_000)
        refund.kind = .income
        s.transactions.append(refund)
        s.confirm(refund.id, as: "Техніка")

        let key = MerchantKey.normalize("Маркет-Приклад")
        let rule = try XCTUnwrap(s.rules.first { $0.merchantKey == key })
        XCTAssertEqual(rule.category, "Техніка")
        XCTAssertFalse(rule.ambiguous, "the same answer twice is consistency, not ambiguity")
        XCTAssertNil(rule.scope, "an answer given for both kinds must apply to both kinds")

        // The payoff: a future expense still answers itself.
        let future = pendingTx("Маркет-Приклад", 3, amount: -50_000)
        s.ingest([future], step: .forward(account: "a1", from: future.date, to: future.date),
                 wasEmpty: false)
        let arrived = try XCTUnwrap(s.transactions.first { $0.id == future.id })
        XCTAssertEqual(arrived.category, "Техніка", "the app must not forget what it was taught")
        XCTAssertEqual(arrived.resolution, .rule)
    }

    /// The other half of the same branch, and **board #81 reverses it.**
    ///
    /// A different category on the other kind used to read as the person
    /// contradicting themselves, so both answers were thrown away and the
    /// merchant asked forever. It is not a contradiction: a marketplace that
    /// charges for goods and pays out refunds, an employer who also sells, a
    /// person who is both client and supplier — the two answers are about two
    /// different kinds of row and both are right.
    ///
    /// Two rules now, and each answers for its own kind.
    func testADifferentCategoryOnEachKindIsTwoRulesRatherThanAContradiction() throws {
        let expense = pendingTx("Маркет-Приклад", 1, amount: -120_000)
        let s = try store([expense])
        s.confirm(expense.id, as: "Техніка")

        var income = pendingTx("Маркет-Приклад", 2, amount: 120_000)
        income.kind = .income
        s.transactions.append(income)
        s.confirm(income.id, as: "Зарплата")

        let key = MerchantKey.normalize("Маркет-Приклад")
        let mine = s.rules.filter { $0.merchantKey == key }
        XCTAssertEqual(mine.count, 2, "one merchant, two kinds, two answers")
        XCTAssertFalse(mine.contains { $0.ambiguous },
                       "answering about two different kinds is not self-contradiction")

        let forSpending = try XCTUnwrap(s.rules.governing(key, kind: .expense))
        XCTAssertEqual(forSpending.category, "Техніка")
        XCTAssertEqual(forSpending.scope, .expense)

        let forIncome = try XCTUnwrap(s.rules.governing(key, kind: .income))
        XCTAssertEqual(forIncome.category, "Зарплата")
        XCTAssertEqual(forIncome.scope, .income)
    }

    /// The payoff, and the actual defect #81 names: the EARLIER answer must
    /// still be applied after the later one is taught.
    ///
    /// Before this card, teaching the income answer destroyed the expense rule
    /// — both became "ask every time" — so a merchant the app had been
    /// handling perfectly went back into the queue for good, and the only
    /// visible symptom was rows appearing there again.
    func testTeachingTheOtherKindDoesNotStopTheFirstRuleWorking() throws {
        let expense = pendingTx("Маркет-Приклад", 1, amount: -120_000)
        let s = try store([expense])
        s.confirm(expense.id, as: "Техніка")

        var income = pendingTx("Маркет-Приклад", 2, amount: 120_000)
        income.kind = .income
        s.transactions.append(income)
        s.confirm(income.id, as: "Зарплата")

        let future = pendingTx("Маркет-Приклад", 3, amount: -50_000)
        s.ingest([future], step: .forward(account: "a1", from: future.date, to: future.date),
                 wasEmpty: false)
        let arrived = try XCTUnwrap(s.transactions.first { $0.id == future.id })
        XCTAssertEqual(arrived.category, "Техніка",
                       "the expense rule survived being joined by an income one")
        XCTAssertEqual(arrived.resolution, .rule)

        var refund = pendingTx("Маркет-Приклад", 4, amount: 70_000)
        refund.kind = .income
        s.ingest([refund], step: .forward(account: "a1", from: refund.date, to: refund.date),
                 wasEmpty: false)
        let paid = try XCTUnwrap(s.transactions.first { $0.id == refund.id })
        XCTAssertEqual(paid.category, "Зарплата", "and the income rule answers for income")
    }

    /// Answering the SAME kind differently is still a contradiction, and still
    /// makes that kind ask — the half of the old behaviour that was right.
    ///
    /// The marker lands on the contradicted rule's own scope. Written unscoped
    /// it would sit beside the scoped rule it was meant to overrule, where
    /// `governing` prefers the more specific one, and the merchant would carry
    /// on auto-typing as though nothing had been said.
    func testTwoAnswersForTheSameKindStillMakeThatKindAsk() throws {
        let first = pendingTx("Маркет-Приклад", 1, amount: -120_000)
        let s = try store([first])
        s.confirm(first.id, as: "Техніка")

        let second = pendingTx("Маркет-Приклад", 2, amount: -30_000)
        s.transactions.append(second)
        s.confirm(second.id, as: "Продукти")

        let key = MerchantKey.normalize("Маркет-Приклад")
        let rule = try XCTUnwrap(s.rules.governing(key, kind: .expense))
        XCTAssertTrue(rule.ambiguous, "two answers for one kind mean ask")
        XCTAssertNil(rule.category, "an ambiguous merchant has no answer to apply")

        let future = pendingTx("Маркет-Приклад", 3, amount: -50_000)
        s.ingest([future], step: .forward(account: "a1", from: future.date, to: future.date),
                 wasEmpty: false)
        let arrived = try XCTUnwrap(s.transactions.first { $0.id == future.id })
        XCTAssertEqual(arrived.resolution, .pending, "it must come back and ask")
    }

    func testAnOlderRuleFileWithoutKindStillDecodes() throws {
        let json = #"[{"merchantKey":"атб","category":"Продукти","ambiguous":false}]"#
        let rules = try SeedLoader.decoder.decode([Rule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertNil(rules[0].kind)
    }
}
