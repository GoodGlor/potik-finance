import Foundation

/// One leaf of `app/core/products.py`'s taxonomy, as shipped in
/// `reference.json`'s `productGroups`. Keywords arrive already lowercase, trimmed
/// and normalised on the Python side.
struct ProductGroup: Codable, Hashable, Identifiable {
    var name: String
    var keywords: [String]
    var id: String { name }
}

/// Places a scanned receipt line's product name into one of the taxonomy's
/// groups, purely by keyword — there is no ML here, just the same substring
/// rule `app/core/products.py` uses on the Python side.
enum ProductGuess {
    static let other = "Інше"

    /// The first group whose keyword appears in `name`, longest keyword
    /// first so a qualified phrase like «масло вершкове» wins over a bare
    /// word from a different group, else `other`. Never nil: an unplaced
    /// name honestly falls to «Інше» rather than to whichever group happens
    /// to be listed first.
    static func group(for name: String, in groups: [ProductGroup]) -> String {
        let normalized = MerchantKey.normalize(name)
        let candidates = groups
            .flatMap { group in group.keywords.map { (group: group.name, keyword: $0) } }
            .sorted { $0.keyword.count > $1.keyword.count }
        for candidate in candidates where normalized.contains(candidate.keyword) {
            return candidate.group
        }
        return other
    }
}
