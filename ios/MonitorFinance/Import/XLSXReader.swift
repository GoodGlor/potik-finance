import Foundation

/// xlsx worksheet → rows of strings. Handles exactly what statement
/// exports contain: shared strings (`t="s"`), inline strings
/// (`t="inlineStr"`), formula-cached strings (`t="str"`) and raw numbers.
/// The FIRST sheet in workbook order is the one read — Privat names it
/// «Виписки», but the name is never trusted.
enum XLSXReader {
    static func rows(from data: Data) throws -> [[String]] {
        let entries = try XLSXArchive.entries(data)
        guard let workbook = entries["xl/workbook.xml"],
              let rels = entries["xl/_rels/workbook.xml.rels"] else {
            throw PrivatImportError.notAnXLSX
        }
        guard let sheetPath = firstSheetPath(workbook: workbook, rels: rels),
              let sheet = entries[sheetPath] else {
            throw PrivatImportError.notAnXLSX
        }
        let shared: [String]
        if let sharedXML = entries["xl/sharedStrings.xml"] {
            guard let parsed = sharedStrings(sharedXML) else { throw PrivatImportError.notAnXLSX }
            shared = parsed
        } else {
            shared = []
        }
        let collector = SheetCollector(shared: shared)
        let parser = XMLParser(data: sheet)
        parser.delegate = collector
        guard parser.parse() else { throw PrivatImportError.notAnXLSX }
        return collector.rows
    }

    /// The first `<sheet>`'s `r:id`, resolved through the rels part.
    private static func firstSheetPath(workbook: Data, rels: Data) -> String? {
        let sheets = AttributeCollector(element: "sheet")
        let wb = XMLParser(data: workbook)
        wb.delegate = sheets
        wb.parse()
        guard let rid = sheets.collected.first?["r:id"] else { return nil }

        let relationships = AttributeCollector(element: "Relationship")
        let rl = XMLParser(data: rels)
        rl.delegate = relationships
        rl.parse()
        guard let target = relationships.collected.first(where: { $0["Id"] == rid })?["Target"]
        else { return nil }
        return target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }

    /// `nil` when the part fails to parse — a truncated or malformed
    /// sharedStrings.xml must refuse the file, not hand back a partial
    /// table that lets later lookups silently miss.
    private static func sharedStrings(_ xml: Data) -> [String]? {
        let collector = SharedStringsCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.strings
    }

    /// "A" → 0, "J" → 9, "AA" → 26. `nil` for a reference with no usable
    /// column letters, or one beyond the format's own XFD ceiling — the
    /// bound is re-checked every iteration, which is also what makes the
    /// arithmetic overflow-proof.
    static func columnIndex(of reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for ch in reference {
            guard let a = ch.asciiValue else { continue }
            let upper = (a >= 97 && a <= 122) ? a - 32 : a
            guard upper >= 65, upper <= 90 else { continue }
            sawLetter = true
            value = value * 26 + Int(upper - 64)
            guard value <= 16_384 else { return nil }   // XFD is the last real column
        }
        return sawLetter ? value - 1 : nil
    }
}

/// Every `<si>`'s concatenated `<t>` text, rich runs included.
private final class SharedStringsCollector: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

/// `<row>`/`<c>`/`<v>`+`<is><t>` → `[[String]]`, gaps as "".
private final class SheetCollector: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private let shared: [String]
    private var cells: [Int: String] = [:]
    private var column = -1
    private var type = "n"
    private var buffer = ""
    private var capturing = false
    // A running rows×width budget, not just `columnIndex`'s per-row cap:
    // `<row><c r="XFD1"><v>1</v></c></row>` is 33 bytes and alone
    // materializes 16,384 strings. Nothing bounded how many such rows a
    // sheet may have, so a ~20 KB archive that deflates trivially (pure
    // repetition) could force gigabytes of `String` allocation — a jetsam
    // kill rather than the `.notAnXLSX` this layer promises. A real
    // 349-row × 10-column statement uses 3,490 of this budget.
    private var emitted = 0

    init(shared: [String]) { self.shared = shared }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            cells = [:]
            column = -1
        case "c":
            if let ref = attributes["r"] {
                guard let index = XLSXReader.columnIndex(of: ref) else {
                    parser.abortParsing()
                    return
                }
                column = index
            } else {
                column += 1
            }
            type = attributes["t"] ?? "n"
            buffer = ""
        case "v", "t":
            capturing = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch name {
        case "v", "t":
            capturing = false
        case "c":
            let value: String
            if type == "s" {
                // A shared-string index that misses the table is refused
                // data, not a number — it must never fall through to the
                // raw digits, which would read as a plausible cell value.
                if let i = Int(buffer), shared.indices.contains(i) {
                    value = shared[i]
                } else {
                    value = ""
                }
            } else {
                value = buffer
            }
            if !value.isEmpty { cells[column] = value }
        case "row":
            let last = cells.keys.max() ?? -1
            emitted += last + 1
            guard emitted <= 2_000_000 else { parser.abortParsing(); return }
            rows.append(last < 0 ? [] : (0...last).map { cells[$0] ?? "" })
        default:
            break
        }
    }
}

/// Collects one element's attribute dictionaries in document order.
private final class AttributeCollector: NSObject, XMLParserDelegate {
    let element: String
    var collected: [[String: String]] = []

    init(element: String) { self.element = element }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == element { collected.append(attributes) }
    }
}
