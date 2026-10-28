import XCTest
@testable import MonitorFinance

final class AppStoreTests: XCTestCase {
    private var keychain: Keychain!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)")
    }
    override func tearDown() { keychain.wipe(); super.tearDown() }

    private func seed() throws -> SeedBundle { try SeedLoader.load() }

    func testFreshStoreIsSeededAndNotOnboarded() throws {
        let store = AppStore(repository: MemoryRepository(), seed: try seed(), keychain: keychain)
        XCTAssertEqual(store.transactions.count, 62)
        XCTAssertFalse(store.settings.onboarded)
        XCTAssertFalse(store.isUnlocked)
        XCTAssertTrue(store.connectedBanks.isEmpty)
    }

    func testConnectPersistsAndStoresTheTokenInKeychainOnly() throws {
        let repo = MemoryRepository()
        let store = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        // Emptied first so the reload assertion below actually discriminates:
        // it must fail if `connect` stopped refilling accounts from the seed.
        if let i = store.banks.firstIndex(where: { $0.id == "monobank" }) {
            store.banks[i].accounts = []
        }
        store.connect(bankId: "monobank", token: "uXyZ-secret")
        store.persistNow()

        XCTAssertEqual(store.connectedBanks.map(\.id), ["monobank"])
        XCTAssertEqual(store.token(for: "monobank"), "uXyZ-secret")
        let banksJSON = String(decoding: repo.files["banks"]!, as: UTF8.self)
        XCTAssertFalse(banksJSON.contains("uXyZ-secret"), "tokens must never land in JSON")

        let reloaded = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        XCTAssertTrue(reloaded.banks.first { $0.id == "monobank" }!.connected)
        XCTAssertEqual(reloaded.banks.first { $0.id == "monobank" }!.accounts.count, 4)
    }

    func testDisconnectKeepsHistoryAndDropsTheToken() throws {
        let store = AppStore(repository: MemoryRepository(), seed: try seed(), keychain: keychain)
        store.connect(bankId: "monobank", token: "t")
        store.disconnect(bankId: "monobank")
        XCTAssertTrue(store.connectedBanks.isEmpty)
        XCTAssertNil(store.token(for: "monobank"))
        XCTAssertEqual(store.transactions.count, 62)
    }

    func testSettingsSurviveReload() throws {
        let repo = MemoryRepository()
        let store = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        store.completeOnboarding()
        store.setFaceId(true)
        store.persistNow()
        let reloaded = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        XCTAssertTrue(reloaded.settings.onboarded)
        XCTAssertTrue(reloaded.settings.faceIdEnabled)
    }

    func testDebouncedPersistEventuallyWrites() async throws {
        let repo = MemoryRepository()
        let store = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        store.setFaceId(true)
        XCTAssertNil(repo.files["settings"], "nothing written synchronously")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotNil(repo.files["settings"])
    }

    /// `persistNow` used to write budget.json only when the budget was
    /// non-nil, so a budget file the store is NOT holding was left on disk for
    /// the next launch to read back.
    ///
    /// `budget` is `private(set)` — `setBudget` is its only outside writer —
    /// so this reaches the nil-with-a-file state the way the field does: a
    /// budget.json this build cannot decode. That is not hypothetical;
    /// `IncomeBase.average` grew an associated value on this branch and there
    /// is no version field to tell the two shapes apart.
    func testABudgetFileTheStoreDoesNotHoldIsErasedRatherThanLeftBehind() throws {
        let repo = MemoryRepository()
        let store = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        store.setBudget(Budget(incomeBase: .fixed(49_000),
                               lines: [.init(id: UUID(), category: "Продукти", percent: 20)]))
        store.persistNow()
        XCTAssertNotNil(repo.files["budget"], "precondition: a budget was written at all")

        // A budget.json written by a build whose `Budget` had another shape.
        repo.files["budget"] = Data(#"{"incomeBase":{"nothingWeKnow":true}}"#.utf8)
        let next = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        XCTAssertNil(next.budget, "precondition: this build cannot decode that file")

        next.persistNow()

        XCTAssertNil(repo.files["budget"], "a budget the store does not hold must be erased, not merely skipped")
        let reloaded = AppStore(repository: repo, seed: try seed(), keychain: keychain)
        XCTAssertNil(reloaded.budget, "the next launch must not resurrect it")
    }

    /// A round-trip through the *current* coders would stay green even if
    /// `startedUsingAt` ever became non-optional — it never exercises a file
    /// that predates the field. This decodes a raw pre-stage-5 fixture
    /// instead, so a future non-optional `startedUsingAt` fails here, not
    /// silently in `AppStore.init`'s `try?`.
    func testSettingsWrittenBeforeStage5StillDecode() throws {
        let old = Data(#"{"faceIdEnabled":true,"onboarded":true}"#.utf8)
        let s = try SeedLoader.decoder.decode(Settings.self, from: old)
        XCTAssertTrue(s.onboarded)
        XCTAssertTrue(s.faceIdEnabled)
        XCTAssertNil(s.startedUsingAt)
    }

    /// A user who onboarded on a pre-stage-5 build has `onboarded == true` and
    /// no stamp. Without a migration their queue stays empty forever, since a
    /// nil stamp means "nothing queues" and nothing ever re-runs
    /// `completeOnboarding` for them.
    func testAPreStage5OnboardedUserIsStampedOnLoadAndTheStampIsPersisted() throws {
        let repo = MemoryRepository()
        repo.files["settings"] = Data(#"{"faceIdEnabled":false,"onboarded":true}"#.utf8)
        let store = AppStore(repository: repo, seed: try seed(), keychain: keychain)

        XCTAssertNotNil(store.settings.startedUsingAt, "migrated in-memory, not left nil forever")

        let onDisk = try SeedLoader.decoder.decode(Settings.self, from: repo.files["settings"]!)
        XCTAssertNotNil(onDisk.startedUsingAt,
                        "written back immediately — waiting for the debounced persist would let the queue boundary creep forward between launches")
    }
}
