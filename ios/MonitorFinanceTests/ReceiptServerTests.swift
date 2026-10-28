import XCTest
@testable import MonitorFinance

/// Board #186 — the phone asks the server to chase a fiscal receipt, and
/// collects the answer instead of asking the tax service itself.
///
/// **Owner:** «Are fiscal check requests sent from the phone? I think it's
/// better to use our server, and set a task there so that as soon as it
/// appears, everything is uploaded to the application.»
///
/// The phone's queue drains only on app-active or a `BGAppRefreshTask` wake,
/// both at iOS's discretion, so its whole retry ladder is a set of ceilings it
/// may never reach — somebody who scans a receipt and puts the phone down can
/// lose the goods. A server is always awake.
///
/// **The two properties this file exists to hold**, both of which are easy to
/// break later and neither of which any other test would notice:
///
/// 1. **The phone never stops being able to ask.** Every failure on the server
///    path falls through to `TaxCabinetClient`. Receipts worked with no server
///    before this card and they still do.
/// 2. **The server's blob is parsed HERE.** The base64 goes through
///    `CheckXML.parse` on the device, which is the other end of the privacy
///    decision that the backend never looks inside one.
@MainActor
final class ReceiptServerTests: XCTestCase {

    // MARK: fakes

    /// Records what it was asked and answers with whatever it was given.
    /// Only the receipt half of `PrivatEmailAPI` does anything; the rest is
    /// present because the protocol requires it and is never reached here.
    private class FakeAPI: PrivatEmailAPI, @unchecked Sendable {
        var queued: [FiscalCheck] = []
        var ready: [PrivatEmailReceipt] = []
        var consumed: [Int] = []
        var listCalls = 0
        var listError: PrivatEmailError?

        func queueReceipt(credentials: PrivatEmailCredentials, check: FiscalCheck) async throws {
            try queueWillThrow.map { throw $0 } ?? ()
            queued.append(check)
        }
        /// Set by the "a failed post costs nothing" test. A stored error
        /// rather than a subclass: `FakeAPI` is nested and final-by-default,
        /// and unsealing a fake to say one thing is a worse trade than a
        /// field nobody else sets.
        var queueWillThrow: PrivatEmailError?
        func readyReceipts(credentials: PrivatEmailCredentials) async throws
            -> [PrivatEmailReceipt] {
            listCalls += 1
            if let listError { throw listError }
            return ready
        }
        func consumeReceipt(credentials: PrivatEmailCredentials, id: Int) async throws {
            consumed.append(id)
        }

        func register() async throws -> PrivatEmailRegistration {
            .init(userId: "u", secret: "s", email: "u@in.example.test")
        }
        func transactions(credentials: PrivatEmailCredentials, since: Int,
                          limit: Int) async throws -> PrivatEmailPage {
            .init(transactions: [], nextCursor: since)
        }
        func pendingLetters(credentials: PrivatEmailCredentials) async throws
            -> PrivatEmailPending { .init(confirmations: [], parseFailures: 0) }
        func status(credentials: PrivatEmailCredentials) async throws -> PrivatEmailStatus {
            .init(email: "u@in.example.test", lastLetterAt: nil, transactionsTotal: 0)
        }
        func deleteAccount(credentials: PrivatEmailCredentials) async throws {}
        func statements(credentials: PrivatEmailCredentials) async throws
            -> PrivatEmailStatements { .init(statements: []) }
        func statementBytes(credentials: PrivatEmailCredentials, id: Int) async throws
            -> Data { Data() }
        func consumeStatement(credentials: PrivatEmailCredentials, id: Int) async throws {}
        func statementLinks(credentials: PrivatEmailCredentials) async throws
            -> PrivatEmailStatementLinks { .init(links: []) }
        func consumeStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws {}
        func downloadStatementLink(credentials: PrivatEmailCredentials, id: Int) async throws
            -> PrivatEmailStatement {
            throw PrivatEmailError.server(404, "not here")
        }
        func recentLetters(credentials: PrivatEmailCredentials) async throws
            -> PrivatEmailRecentLetters { .init(letters: []) }
    }

    /// Counts how often the tax service itself was asked. The whole point of
    /// the card is that this number goes DOWN, so a test that never looks at
    /// it cannot tell the feature from a no-op.
    private final class CountingCabinet: TaxCabinetAPI, @unchecked Sendable {
        var calls = 0
        var answer: ParsedCheck?
        var error: TaxCabinetError = .notPublished
        func check(_ check: FiscalCheck) async throws -> ParsedCheck {
            calls += 1
            if let answer { return answer }
            throw error
        }
    }

    // MARK: fixtures — all invented; this repository is public

    private let register = "4000000000"
    private let document = "42"

    private func check(sum: Int = 28701) -> FiscalCheck {
        FiscalCheck(registerNumber: register, documentNumber: document,
                    fiscalTime: Date(timeIntervalSince1970: 1_787_900_000),
                    fiscalSum: sum, mac: nil)
    }

    /// A minimal windows-1251 `<RQ>`, base64, in exactly the shape the tax
    /// service returns and the server stores unparsed.
    private func blob(total: Int = 28701) -> String {
        let xml = """
        <?xml version="1.0" encoding="windows-1251"?><RQ NDv="ND-74"><DAT><C T="0">\
        <PP N="1" NM="Тестова позиція" Q="1000" PRC="\(total)" SM="\(total)"></PP>\
        <E FN="0" N="0" NO="0" SM="\(total)" TS="20260101000000"></E></C></DAT>\
        <MAC>TEST</MAC></RQ>
        """
        return (xml.data(using: .windowsCP1251) ?? Data()).base64EncodedString()
    }

    private func row(_ id: Int = 1, xml: String? = nil) -> PrivatEmailReceipt {
        .init(id: id, registerNumber: register, documentNumber: document,
              checkXml: xml ?? blob())
    }

    private let credentials = PrivatEmailCredentials(
        userId: "u-testfixture000000", secret: "not-a-real-secret-000")
    private let address = "u-testfixture000000@in.example.test"

    private func cabinet(_ api: FakeAPI, _ direct: CountingCabinet,
                         credentials: PrivatEmailCredentials?,
                         now: @escaping @Sendable () -> Date = { Date() }
    ) -> ServerFirstTaxCabinet {
        ServerFirstTaxCabinet(direct: direct, api: api,
                              credentials: { credentials }, now: now)
    }

    // MARK: the fast path

    func testTheServersAnswerIsUsedAndTheTaxServiceIsNotAsked() async throws {
        let api = FakeAPI()
        api.ready = [row()]
        let direct = CountingCabinet()

        let parsed = try await cabinet(api, direct, credentials: credentials).check(check())

        XCTAssertEqual(direct.calls, 0, "the whole point: the phone did not have to ask")
        XCTAssertEqual(parsed.fiscalTotal, 28701)
        XCTAssertEqual(parsed.lines.count, 1, "the blob really was parsed, on the phone")
    }

    func testCollectingAnAnswerConsumesItOnTheServer() async throws {
        let api = FakeAPI()
        api.ready = [row(7)]

        _ = try await cabinet(api, CountingCabinet(), credentials: credentials).check(check())

        XCTAssertEqual(api.consumed, [7],
                       "the contents of a purchase stop existing on the server as soon as "
                       + "they safely can")
    }

    func testAnAnswerForAnotherDocumentIsNotUsedForThisOne() async throws {
        let api = FakeAPI()
        api.ready = [.init(id: 1, registerNumber: register, documentNumber: "99",
                           checkXml: blob())]
        let direct = CountingCabinet()
        direct.answer = ParsedCheck(registerModel: "1", fiscalTotal: 1,
                                    fiscalTime: Date(), mac: nil, lines: [])

        let parsed = try await cabinet(api, direct, credentials: credentials).check(check())

        XCTAssertEqual(direct.calls, 1, "a different receipt's answer is not this one's")
        XCTAssertEqual(parsed.fiscalTotal, 1)
    }

    // MARK: every fall-through — the property that matters most

    func testWithNoMailboxItAsksTheTaxServiceDirectly() async throws {
        let api = FakeAPI()
        api.ready = [row()]
        let direct = CountingCabinet()
        direct.answer = ParsedCheck(registerModel: "1", fiscalTotal: 5,
                                    fiscalTime: Date(), mac: nil, lines: [])

        let parsed = try await cabinet(api, direct, credentials: nil).check(check())

        XCTAssertEqual(direct.calls, 1)
        XCTAssertEqual(api.listCalls, 0, "a phone with no mailbox never calls the backend")
        XCTAssertEqual(parsed.fiscalTotal, 5)
    }

    func testAnUnreachableBackendFallsThroughRatherThanFailing() async throws {
        let api = FakeAPI()
        api.listError = .offline("no network")
        let direct = CountingCabinet()
        direct.answer = ParsedCheck(registerModel: "1", fiscalTotal: 5,
                                    fiscalTime: Date(), mac: nil, lines: [])

        let parsed = try await cabinet(api, direct, credentials: credentials).check(check())

        XCTAssertEqual(direct.calls, 1,
                       "a fast path that can fail the fetch is a new way to lose a receipt")
        XCTAssertEqual(parsed.fiscalTotal, 5)
    }

    /// An OLD backend answers 404 to a route it does not have. That must read
    /// as «no answer», never as an error — otherwise shipping this app before
    /// the server would break receipts for everyone.
    func testAnOldBackendWithoutTheRouteFallsThrough() async throws {
        let api = FakeAPI()
        api.listError = .server(404, "not found")
        let direct = CountingCabinet()
        direct.answer = ParsedCheck(registerModel: "1", fiscalTotal: 5,
                                    fiscalTime: Date(), mac: nil, lines: [])

        _ = try await cabinet(api, direct, credentials: credentials).check(check())
        XCTAssertEqual(direct.calls, 1)
    }

    func testTheDirectErrorSurvivesTheWrapper() async {
        let api = FakeAPI()
        let direct = CountingCabinet()
        direct.error = .throttled

        do {
            _ = try await cabinet(api, direct, credentials: credentials).check(check())
            XCTFail("the wrapper must not swallow the direct client's own errors")
        } catch {
            // `.throttled` is what stands the whole queue down in
            // `ReceiptFetcher`. A wrapper that turned it into anything else
            // would have the app hammering an endpoint that just asked it to
            // stop.
            XCTAssertEqual(error as? TaxCabinetError, .throttled)
        }
    }

    /// A blob that will not parse is not kept. The direct client re-asks and
    /// gets a fresh one; leaving it on the server means holding somebody's
    /// shopping for nothing.
    func testAnUnparseableBlobIsConsumedAndFallsThrough() async throws {
        let api = FakeAPI()
        api.ready = [row(3, xml: "not base64 at all!!")]
        let direct = CountingCabinet()
        direct.answer = ParsedCheck(registerModel: "1", fiscalTotal: 5,
                                    fiscalTime: Date(), mac: nil, lines: [])

        _ = try await cabinet(api, direct, credentials: credentials).check(check())

        XCTAssertEqual(direct.calls, 1)
        XCTAssertEqual(api.consumed, [3], "not left behind on the server")
    }

    // MARK: the listing window

    func testTheReadyListIsFetchedOncePerDrainAndNotPerReceipt() async throws {
        let api = FakeAPI()
        api.ready = [row()]
        let direct = CountingCabinet()
        direct.error = .notPublished
        let clock = Date(timeIntervalSince1970: 1_787_900_000)
        let wrapper = cabinet(api, direct, credentials: credentials, now: { clock })

        _ = try? await wrapper.check(check())
        for suffix in ["1", "2", "3"] {
            var other = check()
            other.documentNumber = suffix
            _ = try? await wrapper.check(other)
        }

        XCTAssertEqual(api.listCalls, 1,
                       "one list for the whole drain — a call per receipt would be the "
                       + "latency this card removes, added back")
    }

    /// The bug a once-ever flag would have shipped: `ReceiptFetcher` is one
    /// actor for the process, so the wrapper outlives every drain. Without a
    /// clock, every answer the server found after the first drain would sit
    /// uncollected until the app was relaunched.
    func testALaterDrainListsAgain() async throws {
        let api = FakeAPI()
        let direct = CountingCabinet()
        direct.error = .notPublished
        var clock = Date(timeIntervalSince1970: 1_787_900_000)
        let wrapper = ServerFirstTaxCabinet(
            direct: direct, api: api, credentials: { self.credentials },
            now: { clock })

        _ = try? await wrapper.check(check())
        XCTAssertEqual(api.listCalls, 1)

        // Still inside the window: no second listing.
        clock = clock.addingTimeInterval(ServerFirstTaxCabinet.listWindow - 1)
        _ = try? await wrapper.check(check())
        XCTAssertEqual(api.listCalls, 1)

        // Past it: the server's newer answers become reachable again.
        clock = clock.addingTimeInterval(2)
        api.ready = [row()]
        let parsed = try await wrapper.check(check())
        XCTAssertEqual(api.listCalls, 2)
        XCTAssertEqual(parsed.fiscalTotal, 28701)
    }

    // MARK: the question is posted at SCAN time

    private func makeStore(_ api: PrivatEmailAPI) throws -> (AppStore, Keychain) {
        var seed = try SeedLoader.load()
        seed.transactions = []
        seed.receipts = []
        seed.rules = []
        let keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        let store = AppStore(repository: MemoryRepository(), seed: seed,
                             keychain: keychain, emailAPI: api)
        return (store, keychain)
    }

    private func connect(_ keychain: Keychain) {
        try? keychain.setString(credentials.userId, for: AppStore.emailUserIdKey)
        try? keychain.setString(credentials.secret, for: AppStore.emailSecretKey)
        try? keychain.setString(address, for: AppStore.emailAddressKey)
    }

    /// **This, not the wrapper, is what the card is actually about.** The
    /// server only ever has an answer waiting because the question was posted
    /// the moment the QR was read — hours earlier, while the phone was asleep.
    func testScanningPostsTheQuestionToTheServer() async throws {
        let api = FakeAPI()
        let (store, keychain) = try makeStore(api)
        connect(keychain)

        store.scan(check(), now: Date())

        // Posted from a detached task, so the assertion has to let it run —
        // `scan` deliberately does not wait on a network round trip to hand a
        // receipt back to the view that is about to show it.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.queued.count, 1)
        XCTAssertEqual(api.queued.first?.registerNumber, register)
    }

    func testScanningWithNoMailboxPostsNothing() async throws {
        let api = FakeAPI()
        let (store, _) = try makeStore(api)

        store.scan(check(), now: Date())

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.queued, [], "there is nobody to ask")
    }

    /// A failed post must cost nothing: the phone's own client still fetches
    /// the receipt, and the queue entry is unaffected.
    func testAFailedPostStillLeavesTheReceiptQueuedLocally() async throws {
        let api = FakeAPI()
        api.queueWillThrow = .offline("no network")
        let (store, keychain) = try makeStore(api)
        connect(keychain)

        store.scan(check(), now: Date())
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(store.receiptQueue.count, 1,
                       "the local queue is the fallback and is never conditional on the server")
    }
}
