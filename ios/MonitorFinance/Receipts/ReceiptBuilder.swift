import Foundation

/// Turns a scanned QR (`FiscalCheck`) and a fetched document (`ParsedCheck`)
/// into the app's own `Receipt`. Pure: no I/O, no clock reads beyond the
/// `now` the caller hands in.
enum ReceiptBuilder {

    /// What a scan produces before the goods themselves have been fetched:
    /// every field the QR carried, and `items` left empty with
    /// `itemsLandedAt` left `nil` so the UI can tell "not fetched yet" apart
    /// from "fetched, genuinely no lines".
    static func shell(from check: FiscalCheck, now: Date) -> Receipt {
        Receipt(id: UUID(), scannedAt: now,
                registerNumber: check.registerNumber,
                documentNumber: check.documentNumber,
                fiscalTime: check.fiscalTime,
                fiscalSum: check.fiscalSum,
                // D8: the display name comes from the purchase this receipt
                // is matched to, never from a vendor extension on the
                // document — so a fresh shell carries none.
                sellerName: "",
                items: [])
    }

    /// Maps each `ParsedLine` to a `Receipt.Item`. `price` is `netUnitPrice`
    /// — already divided in `Decimal` by `CheckXML` — never `PRC`, which is
    /// the pre-discount pump price and disagrees with the line's own total.
    /// `category` is left `nil`: the product group is guessed lazily where
    /// it is rendered, not written here. Every call mints fresh `UUID`s so
    /// two scans of the same receipt never share item identity.
    static func items(from parsed: ParsedCheck) -> [Receipt.Item] {
        parsed.lines.map { line in
            Receipt.Item(id: UUID(), name: line.name,
                         qty: Double(line.qtyMilli) / 1000,
                         price: line.netUnitPrice,
                         sum: line.netSum,
                         category: nil)
        }
    }

    /// Compares the QR's control number against the document's. Absence on
    /// either side is not disagreement — the bundled samples' synthesised
    /// URLs carry no `mac`, and that is the only scanning path a simulator
    /// (no camera) can reach.
    static func macMatches(_ parsed: ParsedCheck, _ check: FiscalCheck) -> Bool {
        guard let parsedMAC = parsed.mac, let checkMAC = check.mac else { return true }
        return parsedMAC == checkMAC
    }
}
