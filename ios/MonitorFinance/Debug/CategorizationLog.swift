import Foundation
import Observation

/// Which action produced a categorization. Outside the `#if DEBUG` fence
/// below because the mutations in `AppStore+Queue` take it as a parameter and
/// those mutations exist in every build — the enum is a word, and words carry
/// no data off the device. Everything that reads one is Debug-only.
enum CategorizationSource: String, Codable, Hashable {
    /// The picker, opened from a queue card.
    case queueConfirm
    /// The «Приват: …» chip — the bank's own word, accepted in one tap.
    case suggestionChip
    /// The picker, opened from a transaction's detail screen, on a row that
    /// had not been decided yet.
    case detailEdit
    /// The same screen, on a row that ALREADY had an answer. The most
    /// valuable signal here: it is the user telling the app it was wrong.
    case correction
    /// Not a tap at all — a sibling row the confirmed merchant's rule
    /// resolved along with it.
    case cascade
    /// Board #103. One category answered for several cards at once.
    ///
    /// **One event per MERCHANT, not one per tap.** `record` tags row 0 with
    /// the source and every other row `.cascade`, so a ten-card sweep writes
    /// ten `.bulk` events — one deliberate answer each — with their siblings as
    /// cascades. That is the truth, and it is what the card meant by "not N
    /// synthetic single confirms": the log must never claim somebody opened a
    /// picker ten times.
    ///
    /// It is deliberately its own case rather than `queueConfirm`. A bulk
    /// answer is weaker evidence than a considered one — the person was
    /// agreeing to a batch, not looking at this merchant — and a training set
    /// that cannot tell them apart cannot weigh them apart.
    case bulk
}

#if DEBUG

/// One answer, as it will be read back for training.
///
/// What it holds, and what it deliberately does not: merchant text, its
/// normalized key, MCC, the bank, the bank's own suggestion, the category
/// chosen and how. NOT the amount — only its sign — and never a card suffix,
/// a balance or an account id. The amount is what turns a row from a fact
/// about a shop into a fact about a person, and a categorizer does not need
/// it. `CategorizationLogTests` pins the absence.
struct CategorizationEvent: Codable, Hashable {
    var at: Date
    var source: CategorizationSource
    /// `"category"` or `"ownTransfer"` — the shape of the answer, since
    /// «Переказ між своїми картками» is not a category and must not be encoded
    /// as one.
    ///
    /// It read `"notAnExpense"` until board #6, and the rename is worth the
    /// churn precisely because this file is training data: under the old copy
    /// that one value covered own-card transfers, ATM cash, jar top-ups and
    /// money sent to a person, and no future model could tell those four
    /// apart. The log has never been switched on with real data, so nothing
    /// written under the old meaning exists to reconcile — this is the last
    /// moment the rename is free.
    var choice: String
    /// nil exactly when `choice == "ownTransfer"`.
    var category: String?
    var merchant: String
    var merchantKey: String
    var mcc: Int?
    /// The card network's own code, before monobank rewrote it — see
    /// `Transaction.originalMcc`. Logged beside `mcc` rather than instead of
    /// it: on a cross-border row the two disagree and nothing here knows yet
    /// which one predicts the answer, so the training data has to carry both
    /// for that question to be answerable at all. A four-digit network code
    /// says nothing about a person, exactly as `mcc` does not.
    var originalMcc: Int?
    /// `"in"` or `"out"`. The sign, never the amount.
    var sign: String
    var bankId: String
    /// The bank's own category word, when the row arrived with one.
    var bankSuggestion: String?
    /// What the row was before this answer — `pending`, or the answer being
    /// corrected.
    var was: String
    var kind: String
}

/// One product-group answer from a scanned receipt.
///
/// A DIFFERENT shape from `CategorizationEvent`, in a different file, bound
/// for a different tab — deliberately, and not as tidiness. `Receipt.Item`'s
/// group is what was BOUGHT; a transaction's category is where the money
/// WENT. This repo keeps those two namespaces apart everywhere else
/// (`SplitMath`, `AppStore+Splits`, the spec), and one shared column here
/// would be a standing invitation to join them and quietly poison both
/// training sets.
///
/// What it does not carry: price, quantity, sum, and no id of any kind. The
/// receipt parser already drops everything that identifies a person —
/// cashier names, loyalty ids, card numbers, EANs, excise serials — and none
/// of it may come back in through this door.
struct ProductGroupEvent: Codable, Hashable {
    /// Fixed for now, and present anyway: a second place to pick a group
    /// would otherwise be indistinguishable in the sheet, and adding the
    /// column later means migrating rows that already exist.
    static let receiptItem = "receiptItem"

    var at: Date
    var source: String
    /// Routes the row to the right tab at the far end. Absent on a
    /// `CategorizationEvent`, so the webhook can tell the two apart without
    /// guessing from which keys happen to be present.
    var type = "productGroup"
    /// The product text exactly as the register printed it — the input a
    /// later model has to work from.
    var name: String
    /// What `ProductGuess` said, from the keyword list alone, before the tap.
    var guessed: String
    /// What the person actually picked.
    var chosen: String
    /// Whether the guess was already right. A confirmation is a positive
    /// label, not a non-event: logging corrections only would teach a model
    /// that every answer it gets right is wrong.
    var agreed: Bool
    /// The shop. «Молоко» at a pharmacy is not «молоко» at a grocer, and
    /// product-group prediction without the seller is a harder problem than
    /// it needs to be.
    var seller: String
}

/// Where the lines go. A protocol so a test never touches a real file and the
/// whole suite still runs in milliseconds.
protocol CategorizationLogStore: AnyObject {
    func append(_ line: Data) throws
    func contents() throws -> Data
    func clear() throws
    /// Bytes already written. The cap is enforced against this.
    func size() throws -> Int
}

/// The webhook. Reports whether the line was accepted, so a wrong URL shows
/// up as a number on the settings screen instead of as silence.
protocol CategorizationEventSender: Sendable {
    func send(_ line: Data, to url: URL) async -> Bool
}

/// Training data for a categorizer that does not exist yet.
///
/// The app has no categorizer: it asks, once per shop, and the answer becomes
/// a rule. That is deliberate (spec D4), and it also means every answer a
/// person gives is a labelled example nobody is keeping. This keeps them, so
/// a base categorizer can later be trained on real Ukrainian bank text rather
/// than on a keyword list somebody guessed.
///
/// **Debug only, and that is load-bearing.** Everything here is inside one
/// `#if DEBUG` fence, so none of it exists in a Release binary. The app tells
/// its users their data never leaves the device, and a telemetry path that
/// ships to the App Store and merely promises not to fire is a weaker promise
/// than one the compiler keeps. `test_the_categorization_log_is_debug_only`
/// guards the fence; the `nm` recipe in `docs/HANDOFF.md` proves the binary.
///
/// **Opt-in on top of that.** Off until a person turns it on in
/// Налаштування → Дані, where the text says in full what would be sent.
///
/// The receiving end is `docs/categorization-sheet.gs` — an Apps Script bound
/// to the spreadsheet, deployed as a web app. No Google account is involved
/// here: the app sends an unauthenticated POST, and the /exec URL is the only
/// credential.
@Observable
@MainActor
final class CategorizationLog {

    /// Past this the log stops appending and says so on the settings screen.
    /// Silently dropping the tail would be the worst outcome: collection
    /// looks like it is running and the data is not there.
    static let maxBytes = 8 * 1024 * 1024

    @ObservationIgnored private let store: CategorizationLogStore
    /// A second file, not a `type` column in the first one — see
    /// `ProductGroupEvent`.
    @ObservationIgnored private let productStore: CategorizationLogStore
    @ObservationIgnored private let sender: CategorizationEventSender
    @ObservationIgnored private let defaults: UserDefaults

    /// Deliberately UserDefaults rather than the app's own `Settings`
    /// document: a Debug-only switch must not change the shape of a Codable
    /// the Release build also writes, and reading it must not cost a file
    /// read on every `AppStore` init — the unit suite builds hundreds.
    private static let enabledKey = "debug.categorizationLog.enabled"
    private static let webhookKey = "debug.categorizationLog.webhook"

    /// Counters for the settings screen. Session-scoped; the file is the
    /// durable record.
    private(set) var sent = 0
    private(set) var failed = 0
    private(set) var isFull = false
    private(set) var productsFull = false

    /// Counted once and then kept, because the settings card shows it and
    /// SwiftUI re-evaluates a body far more often than lines are written —
    /// re-reading an 8 MB file on every render would make the screen it is
    /// meant to inform stutter.
    private var counted: Int?
    private var countedProducts: Int?

    /// Stored, then written through — NOT computed over `defaults`. A
    /// computed property has nothing for `@Observable` to track, so the
    /// settings card kept its old shape after the switch was flipped: the
    /// toggle drew itself on and the address field it is supposed to reveal
    /// never appeared. Caught by the UI test, invisible to every unit test.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Empty means "file only". A string that is not an https URL is treated
    /// as empty rather than as an error — the local half must keep working.
    /// Trimmed on the way to disk rather than in place, so the field does not
    /// fight the person typing into it.
    var webhook: String {
        didSet {
            defaults.set(webhook.trimmingCharacters(in: .whitespacesAndNewlines),
                         forKey: Self.webhookKey)
        }
    }

    init(store: CategorizationLogStore = CategorizationFileStore.standard(),
         productStore: CategorizationLogStore = CategorizationFileStore.products(),
         sender: CategorizationEventSender = CategorizationWebhookSender(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.productStore = productStore
        self.sender = sender
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.webhook = defaults.string(forKey: Self.webhookKey) ?? ""
    }

    private var webhookURL: URL? {
        guard !webhook.isEmpty, let url = URL(string: webhook), url.scheme == "https" else {
            return nil
        }
        return url
    }

    /// `rows` are the snapshots taken BEFORE the mutation — what arrived, not
    /// what it became — and `rows[0]` is the row the person actually acted
    /// on. Everything after it was resolved by the cascade, which is a
    /// different kind of example and is labelled as one.
    ///
    /// Synchronous, so a test can assert straight after the mutation rather
    /// than waiting on a hop that may or may not have run. The store's
    /// mutations are not themselves main-actor-isolated, so the call site
    /// states the assumption — see `AppStore.note`.
    func record(_ source: CategorizationSource, rows: [Transaction],
                choice: CategoryChoice) {
        guard isEnabled, !rows.isEmpty else { return }
        let now = Date()
        for (i, row) in rows.enumerated() {
            append(event(row, source: i == 0 ? source : .cascade, choice: choice, at: now))
        }
    }

    /// One receipt line, answered. Called from `AppStore.setItemGroup`, which
    /// is the only place a person can pick a product group.
    func recordProduct(name: String, guessed: String, chosen: String, seller: String) {
        guard isEnabled else { return }
        let event = ProductGroupEvent(
            at: Date(), source: ProductGroupEvent.receiptItem, name: name,
            guessed: guessed, chosen: chosen, agreed: guessed == chosen, seller: seller)
        guard let line = try? SeedLoader.encoder.encode(event) else { return }
        appendProduct(line)
    }

    private func appendProduct(_ line: Data) {
        do {
            guard try productStore.size() + line.count + 1 <= Self.maxBytes else {
                productsFull = true
                return
            }
            try productStore.append(line + Data("\n".utf8))
        } catch {
            failed += 1
            return
        }
        countedProducts = countedProducts.map { $0 + 1 } ?? countProductLines()
        send(line)
    }

    private func event(_ row: Transaction, source: CategorizationSource,
                       choice: CategoryChoice, at: Date) -> CategorizationEvent {
        let name: String? = {
            if case .category(let n) = choice { return n }
            return nil
        }()
        return CategorizationEvent(
            at: at,
            source: source,
            choice: name == nil ? "ownTransfer" : "category",
            category: name,
            merchant: row.merchant,
            merchantKey: MerchantKey.normalize(row.merchant),
            mcc: row.mcc,
            originalMcc: row.originalMcc,
            sign: row.amount < 0 ? "out" : "in",
            bankId: row.bankId,
            // Only Privat rows carry a bank word: the seed's monobank rows
            // ship a legacy `suggestions` array that means nothing, and
            // crediting the bank for it is a bug this repo has already fixed
            // once, in the queue's own chip.
            bankSuggestion: row.bankId == PrivatMapper.bankId ? row.suggestions.first : nil,
            was: row.resolution.rawValue,
            kind: row.kind.rawValue)
    }

    private func append(_ event: CategorizationEvent) {
        guard let line = try? SeedLoader.encoder.encode(event) else { return }
        do {
            guard try store.size() + line.count + 1 <= Self.maxBytes else {
                isFull = true
                return
            }
            try store.append(line + Data("\n".utf8))
        } catch {
            failed += 1
            return
        }
        // The line is already in the file, so a first-time count includes it
        // and must not also be incremented — the off-by-one that reported two
        // events after one tap.
        counted = counted.map { $0 + 1 } ?? countLines()
        send(line)
    }

    /// Fire and forget: the file is the durable copy, so no tap ever waits on
    /// a network the tester may not have. The far end routes the line by its
    /// `type`, so both channels can share one address.
    private func send(_ line: Data) {
        guard let url = webhookURL else { return }
        Task { [sender] in
            let ok = await sender.send(line, to: url)
            if ok { sent += 1 } else { failed += 1 }
        }
    }

    /// Every line written so far, for the export buttons.
    func contents() -> Data { (try? store.contents()) ?? Data() }
    func productContents() -> Data { (try? productStore.contents()) ?? Data() }

    func lineCount() -> Int {
        if let counted { return counted }
        let n = countLines()
        counted = n
        return n
    }

    func productLineCount() -> Int {
        if let countedProducts { return countedProducts }
        let n = countProductLines()
        countedProducts = n
        return n
    }

    private func countLines() -> Int { newlines(in: contents()) }
    private func countProductLines() -> Int { newlines(in: productContents()) }

    private func newlines(in data: Data) -> Int {
        data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }

    func clear() {
        try? store.clear()
        try? productStore.clear()
        counted = 0
        countedProducts = 0
        sent = 0
        failed = 0
        isFull = false
        productsFull = false
    }

    /// «Скинути додаток»: the switch goes off and the file goes with it.
    /// Leaving collection running over a wiped app would be the one setting
    /// that survived a reset, and it is the last one that should.
    func reset() {
        clear()
        isEnabled = false
        webhook = ""
    }

    /// The same erasure at launch, before any instance exists — `-resetState`
    /// builds a fresh-install app and this is part of a fresh install.
    /// `stats.bySplits` next door earned its own comment for the same reason:
    /// a `UserDefaults` key nothing wipes outlives every reset, and a UI test
    /// that leaves this one on silently changes what the next test sees.
    nonisolated static func eraseEverything(
        defaults: UserDefaults = .standard,
        store: CategorizationLogStore = CategorizationFileStore.standard(),
        productStore: CategorizationLogStore = CategorizationFileStore.products()
    ) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: webhookKey)
        try? store.clear()
        try? productStore.clear()
    }
}

/// A real append-only file, beside the app's own documents and with the same
/// protection class — the log holds merchant text, which is exactly what the
/// rest of that directory is protected for.
final class CategorizationFileStore: CategorizationLogStore {
    private let url: URL

    init(url: URL) { self.url = url }

    static func standard() -> CategorizationFileStore {
        CategorizationFileStore(url: FileRepository.standard().directory
            .appendingPathComponent("categorization.jsonl"))
    }

    /// Product groups keep their own file for the same reason they keep their
    /// own event shape: what was bought is not where the money went.
    static func products() -> CategorizationFileStore {
        CategorizationFileStore(url: FileRepository.standard().directory
            .appendingPathComponent("product-groups.jsonl"))
    }

    private func ensureFile() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    func append(_ line: Data) throws {
        try ensureFile()
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func contents() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        return try Data(contentsOf: url)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func size() throws -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }
}

/// One POST per line. No retry queue: the file already holds everything, so a
/// failed send costs a counter, not data.
struct CategorizationWebhookSender: CategorizationEventSender {
    func send(_ line: Data, to url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = line
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // Apps Script answers a `doPost` with a redirect to its own script
        // storage, which URLSession follows; anything 2xx after that is an
        // accepted line.
        return (200..<300).contains(http.statusCode)
    }
}

#endif
