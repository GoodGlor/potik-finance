import XCTest
@testable import MonitorFinance

final class RepositoryTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return url
    }

    func testFileRepositoryRoundTripsAndWipes() throws {
        let repo = FileRepository(directory: tempDir())
        XCTAssertNil(try repo.load("settings", as: Settings.self))

        var s = Settings(); s.onboarded = true
        try repo.save(s, as: "settings")
        XCTAssertEqual(try repo.load("settings", as: Settings.self), s)

        try repo.wipe()
        XCTAssertNil(try repo.load("settings", as: Settings.self))
    }

    func testFileRepositoryCreatesItsDirectory() throws {
        let dir = tempDir().appendingPathComponent("nested/deeper")
        let repo = FileRepository(directory: dir)
        try repo.save([1, 2, 3], as: "numbers")
        XCTAssertEqual(try repo.load("numbers", as: [Int].self), [1, 2, 3])
    }

    func testMemoryRepositoryBehavesTheSame() throws {
        let repo = MemoryRepository()
        XCTAssertNil(try repo.load("x", as: Int.self))
        try repo.save(7, as: "x")
        XCTAssertEqual(try repo.load("x", as: Int.self), 7)
        try repo.wipe()
        XCTAssertNil(try repo.load("x", as: Int.self))
    }

    /// The simulator does not enforce data protection and may report no
    /// protection key at all. Where the platform does report one, it must be
    /// the level we asked for; where it does not, this test says so out loud
    /// rather than passing quietly. The real guarantee is pinned in pytest,
    /// which reads the source.
    func testFilesAreWrittenWithProtectionWhereThePlatformReportsIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = FileRepository(directory: dir)
        try repo.save([1, 2, 3], as: "numbers")
        let path = dir.appendingPathComponent("numbers").appendingPathExtension("json").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let raw = attributes[.protectionKey] else {
            throw XCTSkip("this platform reports no file protection attribute")
        }
        XCTAssertEqual((raw as? FileProtectionType)?.rawValue,
                       FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }
}
