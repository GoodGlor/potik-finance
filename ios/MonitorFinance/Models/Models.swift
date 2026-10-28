import Foundation

/// Codable value types only. Behaviour lives in AppStore; formatting in views.
/// Money is Int minor units, signed: in > 0, out < 0.

enum TxKind: String, Codable, Hashable { case expense, income, transfer }

/// How a row came by its category.
///
/// **`skipped` has no writer any more and must not be deleted.** Board #26
/// removed `skip`/`reopen` — dead code with no UI caller — but this is a
/// PERSISTED raw value, and removing the case is not the same size of change
/// as removing the methods: `Transaction`'s synthesised `Decodable` would
/// throw on any stored row carrying `"resolution":"skipped"`, and
/// `AppStore.init` loads with `try?`, so one such row silently discards the
/// WHOLE transactions file and falls back to the seed. Every categorisation
/// the owner ever made, gone, with no error anywhere.
///
/// It costs one enum case to be sure that cannot happen. A row that has it
/// reads «пропущено» on the detail screen and is not counted as pending,
/// which is what it always meant.
enum Resolution: String, Codable, Hashable { case rule, pattern, transfer, user, pending, skipped }

struct Split: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var amount: Int
    var category: String
}

struct Transaction: Identifiable, Codable, Hashable {
    var id: UUID
    var date: Date
    var kind: TxKind
    var category: String
    var merchant: String
    var amount: Int
    var cardSuffix: String
    var bankId: String
    var receiptId: UUID?
    var splits: [Split]
    var resolution: Resolution
    /// Three category suggestions for the queue; empty unless `.pending`.
    var suggestions: [String]
    /// monobank's own id for this row — the identity a re-fetch matches on.
    /// `nil` for demo rows, which is how the seed-clearing sweep finds them.
    ///
    /// Optional is load-bearing, not stylistic: Swift's synthesised `Codable`
    /// throws `keyNotFound` for a missing key rather than using the memberwise
    /// default, and an Optional is the one exception. Non-optional here would
    /// make every `transactions.json` already on a device fail to decode.
    var externalId: String?
    /// Pending — the amount can still change on settlement, so a forward sync
    /// deliberately re-reads the last three days rather than starting where it
    /// stopped. Optional for the same decoding reason as `externalId`.
    var hold: Bool?
    /// The card network's merchant category code, as the bank sent it. Stored
    /// and, for now, displayed nowhere: it is the single most predictive input
    /// a later categorizer will have, and a row synced without it can never be
    /// backfilled — monobank's statement window is 31 days.
    ///
    /// It is a bank-authored fact about the merchant, NOT a spending category:
    /// nothing may read it as one until a card says how. `nil` for every Privat
    /// statement row (the export has no such column) and for every demo row.
    /// Optional and defaulted for the same decoding reason as `externalId`.
    var mcc: Int? = nil
    /// The same code before the bank rewrote it, when the two disagree.
    ///
    /// monobank re-codes some rows: the corpus has `mcc 7829` against
    /// `originalMcc 4899` on one subscription, and 4899 is the one that
    /// describes the shop. 15 of its 111 rows are recoded, three of them
    /// domestic — see `MonobankStatementItem.originalMcc`. Stored for the same
    /// reason as `mcc` and under the same rules: displayed nowhere, never read
    /// as a spending category, unbackfillable once the 31-day window closes.
    ///
    /// `nil` whenever the bank sent no such key, which is every Privat
    /// statement row and every demo row. Optional and defaulted for the same
    /// decoding reason as `externalId`.
    var originalMcc: Int? = nil
    /// The card's running balance immediately after this row, in minor units.
    ///
    /// Written only by the two PrivatBank sources and read only by
    /// `PrivatCrossSource`: it is half of the one identity the statement
    /// export and the notification letter can be made to agree on. Nothing
    /// displays it, and no total may be derived from it — a balance is a
    /// snapshot of one card, and the app holds rows from several.
    ///
    /// `nil` for every monobank row, every demo row, and for the rare Privat
    /// row that carries no balance (interest). A nil here means "this row has
    /// no cross-source identity", which is exactly what the matcher needs to
    /// be told. Optional and defaulted for the same decoding reason as
    /// `externalId`.
    var balanceAfterMinor: Int? = nil
}

enum BankStatus: String, Codable, Hashable {
    case available, comingSoon, statement

    /// `banks.json` is loaded with `try?` and a whole-array fallback. This
    /// `init(from:)` ships in THIS build, so it is not protecting some
    /// older binary already in the field — it protects this build (and
    /// every one after it) against a raw value a FUTURE build adds: without
    /// it, that future value's `banks.json` would fail to decode on this
    /// build and silently reset every bank to the seed while tokens stay in
    /// Keychain. Unknown therefore decodes as the inert case instead of
    /// throwing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BankStatus(rawValue: raw) ?? .comingSoon
    }
}

struct Account: Identifiable, Codable, Hashable {
    var id: String
    var suffix: String
    var type: String
    var currency: String
    var balance: Int
    var creditLimit: Int?
    /// `false` = the user turned this card off for sync. Optional for the
    /// same decoding reason as `externalId` on `Transaction`: every
    /// `banks.json` already on a device has no such key, and `nil` must
    /// mean "enabled", the behavior those devices already have.
    var syncEnabled: Bool? = nil
}

struct Bank: Identifiable, Codable, Hashable {
    var id: String
    var displayName: String
    var status: BankStatus
    var connected: Bool
    var accounts: [Account]
}

extension Bank {
    /// The one bank with a live API behind it, and therefore the only one
    /// `SyncEngine` and `syncState` are ever about. Board #165 named it,
    /// because the id had been spelled as a bare `"monobank"` in the sync
    /// entry point and in the disconnect path, and those two literals having
    /// to agree is exactly the kind of thing that stops being true quietly.
    ///
    /// `PrivatMapper.bankId` beside it is the same idea for the other bank.
    static let monobankId = "monobank"

    /// PrivatBank is the one bank with two ways in — a forwarded notification
    /// letter and an exported statement — so it is the one bank whose picker
    /// row has to ask which. Board #91.
    ///
    /// Keyed on the ID rather than on `.status`: a second `.statement` bank
    /// would have a file to import and no email backend behind it, and a
    /// two-way choice would promise it a source that does not exist.
    var hasEmailSource: Bool { id == PrivatMapper.bankId }
}

enum IncomeBase: Codable, Hashable {
    /// `includeGifts` belongs to the average, not to the budget as a whole:
    /// a fixed sum the user typed is not filtered by anything.
    case average(months: Int, includeGifts: Bool)
    case fixed(Int)
}

struct Budget: Codable, Hashable {
    var incomeBase: IncomeBase
    var lines: [Line]
    /// The month this plan was written FOR. Board #62.
    ///
    /// There used to be exactly one plan, and every month — past, present,
    /// browsed — was measured against it. So a plan carries the month it
    /// starts applying from, and `AppStore.plan(for:)` reads "the newest plan
    /// written on or before that month".
    ///
    /// **`nil` means "written before this field existed", and is in force for
    /// every month.** That is not a fallback chosen for tidiness: it is
    /// exactly the behaviour the build before #62 had, so a plan already on
    /// somebody's phone keeps measuring the same months against the same
    /// numbers, and nothing they have looked at changes under them.
    /// Optional and defaulted for the same decoding reason as
    /// `Transaction.externalId`.
    var month: MonthKey? = nil
    /// Board #114 — **which banks this plan is about**. `nil` means all of
    /// them.
    ///
    /// The owner's decision, and the alternative it beat: ONE plan with a
    /// bank scope, not a plan per bank. Separate plans would multiply every
    /// board #94 concept — income base, category kinds, the month a plan
    /// belongs to — by the number of banks, and the person would then own N
    /// plans that can disagree about what a month's income was.
    ///
    /// A scope is therefore a FILTER on the rows a plan is measured against,
    /// and nothing else. That is what keeps `BudgetMath` kind-driven: the
    /// filter is applied to the transactions before they arrive, so no
    /// function in there ever asks which bank a row came from.
    ///
    /// `nil`, not an empty array, for "everything" — and both are treated the
    /// same way by `scoped(_:)`, because a plan scoped to no banks at all
    /// would measure a month against nothing and read as a bug rather than a
    /// choice. Optional and defaulted for the same decoding reason as
    /// `month`: every plan already on a phone decodes to "all banks", which
    /// is exactly what it has always meant.
    var banks: [String]? = nil

    /// The rows this plan is about.
    ///
    /// Called at the top of `BudgetMath.monthlyIncome` and `report` rather
    /// than by their callers: a filter every caller has to remember is a
    /// filter one of them forgets, and the one that forgot would silently
    /// measure a scoped plan against every bank's spending.
    func scoped(_ txs: [Transaction]) -> [Transaction] {
        guard let banks, !banks.isEmpty else { return txs }
        let allowed = Set(banks)
        return txs.filter { allowed.contains($0.bankId) }
    }

    struct Line: Identifiable, Codable, Hashable {
        var id: UUID
        var category: String
        /// Fractional, so a line can hold an exact ₴ figure the user typed:
        /// on a 46 697 ₴ income one whole percent is 467 ₴, and rounding an
        /// amount to that grid means 5 000 ₴ is not a value you can ask for.
        /// A whole percent still encodes as `30`, so a plan written when this
        /// was an `Int` decodes unchanged — the one thing that keeps the
        /// widening safe, and the only migration this repo has. Pinned by
        /// `BudgetMathTests.testAPlanWrittenWhenPercentsWereIntegersStillDecodes`.
        var percent: Double
    }
}

extension Budget {
    /// The plan offered on first open. A starting point to edit, not a
    /// recommendation — the editor's copy says so out loud. Fresh UUIDs each
    /// call so two starter plans never share line identity.
    static func starter() -> Budget {
        // Board #23: the fourth line was «Кредит — 30%», which told a person
        // with no loan that a third of their money was already spoken for by
        // a debt they do not have. Three lines nobody escapes instead — a
        // roof, food, and something kept back.
        //
        // «Квартплата», not the card's «Оренда»: the seed ships nineteen
        // categories and «Оренда» is not one of them, so a starter naming it
        // would CREATE a twentieth on the first save — the taxonomy fork that
        // boards #14 and #15 exist to prevent. «Квартплата» is this app's word
        // for the same line, and `testTheStarterPlanNamesOnlyCategoriesThe\
        // SeedAlreadyShips` is what holds that.
        Budget(incomeBase: .average(months: 3, includeGifts: false), lines: [
            .init(id: UUID(), category: "Квартплата", percent: 45),
            .init(id: UUID(), category: "Продукти", percent: 35),
            .init(id: UUID(), category: BudgetMath.savingsCategory, percent: 20),
        ])
    }
}

struct Receipt: Identifiable, Codable, Hashable {
    var id: UUID
    var scannedAt: Date
    var registerNumber: String
    var documentNumber: String
    var fiscalTime: Date
    var fiscalSum: Int
    var sellerName: String
    var items: [Item]
    struct Item: Identifiable, Codable, Hashable {
        var id: UUID
        var name: String
        var qty: Double
        var price: Int
        var sum: Int
        var category: String?
    }

    /// The cash register's model and firmware (`NDv`), not a schema version —
    /// it reads as a device name string. Optional for two reasons: a
    /// `receipts.json` written before this field existed must still decode,
    /// and at least one real receipt carries no `NDv` at all.
    var registerModel: String? = nil
    /// When the goods themselves arrived, as distinct from when the receipt
    /// was scanned (`scannedAt`). `nil` while `items` is still a placeholder
    /// — an empty array alone cannot tell "the goods have not arrived yet"
    /// apart from "this receipt genuinely has no lines", so this field carries
    /// that distinction instead. Optional so an old `receipts.json` decodes.
    var itemsLandedAt: Date? = nil
    var isWaitingForItems: Bool { itemsLandedAt == nil }

    /// Set when the fetched document's `<MAC>` disagreed with the scanned
    /// QR's control number (`ReceiptBuilder.macMatches` returned `false`).
    /// Diagnostic only — nothing in the app reads or branches on this field.
    /// The fetch that landed this receipt's goods already matched on
    /// id+fn+sm+date, the endpoint's own lookup key, so a `<MAC>` mismatch is
    /// far more likely a `<MAC>` encoding difference between register
    /// vendors (one captured vendor ships hex where the other seven ship
    /// base64, and no capture in this repo carries a QR to check that
    /// vendor's encoding against) than evidence the document is wrong.
    /// Treating it as a reason to withhold or retry the fetch would strand a
    /// receipt for 48h and then tell the user the tax service never
    /// published a receipt it published fine. `Bool?`, not `Bool`, so an old
    /// `receipts.json` — written before this field existed — still decodes;
    /// a synthesized `Decodable` only skips a missing key for an Optional
    /// property, never for a non-Optional one with a default value. `nil`
    /// and `false` both mean "no mismatch recorded"; nothing distinguishes
    /// them.
    var controlNumberMismatch: Bool? = nil

    /// What to call this receipt on screen. Three views spelled the fallback
    /// themselves and could have drifted apart; and it is not an edge case —
    /// the decoder is mocked, so EVERY receipt scanned on a real device has
    /// an empty seller today.
    var displaySeller: String { sellerName.isEmpty ? "Чек розпізнано" : sellerName }
}

/// What a category MEANS to the budget — board #94.
///
/// Three cases rather than two, because the app already distinguishes three
/// behaviours and a two-case enum would have to lie about one of them: a gift
/// is money coming in that no plan should be built on. Three cases rather than
/// a kind plus an `isEarned` flag, because two fields admit a fourth
/// combination — "spending, but earned" — that means nothing, and nothing
/// would stop a caller writing it.
enum CategoryKind: String, Codable, Hashable, CaseIterable {
    /// Money going out. What a category is unless somebody says otherwise.
    case spending
    /// Money in that the plan is a percentage OF.
    case earned
    /// Money in that no plan is built on — «Подарунки». Offered on an income
    /// row and excluded from the income base, which is exactly what
    /// `income(_:includeGifts:)`'s two answers have always meant.
    case unearned
}

struct Category: Identifiable, Codable, Hashable {
    var name: String
    var tintIndex: Int?
    /// An SF Symbol name, board #61. Optional for the reason every persisted
    /// field here is: Swift's synthesised `Decodable` throws `keyNotFound`
    /// rather than using a memberwise default, and `AppStore.init` loads this
    /// file with a whole-file fallback — so one non-Optional field would
    /// silently lose every category a person has.
    ///
    /// Read through `iconName`, never directly: nil is a category the app has
    /// no opinion about, not a category with nothing to draw.
    var icon: String?
    /// What this category means to the budget — board #94. Optional for the
    /// reason every persisted field here is (see `icon`), and read through
    /// `resolvedKind`, never directly: nil means "written before this field",
    /// not "spending".
    var kind: CategoryKind? = nil
    var id: String { name }

    /// What to draw. Board #61's third criterion — a category with no icon
    /// still renders — lives here rather than at each of the four draw sites.
    var iconName: String { icon ?? CategoryIcon.fallback }

    /// Ukrainian alphabetical order.
    ///
    /// `sorted()` compares UNICODE SCALARS, and Cyrillic's code points are not
    /// its alphabet: І (U+0406) and Ї (U+0407) sit below А (U+0410), so
    /// «Інтернет» opened the list and «Інші надходження» came second, above
    /// «Автомобіль». Nobody looking for a category alphabetically finds it in a
    /// list that starts at І.
    ///
    /// The locale is named rather than taken from the device: the app's
    /// vocabulary is Ukrainian whatever language the phone is set to, and a
    /// test asserting an order must get the same answer on every machine.
    ///
    /// On the MODEL rather than on the picker: three screens list these names —
    /// the picker, Налаштування → Категорії and the feed's filter sheet — and a
    /// helper living on one of them would have left the other two opening at
    /// «Інші надходження».
    static func alphabetical(_ names: [String]) -> [String] {
        // Stays Ukrainian whatever the interface language, because what it
        // sorts is Ukrainian: category names are the person's data and are
        // not translated (board #85). Collating «Інтернет» with an English
        // locale puts it back where board #25 found it.
        let uk = Locale(identifier: "uk_UA")
        return names.sorted {
            $0.compare($1, options: [.caseInsensitive], range: nil, locale: uk) == .orderedAscending
        }
    }
}

extension Category {
    /// What this category means, for a category that may predate the field.
    ///
    /// **The one place name-matching survives, and deliberately.** Before
    /// board #94 the answer WAS the name, so a category stored by an older
    /// build has no other truth to recover — and resolving it any other way
    /// would silently re-base the budget of every device already out there on
    /// the day it upgrades. Anything created since carries its own answer and
    /// never reaches the table below.
    var resolvedKind: CategoryKind { kind ?? CategoryKind.legacy(for: name) }
}

extension CategoryKind {
    /// The hardcoded answer board #94 removed, kept only for categories
    /// written before the field existed. NOT a fallback for new ones:
    /// `AppStore.addCategory` takes a kind and always stores it.
    static func legacy(for name: String) -> CategoryKind {
        switch name {
        case "Зарплата", "Стипендія", "Інші надходження": .earned
        case "Подарунки": .unearned
        default: .spending
        }
    }
}

struct Rule: Identifiable, Codable, Hashable {
    var merchantKey: String
    var category: String?
    var ambiguous: Bool
    /// Set when the rule says "this merchant is not spending" — `.transfer`.
    /// `nil` is an ordinary category rule. Optional so a `rules.json` written
    /// before this field still decodes; a non-optional `TxKind` would throw
    /// `keyNotFound` and silently reset every rule the user has taught.
    var kind: TxKind?
    /// The kind of row this rule was learned from. `nil` means "any kind" —
    /// which is right for a transfer rule (a merchant that moves money is
    /// moving it whichever direction the sign points) and for the seeded
    /// rules, which predate the distinction.
    var scope: TxKind?

    /// **The merchant AND the scope, board #81.** A rule used to be identified
    /// by its merchant alone, so a merchant that both pays and charges — a
    /// marketplace, an employer who also sells — could hold only one answer.
    /// Teaching «Зарплата» for its income and later «Послуги» for its expense
    /// did not give two rules: the second contradicted the first, and both
    /// were replaced by "ask every time", destroying an answer that was right.
    ///
    /// **No migration.** Every rule already on a phone carries either `nil` or
    /// a scope, and there has never been more than one per merchant, so each
    /// of them is already unique under the wider key and keeps working
    /// untouched. What changes is that a second one can now exist beside it.
    ///
    /// The separator is `|`, which `MerchantKey.normalize` cannot produce in
    /// the raw-value half — `TxKind`'s raw values are bare words — so the two
    /// halves can never run together into a third rule's id.
    var id: String { "\(merchantKey)|\(scope?.rawValue ?? "")" }
}

extension Array where Element == Rule {
    /// The rule that governs a row of `kind` for this merchant.
    ///
    /// **Precedence is the whole point, and it is not `first(where:)`.** A
    /// merchant can now hold a scoped rule and an unscoped one at the same
    /// time — the unscoped one seeded before board #81 drew the distinction,
    /// or written by `markNotAnExpense`, which scopes to nothing deliberately.
    /// The more specific answer must win, and array order is not a
    /// specification: `rules` is appended to in the order a person happened to
    /// answer, and a plain `first` would hand back whichever that was.
    func governing(_ merchantKey: String, kind: TxKind?) -> Rule? {
        first { $0.merchantKey == merchantKey && $0.scope == kind && kind != nil }
            ?? first { $0.merchantKey == merchantKey && $0.scope == nil }
    }
}

struct Settings: Codable, Hashable {
    var onboarded: Bool = false
    var faceIdEnabled: Bool = false

    /// When the user started using the app. Divides purchases it should ask
    /// about from spending that happened before it existed. Optional because a
    /// build from before stage 5 wrote no such field — and because "no stamp"
    /// must mean "nothing queues", never "everything queues".
    var startedUsingAt: Date? = nil

    /// «Блокувати одразу»: ask for the code on every single return, instead of
    /// letting `AppStore.lockGrace` cover a minute away. Board #21.
    ///
    /// Optional for the same reason `startedUsingAt` is: a settings file
    /// written before this field existed must still decode, and Swift's
    /// synthesised `Decodable` throws on a missing key for a non-Optional
    /// property whatever default the declaration carries. Read
    /// `locksImmediately`, never this.
    var lockImmediately: Bool? = nil

    /// The default is the GRACE, not the immediate lock: the app's own core
    /// flow sends a person to Приват24 for a statement, and locking behind
    /// them made the app's own instructions cost a Face ID.
    var locksImmediately: Bool { lockImmediately ?? false }

    /// «Як у системі» / «Світла» / «Темна». Board #58. Optional and read
    /// through `appearanceChoice`, for the same reason as `lockImmediately`.
    var appearance: Appearance? = nil
    /// The interface language. Optional for the same decoding reason as every
    /// other persisted field here; read through `languageChoice`.
    var language: AppLanguage? = nil

    /// nil means follow the system, which is the default the card asks for and
    /// the behaviour every settings file already on a device will get.
    var appearanceChoice: Appearance { appearance ?? .system }
    var languageChoice: AppLanguage { language ?? .system }

    /// When the short guide was last dismissed. Board #60. Optional for the
    /// same decoding reason as everything else here, and a DATE rather than a
    /// flag so it also answers "how long ago" if anything ever wants to.
    ///
    /// nil means it has not been seen — including on a device that onboarded
    /// before the guide existed. That is deliberate: the guide is about the
    /// app they already have, it costs one tap to close, and the alternative
    /// is that the only person actually using this app never sees the thing
    /// they asked for.
    var guideSeenAt: Date? = nil

    var hasSeenGuide: Bool { guideSeenAt != nil }
}

/// What the app's colour scheme follows. Board #58.
///
/// The `ColorScheme` mapping and the Ukrainian titles are in `Theme.swift`,
/// not here: this file is Codable value types, and importing SwiftUI into it
/// to name one enum case would be the first crack in that.
/// Which language the interface is written in.
///
/// **The interface only.** Category and product-group names are DATA — a
/// transaction, a rule and a budget line all reference a category by its name,
/// and the person can rename it — so «Продукти» stays «Продукти» in English.
/// The literals `PrivatMapper`, `PrivatStatementParser` and `FuelGrade` match
/// on are not copy either: they are the Ukrainian text PrivatBank and the tax
/// service actually send, and translating them would break the importer with
/// nothing on screen to show for it.
enum AppLanguage: String, Codable, Hashable, CaseIterable {
    case system, uk, en

    /// Same protection as `Appearance`, and for the same reason — see there.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppLanguage(rawValue: raw) ?? .system
    }
}

enum Appearance: String, Codable, Hashable, CaseIterable {
    case system, light, dark

    /// Same protection `BankStatus` carries, and for the same reason: this is
    /// a PERSISTED raw value inside `settings.json`, which `AppStore.init`
    /// loads and falls back from wholesale. A build that one day adds a fourth
    /// case would write a word this build cannot decode — and without this
    /// initialiser that would throw, taking the whole settings file with it
    /// and sending the person back through onboarding. Unknown means follow
    /// the system.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Appearance(rawValue: raw) ?? .system
    }
}
