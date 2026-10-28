import Foundation

/// Decodes the tax cabinet's `checkXml` payload — base64, windows-1251, an
/// `<RQ>` document — into a `ParsedCheck`.
///
/// `XMLDocument` is macOS-only, so this is SAX-based (`XMLParser`), which
/// suits the shape of the data: every value read here is an attribute, and no
/// element carries text worth keeping except `<MAC>`.
///
/// Pinned against `scripts/check_decode.py`'s own answers — see
/// `CheckXMLTests`, generated from `scripts/build_ios_test_fixtures.py` —
/// with one known, deliberate divergence the pin cannot see: Python keys
/// goods by ordinal in a `dict` (a repeated or absent `N` means the LAST
/// line with that ordinal wins), while `Collector` below appends every goods
/// element to an array and applies that ordinal's discount to ALL of them.
/// None of the eight pinned fixtures carries a repeated or absent `N`, so
/// the pin is silent on this. Swift's behaviour is the better of the two —
/// this is not a bug to fix, only a claim the pin does not actually cover.
enum CheckXML {
    static func parse(base64: String) throws -> ParsedCheck {
        guard let data = Data(base64Encoded: base64) else {
            throw TaxCabinetError.malformed("checkXml is not valid base64")
        }
        // The bytes are windows-1251 and the XML declaration says so.
        // Decoding as UTF-8 would not throw — it would silently mangle every
        // Cyrillic name — so this is the one encoding that is correct here.
        guard let text = String(data: data, encoding: .windowsCP1251) else {
            throw TaxCabinetError.malformed("checkXml is not valid windows-1251")
        }
        // Re-declare the encoding after decoding: the bytes are text now, and
        // a parser handed the original declaration would try to re-interpret
        // them as windows-1251 a second time. Only the FIRST occurrence is
        // replaced — a blanket replace would be a silent corruption on the
        // far-fetched day a product name contains this string.
        let rewritten = replacingFirstOccurrence(of: "windows-1251", with: "utf-8", in: text)
        guard let xmlData = rewritten.data(using: .utf8) else {
            throw TaxCabinetError.malformed("could not re-encode as utf-8")
        }

        let collector = Collector()
        let parser = XMLParser(data: xmlData)
        parser.delegate = collector
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "checkXml did not parse"
            throw TaxCabinetError.malformed(reason)
        }

        guard let fiscalTotal = collector.fiscalTotal else {
            throw TaxCabinetError.malformed("no fiscal footer")
        }

        let lines: [ParsedLine] = try collector.rawLines.map { raw in
            let discount = collector.discounts[raw.ordinal] ?? 0
            let netSum = raw.grossSum - discount
            // The footer guard below only refuses a total ABOVE the receipt;
            // nothing else refuses a single line's discount exceeding its own
            // gross sum. Two consecutive `<D>` elements with no `NI` both
            // accumulate onto `lastGoodsOrdinal` (see `Collector`), which can
            // drive one line's `netSum` — and so its `price` — negative
            // while the document still under-totals its own footer and
            // passes that guard. `Receipt.Item.sum`/`.price` are never
            // negative anywhere else in this app; a malformed document is
            // refused here rather than let that invariant break downstream
            // (`SplitMath`'s remainder, in particular).
            guard netSum >= 0 else {
                throw TaxCabinetError.malformed("a line's discount exceeds its own sum")
            }
            return ParsedLine(
                ordinal: raw.ordinal,
                name: raw.name,
                qtyMilli: raw.qtyMilli,
                grossSum: raw.grossSum,
                discount: discount,
                netSum: netSum,
                netUnitPrice: netUnitPrice(netSum: netSum, qtyMilli: raw.qtyMilli)
            )
        }

        let totalNet = lines.reduce(0) { $0 + $1.netSum }
        guard totalNet <= fiscalTotal else {
            throw TaxCabinetError.malformed("lines out-total the receipt")
        }

        return ParsedCheck(
            registerModel: collector.registerModel,
            fiscalTotal: fiscalTotal,
            fiscalTime: collector.fiscalTimeRaw.flatMap(parseFiscalTime),
            mac: collector.sawMAC ? collector.macText.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            lines: lines
        )
    }

    /// What the goods actually cost per unit, after the discount. `Decimal`,
    /// never `Double` — this is the only division in the parser, and it
    /// renders as hryvnia-per-litre in the fuel log.
    private static func netUnitPrice(netSum: Int, qtyMilli: Int) -> Int {
        guard qtyMilli != 0 else { return netSum }
        let qty = Decimal(qtyMilli) / 1000
        var price = Decimal(netSum) / qty
        var rounded = Decimal()
        NSDecimalRound(&rounded, &price, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// `TS="yyyyMMddHHmmss"`, on the wall clock the receipt was printed on —
    /// Kyiv, never the device's zone (see `Models/Kyiv.swift`).
    private static func parseFiscalTime(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = .kyiv
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    private static func replacingFirstOccurrence(of target: String, with replacement: String, in text: String) -> String {
        guard let range = text.range(of: target) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }

    /// One goods element (`<P>` or `<PP>` — S1, they never co-occur in one
    /// document), before its discount (found separately, in `<D>`) is
    /// applied. Kept ordinal-keyed so a `<D NI="…">` can find it regardless
    /// of where either element sits in the document.
    private struct RawLine {
        var ordinal: Int
        var name: String
        var qtyMilli: Int
        var grossSum: Int
    }

    /// Accumulates the handful of elements this stage cares about.
    /// `<L>` is ignored entirely — not collected "for later" — and neither
    /// is the cashier's name: the fiscal footer's cashier-name attribute, or
    /// the vendor block's cashier-name attribute on another register. Named
    /// only in `tests/test_ios_seed.py`'s source-scanning guard, on purpose —
    /// spelling either attribute here would trip that guard for a mention,
    /// not a read.
    private final class Collector: NSObject, XMLParserDelegate {
        var registerModel: String?
        var fiscalTotal: Int?
        var fiscalTimeRaw: String?
        var sawMAC = false
        var macText = ""
        var rawLines: [RawLine] = []
        var discounts: [Int: Int] = [:]

        private var sawFiscalFooter = false
        private var inMAC = false
        // The most recently seen goods element's ordinal, in document order
        // — where a `<D>` with no `NI` (S3) attaches. `nil` until the first
        // goods element is seen, matching the reference decoder's
        // `last_ordinal: int | None = None`: a `<D>` before any goods
        // element has nothing to fall back to and is dropped.
        private var lastGoodsOrdinal: Int?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            switch elementName {
            case "RQ":
                // `NDv` is the register's model and firmware, not a schema
                // version (S4) — a device name string, absent on at least
                // one real receipt, so it stays optional.
                registerModel = attributeDict["NDv"]

            case "P", "PP":
                // Both are goods elements (S1); they never co-occur in one
                // document, so sharing this path costs nothing and avoids
                // duplicating gross/Q/N handling between two cases.
                handleGoods(attributeDict)

            case "D":
                // `NI` names a goods element's document-wide ordinal `N`,
                // never its position — the first goods element in a real
                // document is not ordinal 1, since vendor and loyalty lines
                // precede it. Where `NI` is absent (S3), the discount joins
                // the nearest PRECEDING goods element instead — receipt 1's
                // discounts all lack `NI`, and without this fallback its
                // lines out-total its own footer.
                let sm = attributeDict["SM"].flatMap(Int.init)
                if let ni = attributeDict["NI"].flatMap(Int.init), let sm {
                    discounts[ni, default: 0] += sm
                } else if attributeDict["NI"] == nil, let sm, let last = lastGoodsOrdinal {
                    discounts[last, default: 0] += sm
                }

            case "E":
                // Only the FIRST footer counts, matching the reference
                // decoder's `next(root.iter("E"), None)`.
                guard !sawFiscalFooter else { return }
                sawFiscalFooter = true
                fiscalTotal = attributeDict["SM"].flatMap(Int.init)
                fiscalTimeRaw = attributeDict["TS"]

            case "MAC":
                guard !sawMAC else { return }
                sawMAC = true
                inMAC = true
                macText = ""

            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inMAC else { return }
            macText += string
        }

        /// Shared by `<P>` and `<PP>` (S1). `Q` absent means one unit — 1000,
        /// since `Q` is x1000 (S2) — and `SM` absent means zero gross, which
        /// then makes the line's net sum (and so its unit price) zero too.
        /// `N` absent defaults to ordinal 0, matching the reference decoder's
        /// `int(el.get("N", 0))` rather than silently dropping the line.
        private func handleGoods(_ attributes: [String: String]) {
            let ordinal = attributes["N"].flatMap(Int.init) ?? 0
            lastGoodsOrdinal = ordinal
            rawLines.append(RawLine(
                ordinal: ordinal,
                name: (attributes["NM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                qtyMilli: attributes["Q"].flatMap(Int.init) ?? 1000,
                grossSum: attributes["SM"].flatMap(Int.init) ?? 0
            ))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "MAC" {
                inMAC = false
            }
        }
    }
}
