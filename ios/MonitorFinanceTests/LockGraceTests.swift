import XCTest
@testable import MonitorFinance

/// Board #21: backgrounding locked instantly, so the app's own core flow —
/// leave for Приват24, come back with a statement — cost a Face ID every
/// time. A minute of grace covers the errand; «Блокувати одразу» turns it off.
///
/// Every test drives `lockForBackground`/`unlockIfWithinGrace` with an
/// injected `now`, which is the whole reason the decision lives on the store
/// rather than in `RootView`'s `scenePhase` handler: a wall clock cannot be
/// asked what happens at 59.9 s and at 60.
final class LockGraceTests: XCTestCase {

    private func makeStore(_ repository: Repository = MemoryRepository()) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [], categories: [],
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: the default

    /// The default is the grace. A settings file that predates the field
    /// decodes to it too — the field is Optional precisely so that an upgrade
    /// is not a decode failure.
    func testTheGracePeriodIsTheDefault() throws {
        XCTAssertFalse(Settings().locksImmediately)

        let old = Data(#"{"onboarded":true,"faceIdEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertFalse(decoded.locksImmediately,
                       "a settings file written before board #21 must still open the app")
    }

    /// …and the choice survives being written down, which is the only reason
    /// to put it in `Settings` rather than in memory.
    func testTheChoiceRoundTripsThroughTheSettingsFile() throws {
        var settings = Settings()
        settings.lockImmediately = true
        let reloaded = try JSONDecoder().decode(
            Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(reloaded.locksImmediately)
    }

    // MARK: leaving

    /// Backgrounding still locks, board #21 or not: this is the frame iOS
    /// photographs for the app switcher, and a preview showing a balance is a
    /// leak the grace window has no opinion about.
    func testBackgroundingStillLocks() {
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertFalse(store.isUnlocked)
    }

    /// The stamp must not reach disk: a cold start locks however recent it
    /// was, because the grace covers an errand with the process still alive,
    /// not being force-quit and reopened.
    ///
    /// Asserted against the file the app writes rather than against the
    /// property, because what keeps the stamp off disk is which TYPE it lives
    /// on — move it into `Settings` for convenience one day and every other
    /// test here still passes.
    func testTheStampIsNeverWrittenToDisk() throws {
        let repository = MemoryRepository()
        let store = makeStore(repository)
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        store.persistNow()

        let written = try XCTUnwrap(repository.files["settings"])
        let text = String(decoding: written, as: UTF8.self)
        XCTAssertFalse(text.contains("backgroundedAt"), text)
        XCTAssertNotNil(store.backgroundedAt, "precondition: there WAS a stamp to leak")
    }

    // MARK: coming back

    func testAReturnInsideTheWindowSkipsTheCode() {
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertTrue(store.unlockIfWithinGrace(now: t0 + 45))
        XCTAssertTrue(store.isUnlocked)
    }

    func testAReturnPastTheWindowAsksForTheCode() {
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0 + 61))
        XCTAssertFalse(store.isUnlocked)
    }

    /// The window is `0 ..< 60`, so the boundary itself locks. Pinned as a
    /// literal 60: a test reading `AppStore.lockGrace` would follow the
    /// constant anywhere it went.
    func testExactlyAMinuteIsAlreadyTooLong() {
        XCTAssertEqual(AppStore.lockGrace, 60, accuracy: 0.0001)
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0 + 60))
    }

    /// A clock that moved backwards while the app was away is not a grace
    /// period. Elapsed is negative there, and `< 60` would happily let it in.
    func testAClockThatWentBackwardsDoesNotOpenTheApp() {
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0 - 3600))
        XCTAssertFalse(store.isUnlocked)
    }

    /// One shot. `RootView` calls this on every non-background scene phase, so
    /// a stamp that survived its use would unlock a later return that earned
    /// nothing — the app was never backgrounded again to re-earn it.
    func testTheGraceIsSpentOnceAndNotKept() {
        let store = makeStore()
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertTrue(store.unlockIfWithinGrace(now: t0 + 1))

        store.isUnlocked = false          // whatever locked it next: a wipe, a manual lock
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0 + 2),
                       "the stamp was already spent — this return earned nothing")
        XCTAssertFalse(store.isUnlocked)
    }

    // MARK: what must never get a grace

    /// **Backgrounding the LOCK SCREEN leaves no stamp.** Otherwise the way
    /// past the lock would be to background the app and come straight back —
    /// which is a gesture, not a credential.
    func testBackgroundingWhileAlreadyLockedEarnsNothing() {
        let store = makeStore()
        store.isUnlocked = false
        store.lockForBackground(now: t0)
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0 + 1),
                       "an already-locked app must not unlock itself by being backgrounded")
        XCTAssertFalse(store.isUnlocked)
    }

    /// «Блокувати одразу» means no stamp is taken at all, so there is nothing
    /// for a return to spend — not even an instant one.
    func testImmediateModeTakesNoStamp() {
        let store = makeStore()
        store.setLockImmediately(true)
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertNil(store.backgroundedAt)
        XCTAssertFalse(store.unlockIfWithinGrace(now: t0))
        XCTAssertFalse(store.isUnlocked)
    }

    /// And turning it back off restores the grace without needing a relaunch.
    func testTurningImmediateModeOffRestoresTheGrace() {
        let store = makeStore()
        store.setLockImmediately(true)
        store.setLockImmediately(false)
        store.isUnlocked = true
        store.lockForBackground(now: t0)
        XCTAssertTrue(store.unlockIfWithinGrace(now: t0 + 5))
    }
}
