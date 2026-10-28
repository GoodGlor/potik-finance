import XCTest
@testable import MonitorFinance

/// **A corrupt file must be noticed, and must survive being noticed.**
/// Board #68, split out of #65.
///
/// `Repository.load` returns nil for a MISSING document and throws for one
/// that exists and does not decode. `AppStore.init` collapsed those two with
/// `try?` and fell back to the seed either way, so a fresh install and a
/// person's history going quiet looked identical and neither said anything.
///
/// The half the card did not name is the one these tests spend most of their
/// assertions on: after the fallback, the very next `persist()` writes the
/// seed OVER the file it could not read. Reporting the loss a moment before
/// making it permanent is not much of an improvement, so the file is moved
/// aside first — see `Repository.quarantine`.
@MainActor
final class LoadFailureTests: XCTestCase {

    private let keychain = Keychain(service: "ua.monitorfinance.tests.loadFailures")

    private func seed() throws -> SeedBundle {
        var seed = try SeedLoader.load()
        seed.transactions = []
        return seed
    }

    /// Valid JSON, wrong shape — the realistic corruption. A truncated file
    /// would also throw, but a build whose model changed is how this repo has
    /// actually reached the state twice.
    private let notATransactionsFile = Data(#"[{"nothingWeKnow":true}]"#.utf8)

    private func store(_ repo: MemoryRepository) throws -> AppStore {
        AppStore(repository: repo, seed: try seed(), keychain: keychain)
    }

    // MARK: told apart (the first criterion)

    func testAMissingFileIsNotAFailure() throws {
        let repo = MemoryRepository()
        XCTAssertTrue(repo.files.isEmpty, "precondition: a fresh install")
        XCTAssertEqual(try store(repo).loadFailures, [],
                       "a fresh install must not accuse itself of losing anything")
    }

    func testAFileThatExistsAndDoesNotDecodeIsAFailure() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = notATransactionsFile
        XCTAssertEqual(try store(repo).loadFailures, ["transactions"])
    }

    /// Every document, one at a time, because a name that is loaded but not
    /// routed through the recording path would be invisible — and there is no
    /// way to see that from the outside except by corrupting each in turn.
    func testEveryDocumentTheStoreLoadsIsReported() throws {
        for name in ["transactions", "banks", "categories", "rules", "receipts",
                     "receiptQueue", "budget", "settings", "sync"] {
            let repo = MemoryRepository()
            repo.files[name] = Data(#"[{"nothingWeKnow":true}]"#.utf8)
            XCTAssertEqual(try store(repo).loadFailures, [name],
                           "\(name) is loaded without being watched")
        }
    }

    func testSeveralCorruptFilesAreAllReported() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = notATransactionsFile
        repo.files["receipts"] = notATransactionsFile
        XCTAssertEqual(try store(repo).loadFailures, ["transactions", "receipts"],
                       "in load order, so the report reads the same way twice")
    }

    /// The app must still open. The report is the point; a refusal to launch
    /// would be a worse answer to the same problem.
    func testTheAppStillOpensOnTheSeed() throws {
        let repo = MemoryRepository()
        repo.files["categories"] = notATransactionsFile
        let s = try store(repo)
        XCTAssertFalse(s.categories.isEmpty, "the fallback is unchanged")
        XCTAssertEqual(s.loadFailures, ["categories"])
    }

    // MARK: not overwritten (the half the card did not name)

    func testTheCorruptFileIsMovedAsideRatherThanLeftToBeOverwritten() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = notATransactionsFile

        _ = try store(repo)

        XCTAssertNil(repo.files["transactions"], "the unreadable file is out of the way")
        XCTAssertEqual(repo.files["transactions.corrupt"], notATransactionsFile,
                       "…and its bytes are kept exactly as they were")
    }

    /// The assertion this whole file exists for. Without the quarantine the
    /// store falls back to the seed, `persist()` runs on the first change,
    /// and the person's file is gone — reported, and gone.
    func testPersistingDoesNotWriteTheSeedOverThePersonsData() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = notATransactionsFile

        let s = try store(repo)
        s.persistNow()

        XCTAssertEqual(repo.files["transactions.corrupt"], notATransactionsFile,
                       "persist must not reach the file it could not read")
        XCTAssertNotNil(repo.files["transactions"],
                        "precondition: persist really did write a transactions file")
        XCTAssertNotEqual(repo.files["transactions"], repo.files["transactions.corrupt"],
                          "…and it wrote a NEW one, beside the old, not onto it")
    }

    /// A second bad launch must not throw and leave the file in place for
    /// `persist()` to overwrite — which would be the original failure, reached
    /// by a longer road.
    func testASecondCorruptFileReplacesTheFirstQuarantine() throws {
        let repo = MemoryRepository()
        repo.files["transactions"] = notATransactionsFile
        _ = try store(repo)

        let newer = Data(#"[{"somethingElseEntirely":1}]"#.utf8)
        repo.files["transactions"] = newer
        let s = try store(repo)

        XCTAssertEqual(s.loadFailures, ["transactions"], "reported again, not swallowed")
        XCTAssertNil(repo.files["transactions"])
        XCTAssertEqual(repo.files["transactions.corrupt"], newer)
    }

    /// `FileRepository` is the one that ships. `MemoryRepository` carries the
    /// same behaviour for every other test here, and the two drifting apart
    /// would make all of them true and none of them useful.
    func testTheFileRepositoryQuarantinesOnDiskToo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = FileRepository(directory: dir)

        try repo.save([1, 2, 3], as: "numbers")
        let before = try Data(contentsOf: dir.appendingPathComponent("numbers.json"))

        try repo.quarantine("numbers")

        XCTAssertNil(try repo.load("numbers", as: [Int].self), "gone from its own name")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("numbers.corrupt.json")),
                       before, "…and byte-identical under the quarantined one")

        // Twice, because `moveItem` refuses an existing destination and the
        // throw would leave the second file where `persist()` could reach it.
        try repo.save([4, 5], as: "numbers")
        XCTAssertNoThrow(try repo.quarantine("numbers"))
        XCTAssertEqual(
            try SeedLoader.decoder.decode(
                [Int].self,
                from: Data(contentsOf: dir.appendingPathComponent("numbers.corrupt.json"))),
            [4, 5], "the newer file wins the one slot")
    }

    func testQuarantiningAMissingFileDoesNothingAndDoesNotThrow() throws {
        let repo = MemoryRepository()
        XCTAssertNoThrow(try repo.quarantine("transactions"))
        XCTAssertTrue(repo.files.isEmpty)
    }

    // MARK: what it says on screen

    /// A raw storage key on a settings screen is not a report anybody can act
    /// on. `fileTitle` falls back to the key by design — so this is the test
    /// that notices when a new document arrives without a word for it.
    func testEveryLoadedDocumentHasAWordAPersonCanRead() {
        for name in ["transactions", "banks", "categories", "rules", "receipts",
                     "receiptQueue", "budget", "settings", "sync"] {
            XCTAssertNotEqual(AppStore.fileTitle(name), name,
                              "\(name) would appear on screen as its storage key")
        }
        XCTAssertEqual(AppStore.fileTitle("somethingNew"), "somethingNew",
                       "the fallback is the key, and is meant to look wrong")
    }

    /// It describes THIS launch. A persisted copy could only go stale — the
    /// next launch either reads the file or reports it again.
    func testTheReportIsNotWrittenToDisk() throws {
        let repo = MemoryRepository()
        repo.files["receipts"] = notATransactionsFile
        let s = try store(repo)
        XCTAssertEqual(s.loadFailures, ["receipts"], "precondition")

        s.persistNow()
        for (name, data) in repo.files where name != "receipts.corrupt" {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("loadFailures"),
                           "\(name) carries a report that belongs to one launch")
        }
    }
}
