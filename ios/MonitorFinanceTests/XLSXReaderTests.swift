import XCTest
@testable import MonitorFinance

/// Assembles a minimal, valid, STORED-only zip so a test can hand
/// `XLSXReader` a hand-built workbook/sheet/sharedStrings combination
/// without needing compression — `XLSXArchive`'s own coverage of DEFLATE
/// and STORED entries already lives in `XLSXArchiveTests`.
private struct MiniZip {
    private var localBytes: [UInt8] = []
    private var centralBytes: [UInt8] = []
    private var count: UInt16 = 0

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    mutating func add(_ name: String, _ content: String) {
        let nameBytes = Array(name.utf8)
        let fileBytes = Array(content.utf8)
        let offset = UInt32(localBytes.count)

        localBytes += le32(0x0403_4b50)
        localBytes += le16(20); localBytes += le16(0); localBytes += le16(0)   // stored
        localBytes += le16(0); localBytes += le16(0)
        localBytes += le32(0)
        localBytes += le32(UInt32(fileBytes.count))
        localBytes += le32(UInt32(fileBytes.count))
        localBytes += le16(UInt16(nameBytes.count))
        localBytes += le16(0)
        localBytes += nameBytes
        localBytes += fileBytes

        centralBytes += le32(0x0201_4b50)
        centralBytes += le16(20); centralBytes += le16(20); centralBytes += le16(0); centralBytes += le16(0)
        centralBytes += le16(0); centralBytes += le16(0)
        centralBytes += le32(0)
        centralBytes += le32(UInt32(fileBytes.count))
        centralBytes += le32(UInt32(fileBytes.count))
        centralBytes += le16(UInt16(nameBytes.count))
        centralBytes += le16(0); centralBytes += le16(0); centralBytes += le16(0); centralBytes += le16(0)
        centralBytes += le32(0)
        centralBytes += le32(offset)
        centralBytes += nameBytes
        count += 1
    }

    func finish() -> Data {
        let cdStart = UInt32(localBytes.count)
        var all = localBytes
        all += centralBytes
        all += le32(0x0605_4b50)
        all += le16(0); all += le16(0)
        all += le16(count); all += le16(count)
        all += le32(UInt32(centralBytes.count))
        all += le32(cdStart)
        all += le16(0)
        return Data(all)
    }
}

/// A workbook whose single sheet resolves straight to `worksheetXML`, with
/// an optional `xl/sharedStrings.xml`. Enough for `XLSXReader` — it never
/// looks at `[Content_Types].xml`.
private func makeXLSX(sheet worksheetXML: String, shared sharedXML: String? = nil) -> Data {
    var zip = MiniZip()
    zip.add("xl/workbook.xml", """
    <?xml version="1.0" encoding="UTF-8"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" r:id="rId1" sheetId="1"/></sheets></workbook>
    """)
    zip.add("xl/_rels/workbook.xml.rels", """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
    """)
    zip.add("xl/worksheets/sheet1.xml", worksheetXML)
    if let sharedXML {
        zip.add("xl/sharedStrings.xml", sharedXML)
    }
    return zip.finish()
}

final class XLSXReaderTests: XCTestCase {
    private var sample: Data { Data(base64Encoded: PrivatFixtureData.sampleBase64)! }
    private var edge: Data { Data(base64Encoded: PrivatFixtureData.edgeCasesBase64)! }

    func testSampleTitleHeaderAndRowCount() throws {
        let rows = try XLSXReader.rows(from: sample)
        XCTAssertEqual(rows.count, 16)   // title + header + 14 data rows
        XCTAssertEqual(rows[0].first, "Історія операцій за період 01.08.2026 - 20.08.2026")
        XCTAssertEqual(rows[1], ["Дата", "Категорія", "Картка", "Опис операції",
                                 "Сума в валюті картки", "Валюта картки",
                                 "Сума в валюті транзакції", "Валюта транзакції",
                                 "Залишок на кінець періоду", "Валюта залишку"])
    }

    func testSharedStringsAndNumbersResolve() throws {
        let rows = try XLSXReader.rows(from: sample)
        XCTAssertEqual(rows[2][0], "20.08.2026 18:07:59")
        XCTAssertEqual(rows[2][4], "-174.5")
        XCTAssertEqual(rows[2][5], "UAH")
    }

    func testAGapInARowStaysAGap() throws {
        // Row 13 of the sample (index 12) has an empty card cell — column C
        // was never written, and it must come back as "" with D following.
        let rows = try XLSXReader.rows(from: sample)
        XCTAssertEqual(rows[12][2], "")
        XCTAssertEqual(rows[12][3], "Списання відсотків за кредитом")
    }

    func testInlineStringsSparseRowsAndStoredEntries() throws {
        let rows = try XLSXReader.rows(from: edge)
        XCTAssertEqual(rows, [["перший", "", "42"], ["спільний"]])
    }

    func testMissingWorkbookIsNotAnXLSX() {
        // A valid zip that is not a workbook: zip the edge fixture's bytes
        // as a plain entry? Simpler: hand XLSXReader a zip with no
        // xl/workbook.xml by reusing the sample with a doctored name is
        // overkill — a plain zip of nothing is enough, and garbage data
        // already fails in XLSXArchive. Use a minimal zip: the EOCD of an
        // EMPTY archive (22 fixed bytes, entry count 0).
        var empty = Data(count: 22)
        empty[0] = 0x50; empty[1] = 0x4b; empty[2] = 0x05; empty[3] = 0x06
        XCTAssertThrowsError(try XLSXReader.rows(from: empty)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    // MARK: - Column-reference hardening

    func testCyrillicColumnLetterIsRefusedNotCrashed() {
        // U+0410 (Cyrillic А) has no `asciiValue` — `isLetter` is still
        // true for it, which is exactly what used to force-unwrap to nil.
        let xlsx = makeXLSX(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="А1"><v>1</v></c></row></sheetData></worksheet>
        """)
        XCTAssertThrowsError(try XLSXReader.rows(from: xlsx)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testFourteenLetterReferenceIsRefusedNotTrapped() {
        let xlsx = makeXLSX(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="ZZZZZZZZZZZZZZ1"><v>1</v></c></row></sheetData></worksheet>
        """)
        XCTAssertThrowsError(try XLSXReader.rows(from: xlsx)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testLowercaseColumnLetterResolvesLikeUppercase() throws {
        let xlsx = makeXLSX(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="a1"><v>7</v></c></row></sheetData></worksheet>
        """)
        let rows = try XLSXReader.rows(from: xlsx)
        XCTAssertEqual(rows, [["7"]])
    }

    func testSevenLetterReferenceIsRefusedRatherThanAllocating() {
        // Column index 321,272,406 — a ~5.1 GB row materialization from a
        // few dozen bytes of XML if it were ever allowed through.
        let xlsx = makeXLSX(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="AAAAAAA1"><v>1</v></c></row></sheetData></worksheet>
        """)
        XCTAssertThrowsError(try XLSXReader.rows(from: xlsx)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    // MARK: - Shared-strings hardening

    func testTruncatedSharedStringsIsRefused() {
        let xlsx = makeXLSX(
            sheet: """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>
            """,
            shared: """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>непов
            """)
        XCTAssertThrowsError(try XLSXReader.rows(from: xlsx)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }

    func testOutOfRangeSharedStringIndexYieldsEmptyNotDigits() throws {
        let xlsx = makeXLSX(
            sheet: """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>5</v></c></row></sheetData></worksheet>
            """,
            shared: """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1"><si><t>єдиний</t></si></sst>
            """)
        let rows = try XLSXReader.rows(from: xlsx)
        XCTAssertEqual(rows, [[]])   // never "5" — an empty cell is dropped, not faked
    }

    // MARK: - Column carry across rows

    func testOmittedColumnReferenceResetsAtEachRow() throws {
        let xlsx = makeXLSX(sheet: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c t="inlineStr"><is><t>a</t></is></c><c t="inlineStr"><is><t>b</t></is></c><c t="inlineStr"><is><t>c</t></is></c></row><row r="2"><c t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>
        """)
        let rows = try XLSXReader.rows(from: xlsx)
        XCTAssertEqual(rows, [["a", "b", "c"], ["x"]])
    }

    // MARK: - Rows × width budget

    func testRowsTimesWidthPastTheBudgetIsRefused() {
        // Each row alone is far under any per-row limit — one cell at the
        // format's own last column, XFD — but there are enough of them that
        // the TOTAL cells materialized (rows × 16,384) blows past the
        // collector's running budget. A single-column cap would never catch
        // this; only a running rows×width total does.
        let row = "<row><c r=\"XFD1\"><v>1</v></c></row>"
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(String(repeating: row, count: 200))</sheetData></worksheet>
        """
        let xlsx = makeXLSX(sheet: sheet)
        XCTAssertThrowsError(try XLSXReader.rows(from: xlsx)) {
            XCTAssertEqual($0 as? PrivatImportError, .notAnXLSX)
        }
    }
}
