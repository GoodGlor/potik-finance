import XCTest
@testable import MonitorFinance

/// Board #54. «Підготувати файл» writes the whole dataset — every merchant,
/// amount and category — into `temporaryDirectory`, and it went out with a
/// bare `.atomic` while `Repository` sets
/// `completeUntilFirstUserAuthentication` on the store deliberately and the
/// two categorization exports in the same view set it too.
///
/// Copying the app's own data into a weaker place than the app keeps it is not
/// a trade anybody made on purpose.
final class ExportProtectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() throws -> AppStore {
        var seed = try SeedLoader.load()
        seed.transactions = []
        return AppStore(repository: MemoryRepository(), seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    func testTheExportCarriesTheSameProtectionAsTheStore() throws {
        let url = try makeStore().writeExport(to: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition: it wrote")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        // The simulator does not always report a protection class, and a nil
        // here is that rather than a failure — but when it DOES report one it
        // must not be `.none`, which is what the bare `.atomic` produced.
        try XCTSkipIf(protection == nil, "this platform reports no protection class")
        XCTAssertNotEqual(protection, FileProtectionType.none,
                          "the export must not be weaker than the store it copies")
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication,
                       "the same class `Repository` sets on the store")
    }

    /// The export is the whole dataset, so this is also the test that says so:
    /// if it ever stopped containing the transactions, the protection question
    /// would stop mattering and this file would quietly become pointless.
    func testTheExportReallyContainsThePersonsData() throws {
        let store = try makeStore()
        store.transactions = [Transaction(
            id: UUID(), date: Date(), kind: .expense, category: "Продукти",
            merchant: "Гастроном-Приклад", amount: -12_300, cardSuffix: "*0000",
            bankId: "monobank", receiptId: nil, splits: [], resolution: .user,
            suggestions: [])]

        let url = try store.writeExport(to: directory)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains("Гастроном-Приклад"), "precondition for the card's premise")
    }

    /// One fixed filename: a second export replaces the first rather than
    /// leaving a pile of datasets behind in a directory nobody sweeps.
    func testASecondExportReplacesTheFirstRatherThanAccumulating() throws {
        let store = try makeStore()
        _ = try store.writeExport(to: directory)
        _ = try store.writeExport(to: directory)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["monitorfinance-export.json"], files.description)
    }
}
