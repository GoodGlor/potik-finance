import Compression
import XCTest
@testable import MonitorFinance

/// Assembles a minimal, valid zip byte-by-byte so tests can construct
/// central-directory / local-header combinations `XLSXArchive` must refuse
/// without needing a real xlsx fixture for each one.
private struct RawZipBuilder {
    private(set) var bytes: [UInt8] = []

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Appends one local file header + its raw file data, returning the
    /// header's offset (what a central-directory entry points back to).
    mutating func appendLocalHeader(
        name: String, method: UInt16, compressedSize: UInt32, uncompressedSize: UInt32,
        fileData: [UInt8]
    ) -> Int {
        let offset = bytes.count
        let nameBytes = Array(name.utf8)
        bytes += le32(0x0403_4b50)
        bytes += le16(20)                          // version needed
        bytes += le16(0)                           // flags
        bytes += le16(method)
        bytes += le16(0)                           // mod time
        bytes += le16(0)                           // mod date
        bytes += le32(0)                           // crc32 (unchecked by the reader)
        bytes += le32(compressedSize)
        bytes += le32(uncompressedSize)
        bytes += le16(UInt16(nameBytes.count))
        bytes += le16(0)                           // extra length
        bytes += nameBytes
        bytes += fileData
        return offset
    }

    /// Appends one central-directory header. `localHeaderOffset` need not be
    /// distinct from another entry's — nothing in the format requires it.
    mutating func appendCentralDirectoryEntry(
        name: String, flags: UInt16 = 0, method: UInt16, compressedSize: UInt32,
        uncompressedSize: UInt32, localHeaderOffset: UInt32
    ) {
        let nameBytes = Array(name.utf8)
        bytes += le32(0x0201_4b50)
        bytes += le16(20)                          // version made by
        bytes += le16(20)                          // version needed
        bytes += le16(flags)
        bytes += le16(method)
        bytes += le16(0)                           // mod time
        bytes += le16(0)                           // mod date
        bytes += le32(0)                           // crc32
        bytes += le32(compressedSize)
        bytes += le32(uncompressedSize)
        bytes += le16(UInt16(nameBytes.count))
        bytes += le16(0)                           // extra length
        bytes += le16(0)                           // comment length
        bytes += le16(0)                           // disk number start
        bytes += le16(0)                           // internal attributes
        bytes += le32(0)                           // external attributes
        bytes += le32(localHeaderOffset)
        bytes += nameBytes
    }

    /// Appends the end-of-central-directory record and returns the finished
    /// archive.
    mutating func finish(centralDirectoryOffset: UInt32, centralDirectorySize: UInt32, recordCount: UInt16) -> Data {
        bytes += le32(0x0605_4b50)
        bytes += le16(0)                           // disk number
        bytes += le16(0)                           // disk where CD starts
        bytes += le16(recordCount)
        bytes += le16(recordCount)
        bytes += le32(centralDirectorySize)
        bytes += le32(centralDirectoryOffset)
        bytes += le16(0)                           // comment length
        return Data(bytes)
    }
}

/// Raw DEFLATE via the same `COMPRESSION_ZLIB` algorithm the archive reader
/// decodes with, for tests that need a real compressed stream.
private func deflate(_ input: Data) -> Data {
    let src = [UInt8](input)
    var dst = [UInt8](repeating: 0, count: src.count + 256)
    let written = dst.withUnsafeMutableBufferPointer { dstBuf in
        src.withUnsafeBufferPointer { srcBuf in
            compression_encode_buffer(
                dstBuf.baseAddress!, dstBuf.count, srcBuf.baseAddress!, srcBuf.count, nil, COMPRESSION_ZLIB)
        }
    }
    return Data(dst.prefix(written))
}

final class XLSXArchiveTests: XCTestCase {
    private var sample: Data { Data(base64Encoded: PrivatFixtureData.sampleBase64)! }
    private var edge: Data { Data(base64Encoded: PrivatFixtureData.edgeCasesBase64)! }

    func testDeflatedArchiveListsEveryEntry() throws {
        let entries = try XLSXArchive.entries(sample)
        XCTAssertNotNil(entries["xl/workbook.xml"])
        XCTAssertNotNil(entries["xl/sharedStrings.xml"])
        XCTAssertNotNil(entries["xl/worksheets/sheet1.xml"])
        XCTAssertNotNil(entries["xl/_rels/workbook.xml.rels"])
    }

    func testDeflatedEntryInflatesToRealXML() throws {
        let workbook = try XCTUnwrap(XLSXArchive.entries(sample)["xl/workbook.xml"])
        let text = try XCTUnwrap(String(data: workbook, encoding: .utf8))
        XCTAssertTrue(text.contains("<workbook"), "inflated bytes should be the workbook XML")
        XCTAssertTrue(text.contains("Виписки"))
    }

    func testStoredEntriesComeBackVerbatim() throws {
        let shared = try XCTUnwrap(XLSXArchive.entries(edge)["xl/sharedStrings.xml"])
        XCTAssertTrue(try XCTUnwrap(String(data: shared, encoding: .utf8)).contains("спільний"))
    }

    func testGarbageIsNotAnXLSX() {
        XCTAssertThrowsError(try XLSXArchive.entries(Data("не zip, а текст".utf8))) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testEmptyDataIsNotAnXLSX() {
        XCTAssertThrowsError(try XLSXArchive.entries(Data())) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testTruncatedArchiveIsNotAnXLSX() {
        XCTAssertThrowsError(try XLSXArchive.entries(sample.prefix(120))) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testEncryptedEntriesAreRefused() {
        let encrypted = Data(base64Encoded: PrivatFixtureData.encryptedBase64)!
        XCTAssertThrowsError(try XLSXArchive.entries(encrypted)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    /// Two central-directory entries pointing at the SAME tiny local header,
    /// each individually under `maxEntrySize` but summing well past it. Every
    /// per-entry guard passes; only a whole-archive budget catches this.
    func testEntriesSharingOneLocalHeaderCannotMultiplyPastTheBudget() {
        var zip = RawZipBuilder()
        let localOffset = zip.appendLocalHeader(
            name: "a", method: 0, compressedSize: 1, uncompressedSize: 1, fileData: [0x58])
        let cdStart = zip.bytes.count
        let hugeSize: UInt32 = 9_000_000   // under maxEntrySize alone; two of these exceed it
        zip.appendCentralDirectoryEntry(
            name: "a", method: 0, compressedSize: 1, uncompressedSize: hugeSize,
            localHeaderOffset: UInt32(localOffset))
        zip.appendCentralDirectoryEntry(
            name: "b", method: 0, compressedSize: 1, uncompressedSize: hugeSize,
            localHeaderOffset: UInt32(localOffset))
        let cdSize = zip.bytes.count - cdStart
        let data = zip.finish(
            centralDirectoryOffset: UInt32(cdStart), centralDirectorySize: UInt32(cdSize), recordCount: 2)

        XCTAssertThrowsError(try XLSXArchive.entries(data)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    /// The central directory claims a much smaller `uncompressedSize` than
    /// the entry really inflates to. An undersized destination buffer makes
    /// `compression_decode_buffer` return the buffer's capacity rather than
    /// an error, so this must be refused — never silently truncated.
    func testUnderDeclaredUncompressedSizeIsRefusedNotTruncated() {
        let realText = Data(String(repeating: "виписка ПриватБанку ", count: 20).utf8)
        let compressed = deflate(realText)
        var zip = RawZipBuilder()
        let localOffset = zip.appendLocalHeader(
            name: "x", method: 8, compressedSize: UInt32(compressed.count),
            uncompressedSize: UInt32(realText.count), fileData: [UInt8](compressed))
        let cdStart = zip.bytes.count
        let declaredSize: UInt32 = 8   // far smaller than realText.count
        zip.appendCentralDirectoryEntry(
            name: "x", method: 8, compressedSize: UInt32(compressed.count),
            uncompressedSize: declaredSize, localHeaderOffset: UInt32(localOffset))
        let cdSize = zip.bytes.count - cdStart
        let data = zip.finish(
            centralDirectoryOffset: UInt32(cdStart), centralDirectorySize: UInt32(cdSize), recordCount: 1)

        XCTAssertThrowsError(try XLSXArchive.entries(data)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    /// A STORED (method 0) entry whose declared `uncompressedSize` disagrees
    /// with its `compressedSize`. Nothing decompresses a stored entry, so
    /// the two sizes are supposed to be identical by definition — and
    /// exploitably so before this guard: a tiny declared `uncompressedSize`
    /// (even 0) adds nothing to the whole-archive budget while `payload`
    /// still retains `compressedSize` bytes, and distinct central-directory
    /// entries may share one local header to multiply that many times over.
    func testStoredEntryWithMismatchedDeclaredSizeIsRefused() {
        let fileBytes: [UInt8] = Array(repeating: 0x41, count: 1_000)
        var zip = RawZipBuilder()
        let localOffset = zip.appendLocalHeader(
            name: "a", method: 0, compressedSize: UInt32(fileBytes.count),
            uncompressedSize: UInt32(fileBytes.count), fileData: fileBytes)
        let cdStart = zip.bytes.count
        // Declares an uncompressedSize of 0 — nothing added to the budget —
        // while the local header (and thus `payload`) still holds 1,000 bytes.
        zip.appendCentralDirectoryEntry(
            name: "a", method: 0, compressedSize: UInt32(fileBytes.count),
            uncompressedSize: 0, localHeaderOffset: UInt32(localOffset))
        let cdSize = zip.bytes.count - cdStart
        let data = zip.finish(
            centralDirectoryOffset: UInt32(cdStart), centralDirectorySize: UInt32(cdSize), recordCount: 1)

        XCTAssertThrowsError(try XLSXArchive.entries(data)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    /// The size cap on the whole archive, checked before `[UInt8](data)`
    /// copies it — a file this large is refused before any structural byte
    /// is even read, rather than doubled in memory first.
    func testAnArchiveLargerThanTheWholeFileCapIsRefused() {
        let oversized = Data(count: XLSXArchive.maxArchiveSize + 1)
        XCTAssertThrowsError(try XLSXArchive.entries(oversized)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }
}
