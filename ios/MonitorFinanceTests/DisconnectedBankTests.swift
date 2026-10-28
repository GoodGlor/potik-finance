import XCTest
@testable import MonitorFinance

/// Board #165 — a disconnected monobank went on asking for its token, and went
/// on naming its cards.
///
/// The owner, on the build installed 2026-08-31: «I get a message on the main
/// menu that the mono token is not found, but I have disconnected the monobank»
/// and «the statistics show the monobank cards and the monobank itself».
///
/// **Two symptoms, two causes, and only the first was a defect.** The banner is
/// `SyncEngine.Stop.noToken.userMessage`, persisted as `syncState.lastStop` by
/// any of six call sites that reach `startSync` without the `connectedBanks`
/// guard `startSyncIfConnected` has — pull-to-refresh on Home and on the feed,
/// the depth change, and every background wake. Nothing clears `lastStop`
/// except a sync that commits a window, which cannot happen while the bank is
/// disconnected, so the line stayed on screen across every relaunch.
///
/// The statistics picker is the other kind of finding: it lists a bank because
/// that bank's ROWS are still there, which is what board #157 decided on
/// purpose. So the rows stay and the label carries the fact instead.
@MainActor
final class DisconnectedBankTests: XCTestCase {

    private func makeStore(monobankConnected: Bool = true) -> AppStore {
        let seed = SeedBundle(
            transactions: [],
            banks: [Bank(id: "monobank", displayName: "monobank", status: .available,
                         connected: monobankConnected, accounts: []),
                    Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
                         connected: true, accounts: [])],
            categories: [], rules: [], receipts: [], productGroups: [])
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: the complaint is about a connection that no longer exists

    /// **The detector proving itself.** A connected monobank with no usable
    /// token IS a real complaint, and this asserts the banner still appears
    /// there — otherwise every test below would pass against a fix that simply
    /// deleted the feature.
    func testAConnectedBankWithNoTokenStillComplains() async {
        let store = makeStore()

        _ = await store.startSync()

        XCTAssertEqual(store.syncState.lastStop, SyncEngine.Stop.noToken.rawValue,
                       "a bank the person believes is connected must still say why nothing arrives")
    }

    /// The owner's symptom, in one line: pull to refresh after disconnecting.
    func testASyncAfterDisconnectDoesNotComplainAboutTheBankThatIsGone() async {
        let store = makeStore()
        store.disconnect(bankId: "monobank")

        _ = await store.startSync()

        XCTAssertNil(store.syncState.lastStop,
                     "«Токен monobank не знайдено» about a bank the person disconnected on purpose")
    }

    /// Clearing on disconnect and refusing to write it again are two different
    /// fixes and both are needed: without this one the line already on disk
    /// survives, and without the one above the next pull-to-refresh writes it
    /// straight back.
    func testDisconnectClearsAComplaintAlreadyOnDisk() {
        let store = makeStore()
        store.syncState.lastStop = SyncEngine.Stop.offline.rawValue
        store.syncState.needsReconnect = true

        store.disconnect(bankId: "monobank")

        XCTAssertNil(store.syncState.lastStop)
        XCTAssertFalse(store.syncState.needsReconnect,
                       "a rejected token stops mattering once the token is gone")
    }

    /// `disconnect` takes a bank id, and `syncState`'s stop fields are
    /// monobank's alone. Disconnecting the other bank must not silence them.
    func testDisconnectingAnotherBankLeavesMonobanksStatusAlone() {
        let store = makeStore()
        store.syncState.lastStop = SyncEngine.Stop.offline.rawValue

        store.disconnect(bankId: "privatbank")

        XCTAssertEqual(store.syncState.lastStop, SyncEngine.Stop.offline.rawValue,
                       "one bank's disconnect must not clear another's explanation")
    }

    /// Board #158 made a paused mailbox a state worth keeping. An email-only
    /// person has no monobank connection at all, and their own status line is
    /// the one thing on that screen still telling them anything.
    func testDisconnectLeavesTheEmailStatusAlone() {
        let store = makeStore()
        store.syncState.emailNeedsReconnect = true
        store.syncState.emailPaused = true

        store.disconnect(bankId: "monobank")

        XCTAssertTrue(store.syncState.emailNeedsReconnect,
                      "the letters' own failure is not monobank's to clear")
        XCTAssertTrue(store.syncState.emailPaused)
    }

    /// **The case `disconnect` can never reach.** A `sync.json` restored onto a
    /// phone that has no monobank connection carries whatever stop the old
    /// phone last wrote, and no disconnect ever runs there. `SyncStatusView`
    /// asks this before it speaks, which is why it is a property rather than a
    /// condition spelled out inside the view.
    ///
    /// It is also the pre-existing bug nobody had filed: an **email-only**
    /// person pulling to refresh reaches `startSync`, which reports
    /// `.stopped(.noToken)` because they have no monobank token — and the app
    /// told them to reconnect a bank they had never connected.
    func testAStopOnDiskSaysNothingWhileTheBankIsNotConnected() {
        let store = makeStore(monobankConnected: false)
        store.syncState.lastStop = SyncEngine.Stop.noToken.rawValue
        store.syncState.needsReconnect = true

        XCTAssertFalse(store.monobankIsConnected,
                       "the gate is connectedness, not what the file happens to hold")
    }

    func testTheGateIsOpenWhileTheBankIsConnected() {
        XCTAssertTrue(makeStore().monobankIsConnected)
    }

    // MARK: the statistics picker names a disconnected bank as past

    private var banks: [Bank] {
        [Bank(id: "monobank", displayName: "monobank", status: .available,
              connected: false, accounts: []),
         Bank(id: "privatbank", displayName: "ПриватБанк", status: .comingSoon,
              connected: true, accounts: [])]
    }

    func testAConnectedBankIsNamedPlainly() {
        XCTAssertEqual(StatsView.sourceLabel(.bank("privatbank"), banks: banks, language: .uk),
                       "ПриватБанк")
    }

    func testADisconnectedBankIsMarkedAsPast() {
        XCTAssertEqual(StatsView.sourceLabel(.bank("monobank"), banks: banks, language: .uk),
                       "monobank · відключено",
                       "the rows are still real — the label carries the fact instead of hiding them")
    }

    /// The owner chose the mark on the BANK row only. A card already reads
    /// «monobank · 4321», and «monobank · відключено · 4321» is three marks
    /// fighting over two separators.
    func testACardKeepsItsPlainLabel() {
        XCTAssertEqual(
            StatsView.sourceLabel(.card(bank: "monobank", suffix: "4321"),
                                  banks: banks, language: .uk),
            "monobank · 4321")
    }

    /// `BankMark.bank` falls back to the raw id for a row whose bank is not in
    /// the list at all. That is not the same state as disconnected, and calling
    /// it disconnected would be an invented fact.
    func testAnUnknownBankIsNotCalledDisconnected() {
        XCTAssertEqual(StatsView.sourceLabel(.bank("nonesuch"), banks: banks, language: .uk),
                       "nonesuch")
    }

    /// «відключено» is copy and localises; the bank's name beside it is the
    /// person's data and never does.
    func testTheMarkIsCopyAndTheNameIsNot() {
        XCTAssertEqual(StatsView.sourceLabel(.bank("monobank"), banks: banks, language: .en),
                       "monobank · disconnected")
    }
}
