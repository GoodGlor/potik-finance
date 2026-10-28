import XCTest
@testable import MonitorFinance

/// Board #168 — a reset destroys the mail address, and it must not.
///
/// The owner, minutes after it happened: «I deleted all the data in the
/// application, and my address was also deleted, to which I set up all the
/// forwarding. […] the address should be one per phone and that's it.»
///
/// **Measured on the live database at the time:** the row that had been
/// receiving mail was gone, and a new one existed sixty seconds later.
/// `DataSettingsView` deleted the server account before wiping, and
/// `POST /register` has no other behaviour — it only ever mints a new random
/// address, so the forwarding rule the owner had set up by hand pointed at a
/// mailbox that no longer existed.
///
/// **The old design traded the cheap failure against the expensive one.**
/// `keychain.wipe()` takes the secret, and the secret is the only thing that
/// can read the mailbox — so a wipe alone left a live address nobody could
/// read, collecting `from` and `subject` forever. Board #158 called that the
/// orphan. But an unreadable mailbox costs rows in a table; a destroyed address
/// costs every forwarding rule a person set up by hand, and cannot be asked for
/// back. Carrying the credentials across the wipe removes the orphan instead of
/// trading against it: the address stays reachable, so it is not orphaned, and
/// it stays the same.
@MainActor
final class ResetKeepsTheMailboxTests: XCTestCase {

    /// Invented values, per the project's fixture rule. A real address or
    /// secret in Swift source is what the privacy guard exists to catch, and
    /// this repository is public.
    private let userId = "u-testfixture000000"
    private let secret = "not-a-real-secret-000"
    private let address = "u-testfixture000000@in.example.test"

    private func makeStore() -> (AppStore, Keychain) {
        let keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        let seed = SeedBundle(transactions: [], banks: [], categories: [],
                              rules: [], receipts: [], productGroups: [])
        let store = AppStore(repository: MemoryRepository(), seed: seed, keychain: keychain)
        return (store, keychain)
    }

    private func registered() -> (AppStore, Keychain) {
        let (store, keychain) = makeStore()
        try? keychain.setString(userId, for: AppStore.emailUserIdKey)
        try? keychain.setString(secret, for: AppStore.emailSecretKey)
        try? keychain.setString(address, for: AppStore.emailAddressKey)
        store.syncState.emailAddressIssued = true
        return (store, keychain)
    }

    // MARK: the address survives

    /// The owner's symptom, inverted into the requirement.
    func testAResetKeepsTheAddress() {
        let (store, _) = registered()

        store.resetEverything()

        XCTAssertEqual(store.privatEmailAddress, address,
                       "the address every forwarding rule points at must outlive a reset")
    }

    /// The address alone is not enough: without the secret the mailbox is
    /// exactly the orphan board #158 was trying to prevent — alive, collecting,
    /// and unreadable.
    func testAResetKeepsTheCredentialsThatCanReadIt() {
        let (store, _) = registered()

        store.resetEverything()

        XCTAssertEqual(store.privatEmailCredentials?.userId, userId)
        XCTAssertEqual(store.privatEmailCredentials?.secret, secret,
                       "an address with no secret is a mailbox nobody can ever read")
    }

    /// Board #111's field means «this phone has been given an address». After a
    /// reset that kept one, it still has been — and a fresh `SyncState` would
    /// lie in the exact direction that field exists to prevent, making the app
    /// offer to create an address and mint a second one.
    func testTheResetStillKnowsAnAddressWasIssued() {
        let (store, _) = registered()

        store.resetEverything()

        XCTAssertTrue(store.syncState.emailAddressIssued)
    }

    /// Everything else still goes. A test that only proved the mailbox survived
    /// would pass just as well against a reset that had quietly stopped
    /// resetting.
    ///
    /// The person's own rows are asserted gone by NAME rather than by
    /// `transactions.isEmpty`: `resetEverything` reloads the bundled seed, so
    /// the array is repopulated and an emptiness check would fail against
    /// correct behaviour. The invented merchant is the thing that must not
    /// survive.
    func testTheResetStillEmptiesEverythingElse() {
        let (store, keychain) = registered()
        try? keychain.setString("a-monobank-token", for: "token.monobank")
        store.syncState.lastStop = SyncEngine.Stop.offline.rawValue
        store.transactions.append(
            Transaction(id: UUID(), date: .init(timeIntervalSince1970: 1_780_000_000),
                        kind: .expense, category: "", merchant: "Крамниця-Вигадана",
                        amount: -4_200, cardSuffix: "*1111", bankId: "monobank",
                        receiptId: nil, splits: [], resolution: .pending, suggestions: []))

        store.resetEverything()

        XCTAssertNil(keychain.getString("token.monobank"), "the bank token is not spared")
        XCTAssertNil(store.syncState.lastStop)
        XCTAssertFalse(store.transactions.contains { $0.merchant == "Крамниця-Вигадана" },
                       "the person's own rows go, even though the seed is reloaded")
        XCTAssertFalse(store.settings.onboarded)
    }

    /// The transactions are gone, so every letter has to be consumed again. A
    /// carried-over cursor would tell the backend they were already imported
    /// and leave the hole `ingestRows` exists to avoid.
    func testTheLetterCursorGoesBackToZero() {
        let (store, _) = registered()
        store.syncState.emailCursor = 42

        store.resetEverything()

        XCTAssertEqual(store.syncState.emailCursor, 0)
    }

    /// A reset promises an empty app, and that promise is kept: the mailbox
    /// exists but PrivatBank is not silently left connected. Setting the mail
    /// up again returns the same address rather than minting one, which is what
    /// makes «one phone, one address» true.
    func testTheResetLeavesNoBankConnected() {
        let (store, _) = registered()

        store.resetEverything()

        XCTAssertTrue(store.connectedBanks.isEmpty)
    }

    // MARK: the reset has no second answer, and that is the point

    /// **Board #170's regression guard, so #168 cannot be undone by accident.**
    ///
    /// `resetEverything` had a `keepingMailbox: false` parameter for one
    /// afternoon, written for a second button in the reset alert that a
    /// screenshot rejected — two red answers differing by two words, under a
    /// message true of one and the opposite of the other. #170 gave the
    /// deliberate deletion its own home («Видалити адресу назавжди», on the
    /// mail screen) and removed the parameter.
    ///
    /// This test fails to COMPILE if anybody adds it back, which is stronger
    /// than an assertion and is the intent: the reset must have exactly one
    /// behaviour towards the mailbox, and it is "leave it alone".
    func testTheResetHasNoWayToAskForTheAddressToo() {
        let (store, _) = registered()

        store.resetEverything()

        XCTAssertEqual(store.privatEmailAddress, address,
                       "the only reset there is keeps the address")
        XCTAssertNotNil(store.privatEmailCredentials)
        XCTAssertTrue(store.syncState.emailAddressIssued)
    }

    /// **The claim must not outlive the key.** If the restore fails, the phone
    /// can no longer read the mailbox, and `emailAddressIssued` would otherwise
    /// promise an address this app can never reach again — sending the person
    /// to a screen that shows them nothing.
    func testAMailboxThatWasNeverThereIsNotClaimedAsIssued() {
        let (store, _) = makeStore()
        store.syncState.emailAddressIssued = true

        store.resetEverything()

        XCTAssertFalse(store.syncState.emailAddressIssued,
                       "keeping nothing must not report that something was kept")
    }

    // MARK: the keychain primitive underneath

    func testWipeKeepingSparesOnlyTheNamedKeys() {
        let keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        try? keychain.setString("kept", for: "a")
        try? keychain.setString("gone", for: "b")

        let restored = keychain.wipe(keeping: ["a"])

        XCTAssertTrue(restored)
        XCTAssertEqual(keychain.getString("a"), "kept")
        XCTAssertNil(keychain.getString("b"))
    }

    /// A key that was not there to begin with is not an error — it is the
    /// ordinary case for a person who never set the mail up.
    func testKeepingAnAbsentKeyIsNotAFailure() {
        let keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
        try? keychain.setString("gone", for: "b")

        XCTAssertTrue(keychain.wipe(keeping: ["a"]))
        XCTAssertNil(keychain.getString("a"))
        XCTAssertNil(keychain.getString("b"))
    }
}
