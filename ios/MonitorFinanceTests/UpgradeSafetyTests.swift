import XCTest
@testable import MonitorFinance

/// **An app update must not lose the user's data.** Board #65.
///
/// The repo already follows the rule — every persisted field added after the
/// first build is Optional, because Swift's synthesised `Decodable` throws
/// `keyNotFound` rather than using a memberwise default — and each instance is
/// defended in a comment where it was written. What was missing is proof: the
/// rule was a habit, honoured by whoever remembered it.
///
/// **The failure mode is why this matters.** Every load in `AppStore.init` is
/// `try?` with a fallback to the seed or to an empty value. So a single
/// non-Optional field added to `Transaction` does not surface as an error — it
/// makes the whole `transactions.json` undecodable, and the app opens as if the
/// person were new. Silently. On their next launch after updating.
///
/// Each fixture below is an OLDEST-SHAPE file: only the fields that are not
/// Optional today, written by hand rather than round-tripped, so a reader can
/// see exactly what an older build wrote. Adding a non-Optional field to any
/// of these types fails a test here instead of an install out there.
final class UpgradeSafetyTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try SeedLoader.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: one type at a time

    func testATransactionWithNoneOfTheLaterFieldsDecodes() throws {
        let tx = try decode(Transaction.self, """
        {"id":"5D1B9E6E-0000-4000-8000-000000000001",
         "date":"2026-08-01T12:00:00Z","kind":"expense","category":"Продукти",
         "merchant":"Гастроном-Приклад","amount":-12300,"cardSuffix":"*0000",
         "bankId":"monobank","splits":[],"resolution":"rule","suggestions":[]}
        """)
        XCTAssertNil(tx.receiptId)
        XCTAssertNil(tx.externalId, "the field the seed sweep keys on")
        XCTAssertNil(tx.hold)
        XCTAssertNil(tx.mcc)
        XCTAssertNil(tx.originalMcc, "board #56's field, added after `mcc`")
        XCTAssertNil(tx.balanceAfterMinor,
                     "the cross-source matcher's field, added after `originalMcc`")
    }

    /// Board #26 kept this case for exactly this reason: it is a stored raw
    /// value, and deleting it would throw here — taking the whole file.
    func testATransactionResolutionWithNoWriterLeftStillDecodes() throws {
        let tx = try decode(Transaction.self, """
        {"id":"5D1B9E6E-0000-4000-8000-000000000002",
         "date":"2026-08-01T12:00:00Z","kind":"expense","category":"",
         "merchant":"Гастроном-Приклад","amount":-1,"cardSuffix":"*0000",
         "bankId":"monobank","splits":[],"resolution":"skipped","suggestions":[]}
        """)
        XCTAssertEqual(tx.resolution, .skipped)
    }

    func testABankAndItsAccountsDecodeWithoutTheLaterFields() throws {
        let bank = try decode(Bank.self, """
        {"id":"monobank","displayName":"monobank","status":"available","connected":true,
         "accounts":[{"id":"a1","suffix":"*1111","type":"black","currency":"UAH","balance":1}]}
        """)
        XCTAssertNil(bank.accounts[0].creditLimit)
        XCTAssertNil(bank.accounts[0].syncEnabled,
                     "nil must keep meaning «enabled» — the behaviour those devices already have")
    }

    /// `BankStatus` goes further than the others on purpose: it decodes an
    /// UNKNOWN raw value as the inert case, so a `banks.json` written by a
    /// FUTURE build does not reset this one's banks to the seed.
    func testAnUnknownBankStatusFromALaterBuildDecodesAsInert() throws {
        let bank = try decode(Bank.self, """
        {"id":"someBankNotInventedYet","displayName":"…","status":"openBanking",
         "connected":false,"accounts":[]}
        """)
        XCTAssertEqual(bank.status, .comingSoon)
    }

    func testACategoryAndARuleDecodeWithoutTheLaterFields() throws {
        let category = try decode(MonitorFinance.Category.self, #"{"name":"Продукти"}"#)
        XCTAssertNil(category.tintIndex)
        XCTAssertNil(category.icon, "board #61's field")
        // …and nil is still something to draw. A category on a phone today has
        // neither field, and «no icon» must not mean «blank swatch».
        XCTAssertEqual(category.iconName, CategoryIcon.fallback)

        // Board #94. Before the field, what counted as income WAS the name —
        // so a category written by an older build has no other truth to
        // recover, and resolving it any other way would re-base the budget of
        // every device already out there on the day it upgrades.
        XCTAssertNil(category.kind, "board #94's field")
        XCTAssertEqual(category.resolvedKind, .spending)
        let salary = try decode(MonitorFinance.Category.self, #"{"name":"Зарплата"}"#)
        XCTAssertEqual(salary.resolvedKind, .earned)
        let gift = try decode(MonitorFinance.Category.self, #"{"name":"Подарунки"}"#)
        XCTAssertEqual(gift.resolvedKind, .unearned,
                       "a gift is money in that no plan is built on")

        let rule = try decode(Rule.self, #"{"merchantKey":"гастроном-приклад","ambiguous":false}"#)
        XCTAssertNil(rule.category)
        XCTAssertNil(rule.kind, "a transfer rule's marker")
        XCTAssertNil(rule.scope)
    }

    func testAReceiptDecodesWithoutTheLaterFields() throws {
        let receipt = try decode(Receipt.self, """
        {"id":"5D1B9E6E-0000-4000-8000-000000000003","scannedAt":"2026-08-01T12:00:00Z",
         "registerNumber":"3000000001","documentNumber":"7",
         "fiscalTime":"2026-08-01T11:59:00Z","fiscalSum":12300,
         "sellerName":"Продавець-Приклад","items":[]}
        """)
        XCTAssertNil(receipt.registerModel)
        XCTAssertNil(receipt.itemsLandedAt)
        XCTAssertTrue(receipt.isWaitingForItems,
                      "an absent stamp must mean «the goods have not arrived», not «no lines»")
    }

    func testAPendingReceiptDecodesWithoutTheLaterFields() throws {
        let pending = try decode(PendingReceipt.self, """
        {"receiptId":"5D1B9E6E-0000-4000-8000-000000000004",
         "check":{"registerNumber":"3000000001","documentNumber":"7",
                  "fiscalTime":"2026-08-01T11:59:00Z","fiscalSum":12300},
         "scannedAt":"2026-08-01T12:00:00Z","attempts":0,
         "nextAttempt":"2026-08-01T12:01:00Z"}
        """)
        XCTAssertNil(pending.check.mac)
        XCTAssertNil(pending.lastError)
    }

    func testSettingsDecodeWithoutTheLaterFields() throws {
        let settings = try decode(Settings.self, #"{"onboarded":true,"faceIdEnabled":false}"#)
        XCTAssertNil(settings.startedUsingAt)
        XCTAssertFalse(settings.locksImmediately, "board #21's default survives an old file")
        XCTAssertNil(settings.appearance)
        XCTAssertEqual(settings.appearanceChoice, .system,
                       "board #58: an old file must keep following the system")
    }

    /// `Appearance` is a PERSISTED raw value, so a fourth case added by a
    /// later build would otherwise throw here — and `settings.json` is loaded
    /// with a fallback to a blank `Settings()`, which means onboarding again.
    /// Same protection `BankStatus` carries, tested the same way.
    func testAnAppearanceFromALaterBuildDecodesAsFollowingTheSystem() throws {
        let settings = try decode(Settings.self, """
        {"onboarded":true,"faceIdEnabled":false,"appearance":"solarizedDusk"}
        """)
        XCTAssertEqual(settings.appearanceChoice, .system)
        XCTAssertTrue(settings.onboarded, "the rest of the file must survive it")
    }

    /// The one real migration this repo has: `percent` widened from `Int` to
    /// `Double`, and a plan written as an integer must still decode.
    func testABudgetWrittenWithIntegerPercentsDecodes() throws {
        let budget = try decode(Budget.self, """
        {"incomeBase":{"average":{"months":3,"includeGifts":false}},
         "lines":[{"id":"5D1B9E6E-0000-4000-8000-000000000005",
                   "category":"Продукти","percent":30}]}
        """)
        XCTAssertEqual(budget.lines.first?.percent, 30)
        XCTAssertNil(budget.month, "board #62's field, added after the plan shipped")
    }

    /// `budgetHistory.json` arrived with board #62 and has no oldest shape on
    /// anybody's device — it simply does not exist there. The fixture is
    /// therefore the FIRST shape, and what it pins is that a stored plan with
    /// no month still decodes inside the array: `plan(for:)` reads a nil month
    /// as "always in force", and a throw here would take the whole history.
    func testAStoredHistoryDecodesEvenWhereAPlanCarriesNoMonth() throws {
        let history = try decode([Budget].self, """
        [{"incomeBase":{"average":{"months":3,"includeGifts":false}},
          "lines":[{"id":"5D1B9E6E-0000-4000-8000-000000000006",
                    "category":"Продукти","percent":30}]}]
        """)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].month)
    }

    /// `statementImports.json` arrived with board #148 and exists on nobody's
    /// device, so its fixture is the FIRST shape rather than an older one.
    ///
    /// What it pins is the field that will be tempting to add next: this list
    /// is the only place the ids of a statement's rows are kept, and the undo
    /// is built on them. A new non-Optional field would make every stored
    /// record fail to decode, and `AppStore.init` falls back to an empty array
    /// — so the whole list would vanish, silently, and every import become
    /// impossible to undo. `from`/`to` are already Optional for that reason.
    func testAStoredStatementImportDecodesAtItsFirstShape() throws {
        let records = try decode([StatementImport].self, """
        [{"id":"5D1B9E6E-0000-4000-8000-000000000148",
          "filename":"виписка-приклад.xlsx",
          "importedAt":"2026-08-27T09:00:00Z",
          "created":["5D1B9E6E-0000-4000-8000-000000000149"],
          "merged":2}]
        """)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].created.count, 1, "the undo lives on these ids")
        XCTAssertNil(records[0].from, "a record written before a period was carried")
        XCTAssertNil(records[0].to)
    }

    /// Board #184's file, at the shape this build writes it.
    ///
    /// Small stakes compared to its neighbours — a lost group is a name the
    /// person retypes, not an import that can never be undone — but the same
    /// property: a non-Optional field added to `ProductGroup` later would make
    /// every stored group undecodable, and the picker would quietly go back to
    /// offering only the seed with no sign that anything had been dropped.
    func testAStoredProductGroupDecodesAtItsFirstShape() throws {
        let groups = try decode([ProductGroup].self,
                                #"[{"name":"Солодка вода","keywords":["coca-cola"]}]"#)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Солодка вода")
        XCTAssertEqual(groups[0].keywords, ["coca-cola"],
                       "the keyword is what makes the group reachable by the guesser")
    }

    /// …and the same shape through the file the store actually reads, because
    /// the type decoding is only half of it: `AppStore.init` falls back to the
    /// seed WHOLE-FILE, so a `productGroups` that fails to decode does not lose
    /// one group — it silently loses every group the person ever made, and the
    /// picker looks exactly as it does on a fresh install.
    ///
    /// This is the fixture `test_every_persisted_file_has_an_oldest_shape_fixture`
    /// requires, and it is keyed by the file name for that reason.
    @MainActor
    func testAStoredProductGroupFileLoadsIntoTheStore() throws {
        let repo = MemoryRepository()
        repo.files["productGroups"] =
            Data(#"[{"name":"Солодка вода","keywords":["coca-cola"]}]"#.utf8)

        var seed = try SeedLoader.load()
        seed.transactions = []
        let store = AppStore(repository: repo, seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))

        XCTAssertEqual(store.customProductGroups.map(\.name), ["Солодка вода"])
        XCTAssertEqual(store.productGroups.count, 22, "the seed plus the person's own")
        XCTAssertEqual(store.productGroups.last?.name, ProductGuess.other,
                       "«Інше» is still last on the way in from disk")
        XCTAssertEqual(ProductGuess.group(for: "Coca-Cola 1 л", in: store.productGroups),
                       "Солодка вода", "…and the stored keyword still reaches the guesser")
    }

    /// `SyncState` is hand-decoded rather than synthesised, so an EMPTY object
    /// is a valid oldest shape — which is the strongest form of this property
    /// and the one every other type here should be measured against.
    func testAnEmptySyncStateDecodesToItsDefaults() throws {
        let state = try decode(SyncState.self, "{}")
        XCTAssertEqual(state.depthMonths, 3)
        XCTAssertFalse(state.seedCleared)
        XCTAssertTrue(state.cursors.isEmpty)
        XCTAssertNil(state.clientHash)
    }

    /// Task 4's fields, added to `SyncState` after monobank-only sync
    /// shipped — a file written before them must still decode.
    func testASyncStateWithoutEmailFieldsDecodes() throws {
        let old = #"{"cursors":{},"depthMonths":3,"needsReconnect":false,"seedCleared":true}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(old.utf8))
        XCTAssertEqual(state.emailCursor, 0)
        XCTAssertFalse(state.emailNeedsReconnect)
    }

    func testEmailFieldsRoundTrip() throws {
        var state = SyncState()
        state.emailCursor = 42
        state.emailNeedsReconnect = true
        let back = try JSONDecoder().decode(SyncState.self,
                                            from: JSONEncoder().encode(state))
        XCTAssertEqual(back.emailCursor, 42)
        XCTAssertTrue(back.emailNeedsReconnect)
    }

    // MARK: and the whole store, on files of that vintage

    /// The end-to-end form, because the per-type tests above cannot see the
    /// thing that actually hurts: `AppStore.init` loads each file with `try?`
    /// and falls back to the SEED. A type that stopped decoding would not
    /// throw here — the app would simply open as if the person were new, and
    /// every assertion below is written to fail loudly in that case.
    func testAStoreBuiltOnOldestShapeFilesKeepsThePersonsData() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = Data("""
        [{"id":"5D1B9E6E-0000-4000-8000-000000000010",
          "date":"2026-08-01T12:00:00Z","kind":"expense","category":"Продукти",
          "merchant":"Гастроном-Приклад","amount":-12300,"cardSuffix":"*0000",
          "bankId":"monobank","splits":[],"resolution":"user","suggestions":[]}]
        """.utf8)
        repo.files["categories"] = Data(#"[{"name":"Продукти"},{"name":"Транспорт"}]"#.utf8)
        repo.files["rules"] = Data(#"[{"merchantKey":"гастроном-приклад","ambiguous":false}]"#.utf8)
        repo.files["settings"] = Data(#"{"onboarded":true,"faceIdEnabled":false}"#.utf8)
        repo.files["sync"] = Data("{}".utf8)
        repo.files["banks"] = Data("""
        [{"id":"monobank","displayName":"monobank","status":"available","connected":true,
          "accounts":[{"id":"a1","suffix":"*1111","type":"black","currency":"UAH","balance":1}]}]
        """.utf8)
        repo.files["receipts"] = Data("""
        [{"id":"5D1B9E6E-0000-4000-8000-000000000011","scannedAt":"2026-08-01T12:00:00Z",
          "registerNumber":"3000000001","documentNumber":"7",
          "fiscalTime":"2026-08-01T11:59:00Z","fiscalSum":12300,
          "sellerName":"Продавець-Приклад","items":[]}]
        """.utf8)
        repo.files["receiptQueue"] = Data("""
        [{"receiptId":"5D1B9E6E-0000-4000-8000-000000000012",
          "check":{"registerNumber":"3000000001","documentNumber":"8",
                   "fiscalTime":"2026-08-01T11:59:00Z","fiscalSum":9900},
          "scannedAt":"2026-08-01T12:00:00Z","attempts":0,
          "nextAttempt":"2026-08-01T12:01:00Z"}]
        """.utf8)
        repo.files["budget"] = Data("""
        {"incomeBase":{"average":{"months":3,"includeGifts":false}},
         "lines":[{"id":"5D1B9E6E-0000-4000-8000-000000000013",
                   "category":"Продукти","percent":30}]}
        """.utf8)
        // Board #62's file. Not an OLDEST shape — it did not exist before #62
        // — but it is loaded like every other, so a non-Optional field added
        // to `Budget` would take the person's earlier plans with it, and those
        // are what their past months are measured against.
        repo.files["budgetHistory"] = Data("""
        [{"incomeBase":{"fixed":{"_0":4900000}},
          "lines":[{"id":"5D1B9E6E-0000-4000-8000-000000000014",
                    "category":"Транспорт","percent":20}],
          "month":{"year":2026,"month":7}}]
        """.utf8)
        // Board #148's file, and the stakes are its own: this list holds the
        // only record of which rows each statement created, so a non-Optional
        // field added to `StatementImport` would not merely lose a list — it
        // would make every past import permanently impossible to undo, with
        // nothing on screen saying so.
        repo.files["statementImports"] = Data("""
        [{"id":"5D1B9E6E-0000-4000-8000-000000000148",
          "filename":"виписка-приклад.xlsx",
          "importedAt":"2026-08-27T09:00:00Z",
          "created":["5D1B9E6E-0000-4000-8000-000000000010"],
          "merged":2}]
        """.utf8)

        // Board #184's file is deliberately NOT written here: this fixture is
        // a phone that predates it, and the assertion below is that such a
        // phone gets the shipped taxonomy rather than an empty picker.
        var seed = try SeedLoader.load()
        seed.transactions = []
        let store = AppStore(repository: repo, seed: seed,
                             keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))

        XCTAssertEqual(store.customProductGroups, [],
                       "a phone that predates custom groups has invented none")
        XCTAssertEqual(store.productGroups.count, 21,
                       "…and still gets every seeded group, from the bundle rather than the file")

        XCTAssertEqual(store.transactions.count, 1,
                       "an undecodable transactions.json opens the app as if the person were new")
        XCTAssertEqual(store.transactions.first?.merchant, "Гастроном-Приклад")
        XCTAssertEqual(store.categories.map(\.name), ["Продукти", "Транспорт"],
                       "…and would quietly restore the nineteen seeded categories over theirs")
        XCTAssertEqual(store.rules.count, 1, "…and forget every rule they taught")
        XCTAssertTrue(store.settings.onboarded, "…and send them back through onboarding")
        XCTAssertEqual(store.syncState.depthMonths, 3)
        XCTAssertEqual(store.banks.first(where: { $0.id == "monobank" })?.accounts.count, 1,
                       "…and forget which cards they had connected")
        XCTAssertEqual(store.receipts.count, 1, "…and lose every receipt they scanned")
        XCTAssertEqual(store.receiptQueue.count, 1, "…and abandon a scan still being fetched")
        XCTAssertEqual(store.budget?.lines.count, 1, "…and throw away their plan")
        XCTAssertEqual(store.statementImports.count, 1,
                       "…and lose the record of which rows each statement brought")
        XCTAssertEqual(store.statementImports.first?.created.count, 1,
                       "…which is what makes an import undoable at all")
        XCTAssertEqual(store.budgetHistory.count, 1,
                       "…and measure every past month against the wrong plan")
        XCTAssertEqual(store.plan(for: MonthKey(year: 2026, month: 7))?.lines.first?.category,
                       "Транспорт", "the July plan is the one July had")
    }
}
