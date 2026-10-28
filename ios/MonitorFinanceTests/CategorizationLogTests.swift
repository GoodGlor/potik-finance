import XCTest
@testable import MonitorFinance

/// The Debug-only training-data tap: what it records, what it refuses to
/// record, and that it does nothing at all until a person turns it on.
@MainActor
final class CategorizationLogTests: XCTestCase {
    private var keychain: Keychain!
    private var defaults: UserDefaults!
    private var suiteName: String!

    /// Its own defaults suite per test: the flag is a real `UserDefaults`
    /// key, and a test that flipped the shared one would leak into the next.
    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        suiteName = "ua.monitorfinance.tests.log.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        keychain.wipe()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: doubles

    private final class MemoryStore: CategorizationLogStore {
        var data = Data()
        var failAppend = false
        func append(_ line: Data) throws {
            if failAppend { throw CocoaError(.fileWriteUnknown) }
            data += line
        }
        func contents() throws -> Data { data }
        func clear() throws { data = Data() }
        func size() throws -> Int { data.count }
    }

    /// Records what it was asked to send.
    ///
    /// Locked, and the lock is not decoration: the log fires one unstructured
    /// `Task` per line so no tap ever waits on a network, which means a
    /// cascade's sends run concurrently and off the main actor. An
    /// unsynchronized array here lost one of two lines and read as a missing
    /// event rather than as the test's own bug.
    private final class SpySender: CategorizationEventSender, @unchecked Sendable {
        let answer: Bool
        private let lock = NSLock()
        private var recorded: [Data] = []
        var lines: [Data] { lock.withLock { recorded } }
        init(answer: Bool = true) { self.answer = answer }
        func send(_ line: Data, to url: URL) async -> Bool {
            lock.withLock { recorded.append(line) }
            return answer
        }
    }

    private func makeLog(_ store: MemoryStore, products: MemoryStore = MemoryStore(),
                         sender: CategorizationEventSender = SpySender(),
                         enabled: Bool = true) -> CategorizationLog {
        let log = CategorizationLog(store: store, productStore: products,
                                    sender: sender, defaults: defaults)
        log.isEnabled = enabled
        return log
    }

    private func makeStore(_ txs: [Transaction], log: CategorizationLog) throws -> AppStore {
        let s = AppStore(repository: MemoryRepository(), seed: try SeedLoader.load(),
                         keychain: keychain)
        s.transactions = txs
        s.rules = []
        s.categorizationLog = log
        return s
    }

    private func tx(_ merchant: String, day: Int = 1, amount: Int = -10_000,
                    mcc: Int? = 5411, originalMcc: Int? = nil, bankId: String = "monobank",
                    suggestions: [String] = [], resolution: Resolution = .pending) -> Transaction {
        Transaction(id: UUID(),
                    date: Calendar.kyiv.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!,
                    kind: amount < 0 ? .expense : .income, category: "", merchant: merchant,
                    amount: amount, cardSuffix: "*0000", bankId: bankId, receiptId: nil,
                    splits: [], resolution: resolution, suggestions: suggestions,
                    mcc: mcc, originalMcc: originalMcc)
    }

    private func events(_ store: MemoryStore) throws -> [CategorizationEvent] {
        try String(decoding: store.data, as: UTF8.self)
            .split(separator: "\n")
            .map { try SeedLoader.decoder.decode(CategorizationEvent.self, from: Data($0.utf8)) }
    }

    private func products(_ store: MemoryStore) throws -> [ProductGroupEvent] {
        try String(decoding: store.data, as: UTF8.self)
            .split(separator: "\n")
            .map { try SeedLoader.decoder.decode(ProductGroupEvent.self, from: Data($0.utf8)) }
    }

    /// A receipt with one line, attached to nothing. `setItemGroup` needs only
    /// the receipt, so no transaction is involved.
    private func receipt(_ item: String, seller: String = "Крамниця Приклад") -> Receipt {
        Receipt(id: UUID(), scannedAt: Date(), registerNumber: "1", documentNumber: "2",
                fiscalTime: Date(), fiscalSum: 3200, sellerName: seller,
                items: [Receipt.Item(id: UUID(), name: item, qty: 1, price: 3200, sum: 3200,
                                     category: nil)])
    }

    // MARK: the switch

    /// The guardrail that matters most. Everything below assumes the log is
    /// on; this is the test that says what happens when it is not, which is
    /// the state every build ships in.
    func testNothingIsRecordedUntilSomebodyTurnsItOn() throws {
        let file = MemoryStore()
        let sender = SpySender()
        let log = makeLog(file, sender: sender, enabled: false)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)

        s.confirm(row.id, as: "Продукти")

        XCTAssertTrue(file.data.isEmpty, "an opt-in that records anything is not an opt-in")
        XCTAssertTrue(sender.lines.isEmpty)
        XCTAssertEqual(log.lineCount(), 0)
    }

    func testTheSwitchAndTheWebhookSurviveInDefaults() {
        let log = makeLog(MemoryStore(), enabled: false)
        XCTAssertFalse(log.isEnabled)
        log.isEnabled = true
        log.webhook = "  https://example.test/exec  "
        let reopened = CategorizationLog(store: MemoryStore(), sender: SpySender(),
                                         defaults: defaults)
        XCTAssertTrue(reopened.isEnabled)
        XCTAssertEqual(reopened.webhook, "https://example.test/exec", "trimmed on the way in")
    }

    // MARK: the five sources

    func testAQueueConfirmIsRecordedWithTheRowAsItArrived() throws {
        let file = MemoryStore()
        let row = tx("Маркет-Приклад", mcc: 5411, bankId: "monobank")
        let s = try makeStore([row], log: makeLog(file))

        s.confirm(row.id, as: "Продукти")

        let logged = try events(file)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged[0].source, .queueConfirm)
        XCTAssertEqual(logged[0].choice, "category")
        XCTAssertEqual(logged[0].category, "Продукти")
        XCTAssertEqual(logged[0].merchant, "Маркет-Приклад")
        XCTAssertEqual(logged[0].merchantKey, MerchantKey.normalize("Маркет-Приклад"))
        XCTAssertEqual(logged[0].mcc, 5411)
        XCTAssertEqual(logged[0].sign, "out")
        XCTAssertEqual(logged[0].bankId, "monobank")
        XCTAssertEqual(logged[0].was, "pending", "what it was before the answer, not after")
        XCTAssertEqual(logged[0].kind, "expense")
    }

    /// The cascade is a different kind of example: nobody looked at those
    /// rows. Labelling them `queueConfirm` would teach a categorizer that a
    /// human confirmed twelve rows of one shop when they confirmed a single card.
    func testTheCascadedRowsAreLabelledCascadeAndTheTappedOneIsNot() throws {
        let file = MemoryStore()
        let first = tx("Маркет-Приклад", day: 1)
        let second = tx("Маркет-Приклад", day: 2)
        let third = tx("Маркет-Приклад", day: 3)
        let s = try makeStore([first, second, third], log: makeLog(file))

        s.confirm(first.id, as: "Продукти")

        let logged = try events(file)
        XCTAssertEqual(logged.count, 3)
        XCTAssertEqual(logged[0].source, .queueConfirm)
        XCTAssertEqual(logged.dropFirst().map(\.source), [.cascade, .cascade])
        XCTAssertEqual(Set(logged.map(\.category)), ["Продукти"])
    }

    func testTheSuggestionChipNamesItself() throws {
        let file = MemoryStore()
        let row = tx("Крамниця Хвіст", bankId: PrivatMapper.bankId, suggestions: ["Тварини"])
        let s = try makeStore([row], log: makeLog(file))
        let group = try XCTUnwrap(s.pendingGroups.first)

        s.acceptSuggestion(group)

        let logged = try events(file)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged[0].source, .suggestionChip)
        XCTAssertEqual(logged[0].category, "Тварини")
        XCTAssertEqual(logged[0].bankSuggestion, "Тварини",
                       "what the bank proposed is half the example")
    }

    /// A monobank row's `suggestions` array is legacy seed data that means
    /// nothing — crediting the bank for it is a bug this repo already fixed
    /// once in the queue's chip, and it must not come back through the log.
    func testAMonobankRowSSuggestionsAreNotRecordedAsABankSuggestion() throws {
        let file = MemoryStore()
        let row = tx("Маркет-Приклад", bankId: "monobank", suggestions: ["Продукти"])
        let s = try makeStore([row], log: makeLog(file))

        s.confirm(row.id, as: "Кафе та ресторани")

        XCTAssertNil(try events(file)[0].bankSuggestion)
    }

    func testADetailEditOnAPendingRowIsADetailEdit() throws {
        let file = MemoryStore()
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: makeLog(file))

        s.setCategory(row.id, to: "Продукти")

        let logged = try events(file)
        XCTAssertEqual(logged.map(\.source), [.detailEdit])
        XCTAssertEqual(logged[0].was, "pending")
    }

    /// The most valuable example in the file: the app had an answer and the
    /// person overruled it.
    func testChangingAnAlreadyDecidedRowIsACorrection() throws {
        let file = MemoryStore()
        let row = tx("Маркет-Приклад", resolution: .rule)
        let s = try makeStore([row], log: makeLog(file))

        s.setCategory(row.id, to: "Кафе та ресторани")

        let logged = try events(file)
        XCTAssertEqual(logged.map(\.source), [.correction])
        XCTAssertEqual(logged[0].was, "rule", "what was overruled is the point of the example")
    }

    /// Board #13's own entry in this file: the detail screen's transfer answer
    /// is logged on the same terms as its category answer beside it —
    /// `.correction` when it overrules an answer the app already had. It would
    /// have been a `.queueConfirm` before, because the screen was calling the
    /// queue's mutation, and the training data would have said a tap happened
    /// somewhere it did not.
    func testATransferChosenInDetailIsLoggedAsADetailAnswer() throws {
        let file = MemoryStore()
        let pending = tx("Маркет-Приклад")
        let decided = tx("Сервіс-Приклад", resolution: .rule)
        let s = try makeStore([pending, decided], log: makeLog(file))

        s.setNotAnExpense(pending.id)
        s.setNotAnExpense(decided.id)

        let logged = try events(file)
        XCTAssertEqual(logged.map(\.source), [.detailEdit, .correction])
        XCTAssertEqual(logged.map(\.choice), ["ownTransfer", "ownTransfer"])
        XCTAssertEqual(logged.map(\.was), ["pending", "rule"])
    }

    /// The value is `"ownTransfer"`, not `"notAnExpense"`: board #6 narrowed
    /// the answer to one meaning, and the log is training data — a label that
    /// once covered cash, jars and P2P as well would be unusable to any future
    /// model, with no way to tell which era a line came from.
    func testAnOwnTransferIsRecordedAsAChoiceRatherThanAsACategory() throws {
        let file = MemoryStore()
        let row = tx("Переказ зі своєї картки *0000")
        let s = try makeStore([row], log: makeLog(file))

        s.markNotAnExpense(row.id)

        let logged = try events(file)
        XCTAssertEqual(logged[0].choice, "ownTransfer")
        XCTAssertNil(logged[0].category,
                     "«Переказ між своїми картками» is not a category and must not be encoded as one")
    }

    func testAnIncomeRowRecordsItsSignAndKind() throws {
        let file = MemoryStore()
        let row = tx("Підприємець", amount: 750_000, mcc: nil)
        let s = try makeStore([row], log: makeLog(file))

        s.confirm(row.id, as: "Зарплата")

        let logged = try events(file)
        XCTAssertEqual(logged[0].sign, "in")
        XCTAssertEqual(logged[0].kind, "income")
        XCTAssertNil(logged[0].mcc, "a row the bank sent no code for records none")
        XCTAssertNil(logged[0].originalMcc)
    }

    /// Board #56. The field exists because the two codes disagree on
    /// cross-border rows, so a log carrying only the bank's rewrite would
    /// leave the question this data was collected to answer unanswerable.
    /// Both, and distinct, is the assertion.
    func testACrossBorderRowLogsBothCodesTheBankSent() throws {
        let file = MemoryStore()
        let row = tx("Підписка-Приклад", mcc: 7829, originalMcc: 4899)
        let s = try makeStore([row], log: makeLog(file))

        s.confirm(row.id, as: "Розваги")

        let logged = try events(file)
        XCTAssertEqual(logged[0].mcc, 7829, "what monobank recoded it to")
        XCTAssertEqual(logged[0].originalMcc, 4899, "what the network actually sent")
    }

    // MARK: product groups, from a receipt

    func testPickingAProductGroupIsRecordedWithBothTheGuessAndTheChoice() throws {
        let file = MemoryStore()
        let productFile = MemoryStore()
        let log = makeLog(file, products: productFile)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")

        let logged = try products(productFile)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged[0].name, "Хліб український")
        XCTAssertEqual(logged[0].chosen, "Молочні продукти")
        XCTAssertEqual(logged[0].guessed,
                       ProductGuess.group(for: "Хліб український", in: s.productGroups))
        XCTAssertFalse(logged[0].agreed, "the guess and the choice differ")
        XCTAssertEqual(logged[0].seller, "Крамниця Приклад")
        XCTAssertEqual(logged[0].source, ProductGroupEvent.receiptItem)
        XCTAssertEqual(logged[0].type, "productGroup", "the far end routes on this")
    }

    /// A confirmation is a positive label. Recording only corrections would
    /// teach a model that every answer it already gets right is wrong.
    func testAgreeingWithTheGuessIsStillRecorded() throws {
        let productFile = MemoryStore()
        let log = makeLog(MemoryStore(), products: productFile)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]
        let guess = ProductGuess.group(for: "Хліб український", in: s.productGroups)

        s.setItemGroup(r.items[0].id, on: r.id, to: guess)

        let logged = try products(productFile)
        XCTAssertEqual(logged.count, 1, "a confirmation is an example, not a non-event")
        XCTAssertTrue(logged[0].agreed)
        XCTAssertEqual(logged[0].guessed, logged[0].chosen)
    }

    /// Correcting the same line twice must still compare against the MATCHER,
    /// not against the previous tap — otherwise the second pair says only
    /// "the app agreed with me", which teaches nothing.
    func testASecondCorrectionStillRecordsTheMatchersOwnGuess() throws {
        let productFile = MemoryStore()
        let log = makeLog(MemoryStore(), products: productFile)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]
        let guess = ProductGuess.group(for: "Хліб український", in: s.productGroups)

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")
        s.setItemGroup(r.items[0].id, on: r.id, to: "Овочі та фрукти")

        let logged = try products(productFile)
        XCTAssertEqual(logged.count, 2)
        XCTAssertEqual(logged.map(\.guessed), [guess, guess])
        XCTAssertEqual(logged[1].chosen, "Овочі та фрукти")
    }

    func testNoProductIsRecordedUntilSomebodyTurnsItOn() throws {
        let productFile = MemoryStore()
        let log = makeLog(MemoryStore(), products: productFile, enabled: false)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")

        XCTAssertTrue(productFile.data.isEmpty)
        XCTAssertEqual(log.productLineCount(), 0)
        XCTAssertEqual(s.receipts[0].items[0].category, "Молочні продукти",
                       "the app still does its job with the log off")
    }

    /// What was bought and where the money went are different namespaces, and
    /// the whole point of a second file is that nothing can join them by
    /// accident.
    func testTheTwoLogsNeverWriteIntoEachOther() throws {
        let file = MemoryStore()
        let productFile = MemoryStore()
        let log = makeLog(file, products: productFile)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.confirm(row.id, as: "Продукти")
        XCTAssertEqual(try events(file).count, 1)
        XCTAssertTrue(productFile.data.isEmpty, "a spending category is not a product group")

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")
        XCTAssertEqual(try events(file).count, 1, "and the reverse")
        XCTAssertEqual(try products(productFile).count, 1)
        XCTAssertEqual(log.lineCount(), 1)
        XCTAssertEqual(log.productLineCount(), 1)
    }

    /// The receipt parser drops everything identifying before this point; the
    /// log must not reintroduce the money either.
    func testAProductLineCarriesNoMoneyAndNoIdentifier() throws {
        let productFile = MemoryStore()
        let log = makeLog(MemoryStore(), products: productFile)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")

        let text = String(decoding: productFile.data, as: UTF8.self)
        XCTAssertFalse(text.contains("3200"), "no price, no sum")
        XCTAssertFalse(text.contains("price"))
        XCTAssertFalse(text.contains("qty"))
        XCTAssertFalse(text.contains(r.id.uuidString), "no receipt id")
        XCTAssertFalse(text.contains(r.items[0].id.uuidString), "no item id")
        XCTAssertFalse(text.contains("documentNumber"))
        // The partner: the assertions above must not be passing on an empty
        // file.
        XCTAssertTrue(text.contains("Хліб український"))
        XCTAssertTrue(text.contains("Крамниця Приклад"))
    }

    func testClearEmptiesBothLogs() throws {
        let file = MemoryStore()
        let productFile = MemoryStore()
        let log = makeLog(file, products: productFile)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]
        s.confirm(row.id, as: "Продукти")
        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")

        log.clear()

        XCTAssertEqual(log.lineCount(), 0)
        XCTAssertEqual(log.productLineCount(), 0)
        XCTAssertTrue(productFile.data.isEmpty)
    }

    func testAFullProductFileStopsAppendingAndSaysSo() throws {
        let productFile = MemoryStore()
        productFile.data = Data(count: CategorizationLog.maxBytes)
        let log = makeLog(MemoryStore(), products: productFile)
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")

        XCTAssertEqual(productFile.data.count, CategorizationLog.maxBytes)
        XCTAssertTrue(log.productsFull)
        XCTAssertFalse(log.isFull, "the two caps are independent")
    }

    func testTheWebhookGetsProductLinesToo() async throws {
        let productFile = MemoryStore()
        let sender = SpySender()
        let log = makeLog(MemoryStore(), products: productFile, sender: sender)
        log.webhook = "https://example.test/exec"
        let s = try makeStore([], log: log)
        let r = receipt("Хліб український")
        s.receipts = [r]

        s.setItemGroup(r.items[0].id, on: r.id, to: "Молочні продукти")
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sender.lines.count, 1)
        XCTAssertTrue(String(decoding: sender.lines[0], as: UTF8.self).contains("productGroup"),
                      "the line has to say which tab it belongs in")
        XCTAssertEqual(log.sent, 1)
    }

    // MARK: what must never be written

    /// The line the opt-in text promises. A categorizer needs the shop, not
    /// the size of the person's grocery bill.
    func testTheAmountAndTheCardNeverReachTheFile() throws {
        let file = MemoryStore()
        let row = tx("Маркет-Приклад", amount: -123_456)
        let s = try makeStore([row], log: makeLog(file))

        s.confirm(row.id, as: "Продукти")

        let text = String(decoding: file.data, as: UTF8.self)
        XCTAssertFalse(text.contains("123456"), "the amount must not be in the file")
        XCTAssertFalse(text.contains("123 456"))
        XCTAssertFalse(text.contains("*0000"), "the card suffix must not be in the file")
        XCTAssertFalse(text.contains("amount"))
        XCTAssertFalse(text.contains("cardSuffix"))
        // …and the positive partner, so the assertions above cannot pass by
        // the file simply being empty.
        XCTAssertTrue(text.contains("Маркет-Приклад"))
    }

    // MARK: the webhook

    func testWithNoWebhookTheLineIsStillWritten() throws {
        let file = MemoryStore()
        let sender = SpySender()
        let log = makeLog(file, sender: sender)
        log.webhook = ""
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)

        s.confirm(row.id, as: "Продукти")

        XCTAssertEqual(try events(file).count, 1)
        XCTAssertTrue(sender.lines.isEmpty, "no address, no request")
    }

    /// An `http://` or a typed half-URL must not be posted to. The local half
    /// keeps working regardless — a bad address costs the webhook, not the
    /// training data.
    func testANonHttpsWebhookIsIgnoredAndTheFileStillGetsTheLine() throws {
        for bad in ["http://example.test/exec", "not a url at all", "   "] {
            let file = MemoryStore()
            let sender = SpySender()
            let log = makeLog(file, sender: sender)
            log.webhook = bad
            let row = tx("Маркет-Приклад")
            let s = try makeStore([row], log: log)

            s.confirm(row.id, as: "Продукти")

            XCTAssertEqual(try events(file).count, 1, bad)
            XCTAssertTrue(sender.lines.isEmpty, bad)
        }
    }

    func testAConfiguredWebhookGetsOneLinePerEvent() async throws {
        let file = MemoryStore()
        let sender = SpySender()
        let log = makeLog(file, sender: sender)
        log.webhook = "https://example.test/exec"
        let first = tx("Маркет-Приклад", day: 1)
        let second = tx("Маркет-Приклад", day: 2)
        let s = try makeStore([first, second], log: log)

        s.confirm(first.id, as: "Продукти")
        // The send is fire-and-forget by design, so the UI never waits on it;
        // the test does.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sender.lines.count, 2, "the cascaded row is an example too")
        XCTAssertEqual(log.sent, 2)
        XCTAssertEqual(log.failed, 0)
    }

    func testAFailingWebhookCostsACounterAndNotTheData() async throws {
        let file = MemoryStore()
        let sender = SpySender(answer: false)
        let log = makeLog(file, sender: sender)
        log.webhook = "https://example.test/exec"
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)

        s.confirm(row.id, as: "Продукти")
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(try events(file).count, 1, "the file is the durable copy")
        XCTAssertEqual(log.failed, 1)
        XCTAssertEqual(log.sent, 0)
        XCTAssertEqual(s.transactions[0].category, "Продукти",
                       "a broken webhook must not affect the app at all")
    }

    // MARK: the cap and the housekeeping

    /// No silent truncation: when the file is full the log says so rather
    /// than quietly dropping the tail of the training data.
    func testAFullFileStopsAppendingAndSaysSo() throws {
        let file = MemoryStore()
        file.data = Data(count: CategorizationLog.maxBytes)
        let log = makeLog(file)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)

        s.confirm(row.id, as: "Продукти")

        XCTAssertEqual(file.data.count, CategorizationLog.maxBytes, "nothing was appended")
        XCTAssertTrue(log.isFull)
    }

    func testAWriteFailureIsCountedRatherThanCrashing() throws {
        let file = MemoryStore()
        file.failAppend = true
        let log = makeLog(file)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)

        s.confirm(row.id, as: "Продукти")

        XCTAssertEqual(log.failed, 1)
        XCTAssertEqual(s.transactions[0].category, "Продукти")
    }

    func testClearEmptiesTheFileAndTheCounters() throws {
        let file = MemoryStore()
        let log = makeLog(file)
        let row = tx("Маркет-Приклад")
        let s = try makeStore([row], log: log)
        s.confirm(row.id, as: "Продукти")
        XCTAssertEqual(log.lineCount(), 1)

        log.clear()

        XCTAssertEqual(log.lineCount(), 0)
        XCTAssertTrue(log.contents().isEmpty)
        XCTAssertFalse(log.isFull)
    }

    /// The settings card reads this on every render, so it is cached — and a
    /// cache is only right if it agrees with the file it stands for.
    func testTheLineCountTracksTheFileThroughWritesAndAClear() throws {
        let file = MemoryStore()
        let log = makeLog(file)
        let first = tx("Маркет-Приклад", day: 1)
        let second = tx("Крамниця Хвіст", day: 2)
        let s = try makeStore([first, second], log: log)

        XCTAssertEqual(log.lineCount(), 0)
        s.confirm(first.id, as: "Продукти")
        XCTAssertEqual(log.lineCount(), 1)
        s.confirm(second.id, as: "Тварини")
        XCTAssertEqual(log.lineCount(), 2)
        XCTAssertEqual(log.lineCount(), try events(file).count, "the cache must agree with the file")

        log.clear()
        XCTAssertEqual(log.lineCount(), 0)

        // …and it keeps counting after the clear rather than going stale.
        let third = tx("Маркет-Приклад", day: 3)
        s.transactions = [third]
        s.confirm(third.id, as: "Продукти")
        XCTAssertEqual(log.lineCount(), 1)
    }

    /// A log opened over a file that already holds lines must find them —
    /// the count starts from the file, not from zero.
    func testAReopenedLogCountsWhatIsAlreadyOnDisk() throws {
        let file = MemoryStore()
        let first = tx("Маркет-Приклад", day: 1)
        let s = try makeStore([first], log: makeLog(file))
        s.confirm(first.id, as: "Продукти")

        let reopened = CategorizationLog(store: file, sender: SpySender(), defaults: defaults)
        XCTAssertEqual(reopened.lineCount(), 1)
    }

    /// JSONL, not a JSON array: one self-contained object per line, so the
    /// file can be appended to forever and pasted into a sheet as it is.
    func testTheFileIsOneJSONObjectPerLine() throws {
        let file = MemoryStore()
        let first = tx("Маркет-Приклад", day: 1)
        let second = tx("Крамниця Хвіст", day: 2)
        let s = try makeStore([first, second], log: makeLog(file))

        s.confirm(first.id, as: "Продукти")
        s.confirm(second.id, as: "Тварини")

        let text = String(decoding: file.data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"), "every line is terminated, including the last")
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try SeedLoader.decoder.decode(
                CategorizationEvent.self, from: Data(line.utf8)))
        }
    }
}
