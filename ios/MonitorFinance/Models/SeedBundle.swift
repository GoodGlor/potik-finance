import Foundation

/// The shape the app works with. Assembled from `reference.json` and — in
/// Debug only — `demo.json`. Deliberately unchanged as a type: every
/// `AppStore(repository:seed:)` in the app and the tests keeps compiling.
struct SeedBundle: Codable {
    var transactions: [Transaction]
    var banks: [Bank]
    var categories: [Category]
    var rules: [Rule]
    var receipts: [Receipt]
    var productGroups: [ProductGroup]
}

/// What ships in every build: a dictionary, not a person's money.
struct ReferenceBundle: Codable {
    var banks: [Bank]
    var categories: [Category]
    var productGroups: [ProductGroup]
}

#if DEBUG
/// Invented demo data, for the simulator and the test suite. Compiled out of
/// Release, AND excluded from the Release bundle by `EXCLUDED_SOURCE_FILE_NAMES`
/// — the fence alone would leave the file readable inside the .ipa.
struct DemoBundle: Codable {
    var transactions: [Transaction]
    var receipts: [Receipt]
    var rules: [Rule]
    var accounts: [String: [Account]]
}
#endif

enum SeedLoader {
    enum Error: Swift.Error { case missing }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func loadReference(bundle: Bundle = .main) throws -> ReferenceBundle {
        guard let url = bundle.url(forResource: "reference", withExtension: "json") else {
            throw Error.missing
        }
        return try decoder.decode(ReferenceBundle.self, from: Data(contentsOf: url))
    }

    /// Reference data always; demo data only in Debug, and only when the
    /// launch has not asked for an empty app.
    static func load(bundle: Bundle = .main) throws -> SeedBundle {
        let reference = try loadReference(bundle: bundle)
        var seed = SeedBundle(transactions: [], banks: reference.banks,
                              categories: reference.categories, rules: [],
                              receipts: [], productGroups: reference.productGroups)
#if DEBUG
        if !Launch.noDemoData,
           let url = bundle.url(forResource: "demo", withExtension: "json"),
           let demo = try? decoder.decode(DemoBundle.self, from: Data(contentsOf: url)) {
            seed.transactions = demo.transactions
            seed.receipts = demo.receipts
            seed.rules = demo.rules
            for (bankId, accounts) in demo.accounts {
                guard let i = seed.banks.firstIndex(where: { $0.id == bankId }) else { continue }
                seed.banks[i].accounts = accounts
            }
        }
#endif
        return seed
    }
}
