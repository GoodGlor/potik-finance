import XCTest
@testable import MonitorFinance

/// Board #132 — what one `persist()` actually costs on the main actor.
///
/// The freeze survived board #105, which removed two real per-row render
/// costs. This is the suspect #105 never looked at: `AppStore.persistNow()` is
/// `@MainActor` and re-encodes **nine files including all the transactions**,
/// 300 ms after any change, with no diffing. Every queue confirm calls it.
///
/// **Measured against a real `FileRepository` on disk, not `MemoryRepository`.**
/// The whole question is what `Data.write(options: .atomic)` costs — a temp
/// file, an fsync and a rename, nine times over — and an in-memory repository
/// would hide exactly the thing being measured.
///
/// Numbers here are a Mac's. A phone's flash and a Debug build are slower, so
/// treat them as a floor.
@MainActor
final class PersistCostTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mf-persist-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() throws -> AppStore {
        AppStore(repository: FileRepository(directory: directory),
                 seed: try SeedLoader.load(),
                 keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// **The baseline the card asks for, before anything changes.**
    ///
    /// Not an assertion about a threshold — a wall-clock limit on a shared
    /// machine is a flake generator. This asserts only that the cost is
    /// measurable at all, and reports the number.
    func testOnePersistIsMeasurable() throws {
        let store = try store()
        store.persistNow()                       // warm: create the directory
        let runs = 10
        let total = elapsed { for _ in 0..<runs { store.persistNow() } }
        let each = total / Double(runs)
        print("PERSIST-COST one persistNow() = \(String(format: "%.1f", each * 1000)) ms "
              + "(\(store.transactions.count) transactions, 9 files)")
        XCTAssertGreaterThan(each, 0, "the measurement itself must work")
    }

    /// **Where the cost is: encoding, or writing?** The fix differs entirely.
    ///
    /// If encoding dominates, the answer is to encode off the main actor. If
    /// writing dominates, the answer is to write fewer files — the nine are
    /// rewritten whole on every change, and a queue confirm touches two of them.
    func testEncodingVersusWriting() throws {
        let store = try store()
        store.persistNow()

        let encoding = elapsed {
            for _ in 0..<10 { _ = try? SeedLoader.encoder.encode(store.transactions) }
        }
        let everything = elapsed { for _ in 0..<10 { store.persistNow() } }

        print("PERSIST-COST encode transactions only = "
              + "\(String(format: "%.1f", encoding / 10 * 1000)) ms")
        print("PERSIST-COST full persistNow()        = "
              + "\(String(format: "%.1f", everything / 10 * 1000)) ms")
        XCTAssertGreaterThan(everything, 0)
    }

    /// **What ELSE runs on the main actor when the queue appears.**
    ///
    /// The owner's report names «analyze» — Розібрати, the queue — and the
    /// feed. Persisting is not the only whole-dataset work those screens do,
    /// and naming the biggest cost matters more than confirming the first
    /// suspect. Board #8 made these once-per-render rather than once-per-row;
    /// once per render is still once per tab change.
    func testWhatTheQueueCostsToOpen() throws {
        let store = try store()
        let groups = elapsed { for _ in 0..<10 { _ = store.pendingGroups } }
        let months = elapsed { for _ in 0..<10 { _ = Derived.months(store.transactions) } }
        let persist = elapsed { for _ in 0..<10 { store.persistNow() } }

        print("PERSIST-COST store.pendingGroups = "
              + "\(String(format: "%.2f", groups / 10 * 1000)) ms")
        print("PERSIST-COST Derived.months      = "
              + "\(String(format: "%.2f", months / 10 * 1000)) ms")
        print("PERSIST-COST persistNow          = "
              + "\(String(format: "%.2f", persist / 10 * 1000)) ms")
        XCTAssertGreaterThan(groups, 0)
    }

    /// **The fix, as a ratio.** What `persist()` costs the main actor is now a
    /// snapshot and a task — retains of copy-on-write arrays — not nine
    /// encodes and nine atomic writes.
    ///
    /// A ratio and not a clock, because a wall-clock threshold on a shared
    /// machine is a flake generator. Twentyfold is far inside the gap measured
    /// here and far outside anything noise produces.
    func testPersistCostsTheMainActorAlmostNothingNow() throws {
        let store = try store()
        store.persistNow()

        let deferred = elapsed { for _ in 0..<50 { store.persist() } }
        let immediate = elapsed { for _ in 0..<50 { store.persistNow() } }

        print("PERSIST-COST persist() on the main actor = "
              + "\(String(format: "%.3f", deferred / 50 * 1000)) ms; "
              + "persistNow() = \(String(format: "%.2f", immediate / 50 * 1000)) ms")
        XCTAssertLessThan(deferred * 20, immediate,
                          "persist() must not be doing the writing on the main actor")
    }

    /// **The half that matters more than the speed: it still saves.**
    ///
    /// Moving work off the main actor is only an improvement if the work still
    /// happens. This is the test that would catch a debounced write that was
    /// dropped, cancelled or never scheduled — the failure mode where the app
    /// feels faster because it stopped doing its job.
    func testADebouncedPersistStillReachesTheDisk() async throws {
        let store = try store()
        let marker = Date(timeIntervalSince1970: 1_234_567_890)
        store.settings.guideSeenAt = marker
        store.persist()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if savedSettings()?.guideSeenAt == marker { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("a debounced persist never reached the disk — the fix stopped it saving")
    }

    /// **`persistNow()` is the suspend flush and must be SYNCHRONOUS.**
    ///
    /// iOS suspends the process shortly after the background notification
    /// returns. If this write were queued rather than performed, the change it
    /// carries — the last one the person made — would be the one lost.
    func testTheFlushHasAlreadyWrittenByTheTimeItReturns() throws {
        let store = try store()
        let marker = Date(timeIntervalSince1970: 1_234_567_890)
        store.settings.guideSeenAt = marker
        store.persistNow()

        XCTAssertEqual(savedSettings()?.guideSeenAt, marker,
                       "persistNow must not return before the bytes are on disk")
    }

    /// Decoded rather than string-matched: a date's spelling in JSON is the
    /// encoder's business, and a test that asserts one is a test about the
    /// encoder.
    private func savedSettings() -> Settings? {
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent("settings.json")) else { return nil }
        return try? SeedLoader.decoder.decode(Settings.self, from: data)
    }

    /// **The shape of the waste, stated as a ratio rather than a clock.**
    ///
    /// A queue confirm changes `transactions` and `rules`. `persistNow` writes
    /// all nine regardless — so the six it did not need to touch are pure cost,
    /// repeated 300 ms after every single tap in the queue.
    func testWritingOneFileIsFarCheaperThanWritingNine() throws {
        let store = try store()
        store.persistNow()
        let repository = FileRepository(directory: directory)

        let one = elapsed {
            for _ in 0..<10 { try? repository.save(store.rules, as: "rules") }
        }
        let nine = elapsed { for _ in 0..<10 { store.persistNow() } }

        print("PERSIST-COST one small file = \(String(format: "%.2f", one / 10 * 1000)) ms; "
              + "all nine = \(String(format: "%.1f", nine / 10 * 1000)) ms")
        XCTAssertGreaterThan(nine, one,
                             "if writing nine files were not dearer than one, this card's "
                             + "hypothesis would be dead and the profile would have to start over")
    }
}
