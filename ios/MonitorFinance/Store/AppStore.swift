import Foundation
import Observation

/// The one source of truth for the UI. Views read it from the environment and
/// call named mutations; they never poke the arrays. Every mutation schedules
/// a debounced persist so the UI never waits on disk.
@Observable
final class AppStore {
    var transactions: [Transaction]
    var banks: [Bank]
    var categories: [Category]
    var rules: [Rule]
    var receipts: [Receipt]
    /// Receipts scanned but not yet resolved — waiting on the tax cabinet for
    /// their goods, or already fetched and waiting on a match. `ReceiptFetcher`
    /// (task 11) drains this; nothing else reads the tax cabinet.
    var receiptQueue: [PendingReceipt]
    /// `private(set)` so the compiler, not a convention, enforces what the
    /// doc comment on `setBudget` claims: that mutation is the only writer.
    /// A view assigning here would skip the category creation `setBudget`
    /// does and the persist it schedules.
    private(set) var budget: Budget?
    /// Plans that are no longer the current one, each stamped with the month
    /// it was written for. Board #62.
    ///
    /// A second collection rather than a `[MonthKey: Budget]` replacing
    /// `budget`: the dictionary would have meant a new shape for `budget.json`,
    /// which `AppStore.init` loads with a fallback — so every plan already on
    /// a device would have failed to decode and quietly vanished. This is a
    /// NEW file instead, and a missing one is simply an empty array.
    private(set) var budgetHistory: [Budget] = []
    /// Board #148 — the statement files that were imported, newest last.
    ///
    /// `private(set)` for the same reason `budget` is: the record and the rows
    /// it names have to be written together, and a view assigning here would
    /// leave a list describing transactions that were never added. `recordImport`
    /// and `deleteStatementImport` are the only writers.
    ///
    /// A NEW file, like `budgetHistory` before it: a missing one is an empty
    /// array, so every device that already has data reads back correctly and
    /// simply has no history before today.
    private(set) var statementImports: [StatementImport] = []
    var settings: Settings
    /// Cursors, depth and the client hash. Written by `ingest` together with
    /// the rows it commits — see `AppStore+Sync`.
    var syncState = SyncState()

    /// Unlocked for this foreground session. Never persisted: backgrounding
    /// the app is what clears it.
    var isUnlocked = false

    /// When the app was last backgrounded from an unlocked state, or nil.
    ///
    /// **Never persisted, deliberately.** A cold start locks however recent
    /// the stamp was: the grace exists to cover a trip to Приват24 with the
    /// process still alive, not to survive being force-quit and reopened.
    private(set) var backgroundedAt: Date?

    /// How long a return may skip the code for. Board #21 asked for 30–60 s;
    /// a minute is the top of that range because the thing being covered — go
    /// to another app, find the statement, share it back — is a slow errand,
    /// and half a minute of it is easy to spend on the sharing sheet alone.
    static let lockGrace: TimeInterval = 60

    /// True while a sync run is in flight. Never persisted.
    var isSyncing = false

    /// Same shape as `isSyncing`, one host over: true while `syncPrivatEmail`
    /// is in flight, so a second trigger (foreground activation racing a
    /// background wake) finds a run already going instead of firing a
    /// second `/transactions` page request. Never persisted.
    var isEmailSyncing = false

    /// The one PIN store in the app. Views must go through this rather than
    /// constructing their own: four independent `PinStore()` instances used
    /// to exist, each hardcoding `Keychain.app` and so bypassing the keychain
    /// injected here — which is exactly why no single place owned the answer
    /// to "is a PIN set", and why a failed write could strand a user behind a
    /// lock no PIN would open.
    @ObservationIgnored let pinStore: PinStore

    @ObservationIgnored private let repository: Repository
    @ObservationIgnored private(set) var keychain: Keychain
    @ObservationIgnored private let seedBanks: [Bank]

    /// The bank. `MonobankClient` in Release; a canned stub under
    /// `-stubMonobank`, which is the only reason the UI suite can run at all.
    @ObservationIgnored let api: MonobankAPI

    /// The email backend (task 3). `PrivatEmailClient` in Release; a canned
    /// stub under `-stubPrivatEmail` — selected in `AppStore.live()` the same
    /// way `api` is.
    @ObservationIgnored let emailAPI: PrivatEmailAPI

    /// The tax cabinet `ReceiptFetcher` (task 11) asks for a receipt's goods.
    /// `TaxCabinetClient` in Release; `TaxCabinetStub` under `-stubTaxCabinet`
    /// — selected in `AppStore.live()` the same way `api` is. Stored (rather
    /// than constructed fresh in `makeReceiptFetcher`) so a test can inject a
    /// gated fake the same way it injects `api`.
    @ObservationIgnored let taxCabinetAPI: TaxCabinetAPI

    /// One `SyncEngine` per process, not one per call — see `startSync`. The
    /// 61-second pacer is instance state, so a fresh engine on every call
    /// would forget it and risk a 429 nothing could prevent.
    @ObservationIgnored var syncEngine: SyncEngine?

    /// Which dataset the running sync belongs to. `makeSyncEngine` captures
    /// this value in the closures it hands the engine, and every closure that
    /// WRITES checks it before touching anything — so a window fetched for a
    /// dataset that has since been wiped is dropped instead of committed.
    ///
    /// A counter rather than a cancelled `Task` because cancellation is
    /// cooperative and this boundary is an actor's: `SyncEngine.run` reads the
    /// token once into a local before its loop, so an emptied Keychain does
    /// not stop it, and a `commit` already in flight lands whatever a
    /// cancellation flag says. Reading it costs nothing on the main actor,
    /// which is where every one of those closures already hops.
    @ObservationIgnored private(set) var syncGeneration = 0

    /// One `ReceiptFetcher` per process, not one per call — the same reason
    /// `syncEngine` is: the 3-second pacer and the hour-long stand-down are
    /// both instance state, so a fresh actor per call would forget both and
    /// risk sending two requests back to back, or walking straight past a
    /// stand-down the previous run just entered.
    @ObservationIgnored var receiptFetcher: ReceiptFetcher?

    /// The same shape as `syncGeneration`, one host over: `ReceiptFetcher`
    /// (task 11) is also an actor parked inside a network request — a
    /// tax-service one rather than a bank one — that cannot be cancelled from
    /// here either. Both wipes bump this before clearing `receiptQueue`, so a
    /// fetch already in flight for the dataset just wiped finds
    /// `isCurrentReceiptFetch` false on its next `commit`/`fail` and drops
    /// what it was about to write instead of landing it in — or losing it
    /// from — the dataset that replaced it.
    @ObservationIgnored private(set) var receiptGeneration = 0

    /// Narrows the next `startSync` call to one account — the background
    /// wake's "one wake, one card" budget (see `BackgroundRefresh`). `nil`,
    /// the normal case, leaves every UAH account eligible. Never persisted:
    /// it is a one-shot instruction for the run that reads it, not state.
    @ObservationIgnored var syncOnlyAccount: String?

    /// The bundled sample catalogue, exactly as `demo.json` ships it, and never
    /// written to afterwards.
    ///
    /// Deliberately NOT `receipts`: that array is the user's own attached
    /// receipts and `attach` appends to it, so a scanner fed from it would
    /// offer every receipt ever attached as a further "sample" — on a device,
    /// a real QR's seller-less, item-less record — and would let the decoder
    /// treat a real fiscal check number as a known sample.
    @ObservationIgnored let sampleReceipts: [Receipt]
    /// The product taxonomy, exactly as `reference.json` ships it — `app/core/products.py`
    /// stays the one source of truth, this is just where the app reads it from.
    ///
    /// **Read `productGroups`, not this.** The person's own groups live in
    /// `customProductGroups` and the composed list is what every screen wants.
    @ObservationIgnored let seedProductGroups: [ProductGroup]

    /// The groups this person invented, and ONLY those. Board #184.
    ///
    /// **Not the composed taxonomy, deliberately.** Persisting all twenty-one
    /// seeded groups alongside the additions would have been one line shorter
    /// and would have frozen the taxonomy on the day somebody first added a
    /// group: `reference.json` is regenerated from `app/core/products.py`, and
    /// a saved copy shadowing it means a later build's new keywords never
    /// reach a phone that has one custom group on it. Saving only the
    /// additions keeps the seed live and makes the file's meaning obvious —
    /// everything in it is the person's own work.
    private(set) var customProductGroups: [ProductGroup] = []

    /// What the pickers and `ProductGuess` read: the shipped taxonomy with the
    /// person's own groups folded in.
    ///
    /// **«Інше» stays last.** It is the final element of the seed and the
    /// answer that means "none of the above", so custom groups are inserted
    /// BEFORE it rather than appended after. `ProductGroupPicker.matches`
    /// never re-sorts precisely so this order survives to the screen; an
    /// append here would have put «Інше» mid-list on every phone that has a
    /// custom group, which is the bug that comment exists to prevent.
    var productGroups: [ProductGroup] {
        guard !customProductGroups.isEmpty else { return seedProductGroups }
        guard let other = seedProductGroups.firstIndex(where: { $0.name == ProductGuess.other })
        else { return seedProductGroups + customProductGroups }
        var composed = seedProductGroups
        composed.insert(contentsOf: customProductGroups, at: other)
        return composed
    }
    @ObservationIgnored private var persistTask: Task<Void, Never>?

#if DEBUG
    @ObservationIgnored private var madeCategorizationLog: CategorizationLog?

    /// Training data for a categorizer that does not exist yet. Off until a
    /// person turns it on; absent entirely from Release.
    ///
    /// Made on first use rather than in `init`: the log is main-actor
    /// isolated and `AppStore.init` is not, and a store built by a unit test
    /// that never categorises anything should not construct one at all.
    /// Settable, so a test can hand it an in-memory file without every
    /// caller of `init` learning the parameter exists.
    @ObservationIgnored var categorizationLog: CategorizationLog {
        get {
            MainActor.assumeIsolated {
                if let madeCategorizationLog { return madeCategorizationLog }
                let made = CategorizationLog()
                madeCategorizationLog = made
                return made
            }
        }
        set { madeCategorizationLog = newValue }
    }
#endif

    /// Undo is a foreground-session affordance, not history: it is deliberately
    /// not persisted, so relaunching never resurrects a "Скасувати" for a
    /// decision made yesterday.
    @ObservationIgnored var undoStack: [UndoEntry] = []

    /// Documents that EXISTED at launch and did not decode. Board #68.
    ///
    /// A missing file and a corrupt one used to be the same event here: every
    /// load is `try?` with a fallback to the seed, and `Repository.load`
    /// returns nil for a missing document but THROWS for one it cannot read.
    /// One of those is a fresh install; the other is somebody's history going
    /// quiet. They looked identical and neither said anything.
    ///
    /// Not persisted. It describes this launch, and the next launch either
    /// reads the file or reports it again — a stored copy could only go stale.
    private(set) var loadFailures: [String] = []

    /// What a person should be told a file held, in their own words. The raw
    /// names are storage keys and mean nothing to anybody reading a screen.
    ///
    /// A `default` rather than an exhaustive switch, deliberately: a new
    /// document must not make this fail to compile in a way somebody fixes by
    /// pasting a name in. It falls back to the key, which is ugly on screen
    /// and therefore gets noticed and named properly. `AppStoreTests` pins
    /// that every name the store actually loads has an entry.
    static func fileTitle(_ name: String) -> String {
        switch name {
        case "transactions": "операції"
        case "banks": "банки й картки"
        case "categories": "категорії"
        case "rules": "правила категоризації"
        case "receipts": "чеки"
        case "receiptQueue": "чеки, що завантажуються"
        case "budget": "план бюджету"
        case "budgetHistory": "плани попередніх місяців"
        case "statementImports": "імпортовані виписки"
        case "productGroups": "власні товарні групи"
        case "settings": "налаштування"
        case "sync": "стан синхронізації"
        default: name
        }
    }

    /// One load, with the two failures told apart.
    ///
    /// Static because `init` calls it before every stored property has a
    /// value, and an instance method there is not available. The quarantine
    /// is the load-bearing half — see `Repository.quarantine`.
    private static func load<T: Decodable>(_ name: String, as type: T.Type,
                                           from repository: Repository,
                                           failures: inout [String]) -> T? {
        do {
            return try repository.load(name, as: type)
        } catch {
            failures.append(name)
            try? repository.quarantine(name)
            return nil
        }
    }

    /// `pinStore` defaults to one built on the *injected* keychain — a Swift
    /// default argument cannot reference another argument, so it is resolved
    /// here instead. Tests therefore get a test-scoped PIN for free.
    init(repository: Repository, seed: SeedBundle, keychain: Keychain = .app,
         pinStore: PinStore? = nil, api: MonobankAPI = MonobankClient(),
         taxCabinetAPI: TaxCabinetAPI = TaxCabinetClient(),
         emailAPI: PrivatEmailAPI = PrivatEmailClient()) {
        self.repository = repository
        self.keychain = keychain
        self.pinStore = pinStore ?? PinStore(keychain: keychain)
        self.api = api
        self.taxCabinetAPI = taxCabinetAPI
        self.emailAPI = emailAPI
        self.seedBanks = seed.banks
        self.sampleReceipts = seed.receipts
        self.seedProductGroups = seed.productGroups
        // `Self.load` rather than `try?`, so a file that exists and does not
        // decode is recorded and moved aside instead of being fallen back
        // from in silence — board #68. The fallbacks themselves are unchanged:
        // the app still opens, and still opens on the seed.
        var failures: [String] = []
        transactions = Self.load("transactions", as: [Transaction].self,
                                 from: repository, failures: &failures) ?? seed.transactions
        banks = Self.load("banks", as: [Bank].self,
                          from: repository, failures: &failures) ?? seed.banks
        categories = Self.load("categories", as: [Category].self,
                               from: repository, failures: &failures) ?? seed.categories
        rules = Self.load("rules", as: [Rule].self,
                          from: repository, failures: &failures) ?? seed.rules
        receipts = Self.load("receipts", as: [Receipt].self,
                             from: repository, failures: &failures) ?? seed.receipts
        // No seed fallback: the queue is purely runtime state, nothing a
        // bundled catalogue ever ships.
        receiptQueue = Self.load("receiptQueue", as: [PendingReceipt].self,
                                 from: repository, failures: &failures) ?? []
        budget = Self.load("budget", as: Budget.self, from: repository, failures: &failures)
        // No seed fallback: superseded plans are the person's own history and
        // a bundled catalogue never ships any.
        budgetHistory = Self.load("budgetHistory", as: [Budget].self,
                                  from: repository, failures: &failures) ?? []
        // No seed fallback: a bundled catalogue ships no import history, and
        // an absent file is simply a device that has never imported one.
        statementImports = Self.load("statementImports", as: [StatementImport].self,
                                     from: repository, failures: &failures) ?? []
        // No seed fallback, and that is the point: an absent file means this
        // person has invented no groups, not that they should be handed the
        // seed a second time. The seed reaches them through
        // `seedProductGroups`, which never goes to disk.
        customProductGroups = Self.load("productGroups", as: [ProductGroup].self,
                                        from: repository, failures: &failures) ?? []
        settings = Self.load("settings", as: Settings.self,
                             from: repository, failures: &failures) ?? Settings()
        syncState = Self.load("sync", as: SyncState.self,
                              from: repository, failures: &failures) ?? SyncState()
        loadFailures = failures

        // Status and display name are the APP's knowledge, not the user's
        // data — a persisted banks.json must not pin privatbank to the
        // status it had when that file was first written.
        for i in banks.indices {
            if let seeded = seedBanks.first(where: { $0.id == banks[i].id }) {
                banks[i].status = seeded.status
                banks[i].displayName = seeded.displayName
            }
        }

        // Board #57. Runs on every install exactly once — `tintIndex` has been
        // in the model since the beginning and nothing ever wrote it, so every
        // category everywhere arrives here with none. Written straight through
        // rather than via `persist()`: the debounce is a 300 ms timer, and a
        // person who launches and immediately force-quits would come back to
        // a different set of colours.
        // Board #85. Before anything formats a date or an amount, and from
        // the value just loaded — a launch that read the setting and then
        // formatted with the previous default would show the first screen in
        // one language and everything after it in another.
        L10n.setFormatting(settings.languageChoice)

        let tinted = Self.assigningMissingTintIndexes(categories)
        if tinted != categories {
            categories = tinted
            try? repository.save(categories, as: "categories")
        }

        // Board #149. After the tint pass, because a fold can remove a
        // category and the colour it carries has to have been assigned first.
        // Idempotent, so a launch that never gets to persist just does it
        // again — which is why this one does not need #57's write-through.
        foldDuplicateCategories()

        // A user who onboarded before stage 5 has no stamp, and a nil stamp
        // queues nothing — their queue would stay empty forever while new
        // purchases arrived. Stamp them as starting now: what they spent before
        // the upgrade is history, exactly as it is for a fresh install.
        if settings.onboarded && settings.startedUsingAt == nil {
            settings.startedUsingAt = Date()
            try? repository.save(settings, as: "settings")
        }
    }

    // MARK: settings

    func completeOnboarding() {
        settings.onboarded = true
        // Stamped once. Re-onboarding after a reset re-stamps, which is right:
        // a wiped app is a new start. The stamp itself is no longer read by
        // the queue (D5 — the cap counts merchant groups, not a date window),
        // but the field stays populated for anything else that might.
        settings.startedUsingAt = Date()
        isUnlocked = true
        persist()
    }

    func setFaceId(_ on: Bool) {
        settings.faceIdEnabled = on
        persist()
    }

    func setLockImmediately(_ on: Bool) {
        settings.lockImmediately = on
        persist()
    }

    func setAppearance(_ appearance: Appearance) {
        settings.appearance = appearance
        persist()
    }

    func setLanguage(_ language: AppLanguage) {
        settings.language = language
        // Views re-render from `\.locale`; the formatters cannot see the
        // environment and read `L10n.formatting` instead. This is the only
        // assignment to it outside `init`.
        L10n.setFormatting(language)
        persist()
    }

    /// Board #60. Stamped when the guide is dismissed from its FIRST showing,
    /// so it does not come back — and deliberately not when it is re-opened
    /// from Налаштування, where re-stamping would say something untrue about
    /// when it was first read.
    func markGuideSeen(now: Date = Date()) {
        guard settings.guideSeenAt == nil else { return }
        settings.guideSeenAt = now
        persist()
    }

    // MARK: the lock grace (board #21)

    /// Going to the background. Locks, and remembers when — unless there is
    /// nothing to remember: an already-locked app leaves no stamp, or
    /// backgrounding the LOCK SCREEN and coming straight back would open the
    /// app to whoever did it.
    func lockForBackground(now: Date = Date()) {
        backgroundedAt = (isUnlocked && !settings.locksImmediately) ? now : nil
        isUnlocked = false
    }

    /// Coming back. Skips the code when the app was unlocked less than
    /// `lockGrace` ago, and reports whether it did.
    ///
    /// **One shot**: the stamp is cleared whether or not it was still good, so
    /// a stamp cannot sit around unlocking a later return that earned nothing.
    ///
    /// The window is `0 ..< lockGrace`, so a NEGATIVE elapsed — the clock
    /// moved back while the app was away — locks rather than unlocking. It is
    /// the cheap half of the trade: the honest case for a backwards clock is a
    /// timezone edit, and that person can type four digits.
    @discardableResult
    func unlockIfWithinGrace(now: Date = Date()) -> Bool {
        guard let at = backgroundedAt else { return false }
        backgroundedAt = nil
        let elapsed = now.timeIntervalSince(at)
        guard elapsed >= 0, elapsed < Self.lockGrace else { return false }
        isUnlocked = true
        return true
    }

    // MARK: pin

    var isPinSet: Bool { pinStore.isSet }

    /// Non-nil while the keypad is refusing attempts.
    var pinLockedUntil: Date? { pinStore.lockedUntil }

    /// The only way `isUnlocked` becomes true from a PIN. Returns false both
    /// for a wrong PIN and for a correct one entered during a lockout.
    @discardableResult
    func unlock(with pin: String) -> Bool {
        guard pinStore.verify(pin) else { return false }
        isUnlocked = true
        return true
    }

    /// Face ID and friends: the biometric check has already succeeded.
    func unlockWithoutPin() { isUnlocked = true }

    /// Verify without unlocking — "confirm it is you" before a sensitive change.
    func verifyPin(_ pin: String) -> Bool { pinStore.verify(pin) }

    func setPin(_ pin: String) throws { try pinStore.set(pin) }

    // MARK: banks

    var connectedBanks: [Bank] { banks.filter(\.connected) }

    func token(for bankId: String) -> String? { keychain.getString("token.\(bankId)") }

    /// Token goes to Keychain; the bank row flips to connected and takes its
    /// accounts from the seed (the real client fills them in later).
    func connect(bankId: String, token: String) {
        guard let i = banks.firstIndex(where: { $0.id == bankId }) else { return }
        try? keychain.setString(token, for: "token.\(bankId)")
        banks[i].connected = true
        if banks[i].accounts.isEmpty, let seeded = seedBanks.first(where: { $0.id == bankId }) {
            banks[i].accounts = seeded.accounts
        }
        persist()
    }

    /// History stays — it is the user's, not the bank's.
    ///
    /// **Board #165: the complaint goes, though.** `syncState.lastStop` and
    /// `needsReconnect` describe a connection, and this is the moment that
    /// connection stops existing. Left behind, they outlived it forever: the
    /// only writer that clears `lastStop` is a sync that commits a window, and
    /// a disconnected bank can never commit one — so the owner was told
    /// «Токен monobank не знайдено — підключіть банк заново» about a bank they
    /// had deliberately disconnected, on every launch, with no way back.
    ///
    /// Scoped by `bankId`, because these two fields are monobank's alone and
    /// disconnecting PrivatBank must not silence them. The email fields are
    /// untouched for the mirror-image reason — board #158's paused mailbox and
    /// a dead email secret are not monobank's to clear.
    ///
    /// This is half the fix. Clearing state a sync writes back on the next
    /// pull-to-refresh would fix nothing; see `startSync`.
    func disconnect(bankId: String) {
        guard let i = banks.firstIndex(where: { $0.id == bankId }) else { return }
        keychain.delete("token.\(bankId)")
        banks[i].connected = false
        if bankId == Bank.monobankId {
            syncState.lastStop = nil
            syncState.needsReconnect = false
        }
        persist()
    }

    /// The card-selection toggle's one write.
    @MainActor
    func setSyncEnabled(bankId: String, accountId: String, _ enabled: Bool) {
        guard let b = banks.firstIndex(where: { $0.id == bankId }),
              let a = banks[b].accounts.firstIndex(where: { $0.id == accountId }) else { return }
        banks[b].accounts[a].syncEnabled = enabled
        persist()
    }

    // MARK: persistence

    /// **Every write goes through this one serial queue.** Board #132.
    ///
    /// Serial buys ordering for nothing: two snapshots taken in order are
    /// enqueued in order and land in order, so no generation counter is needed
    /// to stop a stale write overwriting a fresh one. `.userInitiated` because
    /// the suspend flush below blocks the main thread on it — a background QoS
    /// there would be a stall waiting to happen.
    private static let writeQueue = DispatchQueue(
        label: "ua.monitorfinance.persist", qos: .userInitiated)

    /// The nine documents as values. **Taking this on the main actor is a
    /// retain, not a copy** — every field is a Swift value type, so the 772
    /// transactions are shared copy-on-write until something mutates them, at
    /// which point the mutation copies and this snapshot keeps the old buffer.
    private struct Snapshot {
        var transactions: [Transaction]
        var banks: [Bank]
        var categories: [Category]
        var rules: [Rule]
        var receipts: [Receipt]
        var receiptQueue: [PendingReceipt]
        var budget: Budget?
        var budgetHistory: [Budget]
        var statementImports: [StatementImport]
        var customProductGroups: [ProductGroup]
        var settings: Settings
        var syncState: SyncState
    }

    /// The two writers of `statementImports`, here rather than beside their
    /// callers so its `private(set)` stays enforced by the COMPILER instead of
    /// by convention — Swift scopes a private setter to the file, so an
    /// extension in another file cannot write it, and that is the point.
    /// `AppStore+StatementImports` holds the reasoning; these hold the write.
    func appendStatementImport(_ record: StatementImport) {
        statementImports.append(record)
    }

    func removeStatementImport(_ id: StatementImport.ID) {
        statementImports.removeAll { $0.id == id }
    }

    private func snapshot() -> Snapshot {
        Snapshot(transactions: transactions, banks: banks, categories: categories,
                 rules: rules, receipts: receipts, receiptQueue: receiptQueue,
                 budget: budget, budgetHistory: budgetHistory,
                 statementImports: statementImports,
                 customProductGroups: customProductGroups,
                 settings: settings, syncState: syncState)
    }

    /// Runs OFF the main actor for `persist()`, and on it for `persistNow()`.
    /// **Not named `write`:** the file-protection guard in `test_ios_seed.py`
    /// matches `.write(` to catch a `Data.write` that skips the protection
    /// attribute, and a method of that name is a false positive on a real
    /// security gate. Renaming this was cheaper than loosening that.
    /// It touches nothing but its argument and the repository, which is why
    /// that is safe.
    private static func persistSnapshot(_ s: Snapshot, to repository: Repository) {
        try? repository.save(s.transactions, as: "transactions")
        try? repository.save(s.banks, as: "banks")
        try? repository.save(s.categories, as: "categories")
        try? repository.save(s.rules, as: "rules")
        try? repository.save(s.receipts, as: "receipts")
        try? repository.save(s.receiptQueue, as: "receiptQueue")
        // The else branch is the whole point: `budget` is the only optional
        // here, and without the delete, clearing it leaves budget.json on
        // disk for the next launch to read back.
        if let budget = s.budget { try? repository.save(budget, as: "budget") }
        else { try? repository.remove("budget") }
        try? repository.save(s.budgetHistory, as: "budgetHistory")
        try? repository.save(s.statementImports, as: "statementImports")
        try? repository.save(s.customProductGroups, as: "productGroups")
        try? repository.save(s.settings, as: "settings")
        try? repository.save(s.syncState, as: "sync")
    }

    /// **The common path — every edit, every queue confirm.** Debounced, and
    /// the encoding and writing happen off the main actor.
    ///
    /// Board #132 measured one write at **9.7 ms on a Mac**, of which encoding
    /// the transactions alone was 5.3 ms, against a 16.7 ms frame — and the
    /// phone runs a Debug build, where it is far worse. All of it used to land
    /// on the main actor 300 ms after every tap in the queue.
    func persist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            // Snapshot ON the main actor — reading the properties is what has
            // to be isolated. Encoding and writing do not.
            let snapshot = self.snapshot()
            let repository = self.repository
            Self.writeQueue.async { Self.persistSnapshot(snapshot, to: repository) }
        }
    }

    /// **The flush, and it stays SYNCHRONOUS on purpose.**
    ///
    /// Called when the app is being backgrounded, and iOS suspends the process
    /// shortly after that returns. An async write there is a write that may
    /// never happen, and the change it was carrying is the one the person made
    /// last. `sync` on the serial queue also drains anything `persist()`
    /// already queued, so this lands after them and wins.
    func persistNow() {
        persistTask?.cancel()
        let snapshot = snapshot()
        let repository = self.repository
        Self.writeQueue.sync { Self.persistSnapshot(snapshot, to: repository) }
    }

    // MARK: categories

    /// The five categories most recently used, newest first. "Recently used"
    /// means by transaction date, not by edit time — the user recognises their
    /// own spending order, and nothing records edit times.
    /// `.user` only — categories this person CHOSE (board #12).
    ///
    /// It used to read every row's category, so on a phone whose owner had not
    /// tapped anything «Нещодавні» offered five categories off the demo's
    /// newest rows — «Інші надходження» among them, which is not a thing anyone
    /// picks for a purchase. A heading that means "what you reach for" cannot
    /// be filled by the app.
    ///
    /// `.rule` is excluded for the same reason even though a rule descends from
    /// a real answer: the row it settled was never shown to anybody, and a
    /// merchant answered once should not crowd out four other categories the
    /// person chose by hand. The demo ships no `.user` row at all, so a fresh
    /// install starts empty and «Популярні» stands in until the first tap.
    var recentCategories: [String] {
        var seen: [String] = []
        for tx in transactions.sorted(by: { $0.date > $1.date }) where tx.resolution == .user {
            let name = tx.category
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.append(name)
            if seen.count == 5 { break }
        }
        return seen
    }

    /// `kind` has no default (board #94). A default would let a caller create
    /// a category that means nothing to the budget — which is exactly what
    /// every category created before this card was, and why an income row
    /// could not have one made for it.
    func addCategory(_ name: String, kind: CategoryKind) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !categories.contains(where: { $0.name == trimmed }) else { return }
        categories.append(Category(name: trimmed, tintIndex: nextTintIndex(), kind: kind))
        persist()
    }

    /// Create a PRODUCT group — what was bought, never a spending category.
    /// Board #184, from «for Coca-Cola I would like to create the category
    /// Soft Water», which the app had no way to accept.
    ///
    /// `item` is the receipt line the picker was opened for, and it is what
    /// makes the new group reachable by `ProductGuess` instead of a name the
    /// person has to pick by hand forever. Its FIRST WORD becomes the group's
    /// only keyword: the seeded keywords are single words («молоко», «кефір»),
    /// receipt lines lead with the product and trail into size and brand, and
    /// «Coca-Cola 0,5 л» therefore teaches `coca-cola` — so the next bottle
    /// places itself. That is board #7's cascade, applied to goods.
    ///
    /// **A keyword another group already claims is dropped rather than taken.**
    /// Creating a group from «Вода Моршинська» would otherwise hand `вода` to
    /// it and away from «Плодоовочеві товари» — and `ProductGuess` sorts
    /// candidates by keyword LENGTH, which for two identical keywords is a tie
    /// Swift's unstable sort breaks differently on different runs. The group is
    /// still created; it is simply one the guesser cannot reach, which is
    /// honest, whereas silently rerouting an existing word is not.
    ///
    /// Returns the stored name on success — the caller needs it to select what
    /// it just created — and nil when nothing was added.
    @discardableResult
    func addProductGroup(_ name: String, from item: String = "") -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Case-insensitive and across the COMPOSED list: «ліки» must not
        // become a second «Ліки», and a duplicate of a custom group is the
        // same mistake one step later.
        let existing = productGroups.first {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        // Folded, not refused: the person asked for a group by that name and
        // there is one, so the picker should select it rather than report a
        // failure they cannot act on.
        if let existing { return existing.name }

        let claimed = Set(productGroups.flatMap(\.keywords))
        let keyword = Self.firstWord(of: item)
        let keywords = keyword.map { claimed.contains($0) ? [] : [$0] } ?? []
        customProductGroups.append(ProductGroup(name: trimmed, keywords: keywords))
        persist()
        return trimmed
    }

    /// The leading word of a receipt line, normalised the way `ProductGuess`
    /// normalises the names it matches against — otherwise the keyword is
    /// stored in one alphabet's worth of case and compared in another.
    /// Nil when there is no word to take.
    static func firstWord(of item: String) -> String? {
        MerchantKey.normalize(item)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first
            .map(String.init)
    }

    // MARK: category colours (board #57)

    /// Which wash a category wears, and the one place that decides it.
    ///
    /// **On the store rather than on `Theme`, which is the whole card.** The
    /// colour used to be `Theme.tint(for: String)` — a hash of the name — so
    /// nineteen categories fell into twelve slots and «Покупки» and «Послуги»
    /// were the same colour on every screen that drew one. A colour that is a
    /// property of the category has to be read from the category, and only the
    /// store holds those.
    ///
    /// **An index and not a `Color`.** Nothing under `Store/` imports SwiftUI
    /// — `Derived` says so in its first line and this is the same boundary.
    /// `CategorySwatch` is what turns the number into a colour, and it is the
    /// only thing that draws one.
    ///
    /// **Total, and deliberately falls back rather than trapping.** A row can
    /// name a category the store does not have — an import, a restore, a file
    /// edited by hand — and the honest answer to "what colour is a category
    /// that does not exist" is a stable arbitrary one, not a crash on the feed.
    func tintIndex(for category: String) -> Int {
        guard let index = categories.first(where: { $0.name == category })?.tintIndex else {
            return Theme.fallbackIndex(for: category)
        }
        return Theme.washIndex(index)
    }

    // MARK: category icons (board #61)

    /// The SF Symbol a category wears. Board #61.
    ///
    /// Total for the same reason `tintIndex(for:)` is: a row can name a
    /// category the store does not have, and the feed still has to draw it.
    /// A category nobody has chosen for, and a category that does not exist,
    /// both get the generic label — which is the honest answer to "what is
    /// this?" in both cases.
    func iconName(for category: String) -> String {
        categories.first(where: { $0.name == category })?.iconName ?? CategoryIcon.fallback
    }

    /// The only writer. Refuses an icon the app does not offer: the chooser
    /// cannot produce one, but a restored file or a hand edit can, and a
    /// symbol name that does not resolve draws NOTHING — a blank swatch, with
    /// no error anywhere.
    func setIcon(_ icon: String, for category: String) {
        guard CategoryIcon.offered.contains(icon),
              let i = categories.firstIndex(where: { $0.name == category }) else { return }
        categories[i].icon = icon
        persist()
    }

    /// The wash a category created right now should take.
    private func nextTintIndex() -> Int {
        Self.nextTintIndex(amongTaken: categories.compactMap(\.tintIndex))
    }

    /// The lowest wash nobody holds — or, once all twenty are spoken for, the
    /// least-held one, ties broken by the lowest index.
    ///
    /// **Past twenty categories two of them do share a colour, and there is no
    /// version of this that avoids it.** Twenty is the palette; a
    /// twenty-first category has to reuse something. Spreading the reuse
    /// evenly is the most that can be done, and board #61's icon is what keeps
    /// the pair apart once colour cannot.
    static func nextTintIndex(amongTaken taken: [Int]) -> Int {
        var counts = [Int](repeating: 0, count: Theme.washes.count)
        for index in taken { counts[Theme.washIndex(index)] += 1 }
        var best = 0
        for index in counts.indices where counts[index] < counts[best] { best = index }
        return best
    }

    /// Give a wash to every category that has none. Board #57's migration.
    ///
    /// Every category on a phone today has `tintIndex: nil` — the field has
    /// been in the model since the beginning and nothing ever wrote it. So
    /// this runs on literally every install, once, and its result is what the
    /// person then sees for good.
    ///
    /// **Alphabetical, and that is load-bearing.** The allocation has to be a
    /// pure function of the set of names: `categories` arrives in file order,
    /// which differs between a fresh install (seed order), a restored backup
    /// and a device that has renamed things — and three devices holding the
    /// same nineteen categories in different colours is the same defect this
    /// card is fixing, one layer down.
    static func assigningMissingTintIndexes(_ categories: [Category]) -> [Category] {
        var result = categories
        let unassigned = result.filter { $0.tintIndex == nil }.map(\.name)
        for name in Category.alphabetical(unassigned) {
            guard let i = result.firstIndex(where: { $0.name == name }) else { continue }
            result[i].tintIndex = Self.nextTintIndex(amongTaken: result.compactMap(\.tintIndex))
        }
        return result
    }

    // MARK: category editing

    /// Renaming onto an existing name is a merge, not an error: two categories
    /// with one name would break the picker, the tints and every grouping.
    func renameCategory(_ old: String, to new: String) {
        let target = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != old else { return }
        for i in transactions.indices where transactions[i].category == old {
            transactions[i].category = target
        }
        // Rules point at category NAMES. A rule left pointing at the old name
        // would re-apply it to the next matching purchase.
        for i in rules.indices where rules[i].category == old {
            rules[i].category = target
        }
        // Read BEFORE the removal, and carried onto the new name: renaming is
        // the same category under a different word, and a category that
        // changed colour because it was renamed would be the card's own defect
        // in miniature. A MERGE is the other case and keeps the target's
        // colour — the surviving category is the target, not the source.
        // Board #57.
        let carried = categories.first(where: { $0.name == old })?.tintIndex
        let carriedIcon = categories.first(where: { $0.name == old })?.icon
        categories.removeAll { $0.name == old }
        if !categories.contains(where: { $0.name == target }) {
            categories.append(Category(name: target, tintIndex: carried ?? nextTintIndex(),
                                       icon: carriedIcon))
        }
        persist()
    }

    func mergeCategory(_ source: String, into target: String) {
        renameCategory(source, to: target)
    }

    /// Board #149 — two names for one idea, folded on the device that already
    /// has both.
    ///
    /// `PrivatMapper.categoryMap` stops the NEXT «Авто» from being created;
    /// this is for the rows that already exist. Fixing only the mapper would
    /// leave the owner looking at exactly the two car categories they asked
    /// about — «There is an Automobile, so why is Авто there?»
    ///
    /// **This does not re-decide anything**, which is what makes it compatible
    /// with the card's own rule against touching a row the person already
    /// answered. A row filed under «Авто» keeps its meaning; only the word
    /// changes, and `renameCategory` is a MERGE that carries rules and colour
    /// with it. Re-categorizing would destroy the answers this card is built
    /// on; re-spelling them preserves every one.
    ///
    /// **Deliberately just the one pair.** Nine other off-vocabulary names
    /// exist in the owner's log and most are NOT duplicates — «АЗС» sits
    /// beside «Автомобіль» by their own repeated choice. Those are listed in
    /// a review for them to accept or reject, because
    /// the card is explicit that proposals are written down before they ship.
    static let duplicateCategoryFolds: [(from: String, into: String)] = [
        ("Авто", "Автомобіль"),
    ]

    /// Idempotent by construction rather than by a flag: after the first run
    /// no category or row carries the old name, so the guard below finds
    /// nothing and `renameCategory` — which would otherwise CREATE the target
    /// — is never reached. A launch that never persists simply does it again.
    func foldDuplicateCategories() {
        for fold in Self.duplicateCategoryFolds {
            guard categories.contains(where: { $0.name == fold.from })
                || transactions.contains(where: { $0.category == fold.from })
            else { continue }
            renameCategory(fold.from, to: fold.into)
        }
    }

    /// Board #94. Changing a kind re-bases EVERY month, not only the ones
    /// after it: `BudgetMath.income` reads the kind at the moment it runs and
    /// the rows it filters are the whole history. The screen says so before
    /// calling this — the warning is not decoration, it is the difference
    /// between a setting and a surprise.
    ///
    /// No transaction is touched. A kind is a fact about the category, not
    /// about the rows in it.
    func setCategoryKind(_ name: String, _ kind: CategoryKind) {
        // The one category whose kind is not the person's to choose. Every
        // mapper lands income in `defaultIncomeCategory`, and `BudgetMath`'s
        // own doc says it MUST be earned: anything else makes every synced
        // income row worth zero to the budget and the default plan divide by
        // nothing — while Головна, which reads the sign, keeps counting it.
        // Board #94 made kinds editable, which is what first made this
        // reachable; the screen greys the control out and says why.
        guard !(name == BudgetMath.defaultIncomeCategory && kind != .earned) else { return }
        guard let i = categories.firstIndex(where: { $0.name == name }) else { return }
        categories[i].kind = kind
        persist()
    }

    /// Deleting never orphans a row: everything it held moves to «Інше», which
    /// is created if the user has never used it.
    func deleteCategory(_ name: String) {
        guard name != "Інше" else { return }
        renameCategory(name, to: "Інше")
    }

    // MARK: budget

    /// The only writer of `budget`. Views call this; nothing assigns the
    /// property directly.
    ///
    /// A plan may name a category the store has never seen — the starter plan
    /// names «Заощадження», which the seed does not ship. Creating it here
    /// rather than in the editor means every entry point (starter plan, manual
    /// line, a plan restored from another device) lands in the same state.
    func setBudget(_ budget: Budget, now: Date = Date()) {
        var plan = budget
        // Every plan written from here on belongs to a month — the one it is
        // written in. Board #62.
        if plan.month == nil { plan.month = MonthKey(now) }

        var known = Set(categories.map(\.name))
        for line in plan.lines where !known.contains(line.category) {
            categories.append(Category(name: line.category, tintIndex: nextTintIndex()))
            known.insert(line.category)
        }
        archiveCurrentPlanIfItBelongsToAnEarlierMonth(than: plan)
        self.budget = plan
        persist()
    }

    /// Board #114 — **a scope change takes effect NEXT month.**
    ///
    /// The owner's decision, and the reason for it: a half-spent month has a
    /// plan somebody already made decisions against, and narrowing it
    /// mid-month would rewrite what those decisions were measured by.
    ///
    /// It needs almost no machinery, because board #62 already built it. A
    /// plan carries the month it starts applying from, so "next month" is a
    /// new plan stamped one month on — the current one stays in force for the
    /// rest of this month exactly as it is, and `plan(for:)` picks whichever
    /// applies without knowing this feature exists.
    ///
    /// **The cost is real and the screen says it out loud:** for the rest of
    /// this month the budget covers banks the feed no longer will, and from
    /// next month it covers fewer. Silently changing which is which is the
    /// failure this whole shape avoids.
    func setBudgetScope(_ banks: [String]?, now: Date = Date()) {
        guard var plan = plan(for: MonthKey(now)) else { return }
        plan.banks = banks
        plan.month = MonthKey(now).advanced(by: 1)
        setBudget(plan, now: now)
    }

    /// The scope that will apply from next month, when it differs from the one
    /// applying now — what the screen needs to say the change is pending.
    ///
    /// `nil` when nothing is pending, which is the ordinary case and the one
    /// the screen must stay quiet about.
    func pendingBudgetScope(now: Date = Date()) -> [String]?? {
        let thisMonth = plan(for: MonthKey(now))
        let next = plan(for: MonthKey(now).advanced(by: 1))
        guard let next, next.banks != thisMonth?.banks else { return nil }
        return .some(next.banks)
    }

    /// The plan a month was actually measured against: the newest one written
    /// on or before it. Board #62's third criterion.
    ///
    /// A plan with no month predates the field and counts as always in force
    /// — see `Budget.month`.
    ///
    /// **A month that ended before the first plan was written falls back to
    /// that first plan.** The first version of this returned nil there, which
    /// is arguably the more honest answer and is the wrong one: the app
    /// backfills months of history, and the whole reason to look back is to
    /// measure it. Returning nil made the tab useful for exactly the month the
    /// plan was written in, and two UI tests said so. The screen names the
    /// month the plan came from, so nothing is being implied.
    ///
    /// A note for whoever mutation-tests this next: `?? true` and `?? false`
    /// on the month filter are BEHAVIOURALLY EQUIVALENT, because the
    /// earliest-plan fallback catches the legacy plan either way — its
    /// effective month sorts before every real one. The `true` stays because
    /// it says what is meant, and a pytest guard pins it for that reason; no
    /// Swift test can tell the two apart.
    func plan(for month: MonthKey) -> Budget? {
        let all = [budget].compactMap { $0 } + budgetHistory
        let inForce = all.filter { $0.month.map { $0 <= month } ?? true }
        guard !inForce.isEmpty else {
            return all.min { Self.effectiveMonth($0) < Self.effectiveMonth($1) }
        }
        return inForce.max { Self.effectiveMonth($0) < Self.effectiveMonth($1) }
    }

    /// A plan with no month sorts before every real one, so a stamped plan
    /// always wins over the legacy one it replaced.
    static func effectiveMonth(_ budget: Budget) -> MonthKey {
        budget.month ?? MonthKey(year: 0, month: 1)
    }

    /// True when the current plan was written for a month that has passed —
    /// i.e. the 1st has come round and nobody has decided anything yet.
    ///
    /// Deliberately NOT a trigger for doing something automatically. Until the
    /// person chooses, the old plan is still the newest one written on or
    /// before now, so it goes on measuring the new month and nothing about the
    /// screen breaks. The choice is an offer, not an interruption.
    func planNeedsAMonthlyDecision(now: Date = Date()) -> Bool {
        guard let budget, let month = budget.month else { return false }
        return month < MonthKey(now)
    }

    /// «Лишити той самий план»: the same shares, stamped with this month. The
    /// previous stamp goes to history, so the month it belonged to keeps being
    /// measured against it and not against this copy.
    func carryPlanForward(now: Date = Date()) {
        guard let budget, planNeedsAMonthlyDecision(now: now) else { return }
        var next = budget
        next.month = MonthKey(now)
        setBudget(next, now: now)
    }

    private func archiveCurrentPlanIfItBelongsToAnEarlierMonth(than incoming: Budget) {
        guard let current = budget else { return }
        // Same month: this is an edit, not a new plan, and the month has only
        // ever been measured against the thing being edited. Archiving here
        // would fill history with every tap of «Змінити».
        guard Self.effectiveMonth(current) < Self.effectiveMonth(incoming) else { return }
        budgetHistory.removeAll { Self.effectiveMonth($0) == Self.effectiveMonth(current) }
        budgetHistory.append(current)
    }

    // MARK: data

    /// Everything the app persists, in one document. Deliberately built from
    /// the collections rather than by reading the JSON files, so a secret can
    /// never be included by accident — secrets are not in these collections.
    /// Writes the export where the share sheet can reach it, and says where.
    ///
    /// **The protection key is the point, and it was missing** (board #54).
    /// This file is the whole dataset — every merchant, amount and category —
    /// and it went to `temporaryDirectory` with a bare `.atomic`, while
    /// `Repository` sets `completeUntilFirstUserAuthentication` on the store
    /// deliberately and the two categorization exports twenty lines above the
    /// old call site set it too. Copying the app's own data into a weaker
    /// place than the app keeps it is not a trade anybody made on purpose.
    ///
    /// On `AppStore` rather than inside the view for one reason: a file
    /// attribute is invisible to every screen and to XCUITest, so putting the
    /// write here is what lets a unit test read it back.
    ///
    /// One fixed filename, so a second export replaces the first rather than
    /// leaving a pile behind; `temporaryDirectory` is purged by iOS, and until
    /// it is, what is left is protected exactly as the store is.
    func writeExport(to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("monitorfinance-export.json")
        try exportJSON().write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func exportJSON() throws -> Data {
        struct Export: Encodable {
            var exportedAt: Date
            var transactions: [Transaction]
            var banks: [Bank]
            var categories: [Category]
            var rules: [Rule]
            var receipts: [Receipt]
            var budget: Budget?
            /// Board #62. Without it an export would carry the current plan
            /// and silently drop every earlier one — and those are what the
            /// person's past months were measured against.
            var budgetHistory: [Budget]
        }
        // Banks are exported without tokens because tokens live in Keychain and
        // are not a property of Bank. If that ever changes, this must strip them.
        return try SeedLoader.encoder.encode(Export(
            exportedAt: Date(), transactions: transactions, banks: banks,
            categories: categories, rules: rules, receipts: receipts, budget: budget,
            budgetHistory: budgetHistory))
    }

    /// Everything: files, Keychain, PIN, in-memory state. The app returns to
    /// the state a fresh install is in, which means onboarding — so this also
    /// clears `onboarded` and locks.
    /// Disowns whatever sync run is in flight. Called by every path that
    /// destroys the dataset that run was started against.
    ///
    /// The engine cannot be stopped from here — it is an actor mid-`await`
    /// inside a bank request — so instead it is orphaned: the generation moves
    /// on, so every write its closures attempt is dropped, and `syncEngine` is
    /// released so the NEXT `startSync` builds a fresh engine bound to the new
    /// generation. The orphan then discovers on its own that its commit
    /// changed no cursor and stops with `.stalled`.
    ///
    /// `isSyncing` AND `isEmailSyncing` go down with it: `startSync`'s and
    /// `syncPrivatEmail`'s `defer`s only lower the flag each raised (they
    /// compare generations too), so neither run sees its own abandonment —
    /// without this, an email page landing mid-flight would find
    /// `isEmailSyncing` stuck true for the rest of the process, and every
    /// later `syncPrivatEmail` would bail at its reentrancy guard forever.
    func abandonSync() {
        syncGeneration &+= 1
        syncEngine = nil
        isSyncing = false
        isEmailSyncing = false
    }

    /// True while `generation` still names the dataset the app is working on.
    /// The guard every write from a sync closure goes through.
    func isCurrentSync(_ generation: Int) -> Bool { generation == syncGeneration }

    /// Same shape as `abandonSync`, one host over: a `ReceiptFetcher` (task
    /// 11) is also an actor parked inside a network request — a tax-service
    /// one rather than a bank one — that cannot be cancelled from here
    /// either. Bumping this before either wipe means its next `commit`/`fail`
    /// finds `isCurrentReceiptFetch` false and drops whatever it was about to
    /// write, instead of landing it in the dataset that replaced the one it
    /// was fetching for.
    ///
    /// Releases `receiptFetcher` the same way `abandonSync` releases
    /// `syncEngine`: the actor itself cannot be stopped from here — it is
    /// mid-`await` inside a tax-cabinet request — so it is orphaned instead.
    /// The generation moves on, so its `commit`/`fail` closures find
    /// `isCurrentReceiptFetch` false and drop whatever they were about to
    /// write; releasing the reference here means the NEXT fetch builds a
    /// fresh actor bound to the new generation rather than reusing the
    /// orphan, whose pacer and stand-down state belong to a dataset that no
    /// longer exists.
    ///
    /// No `isFetchingReceipts`-style flag to lower alongside it: unlike
    /// `isSyncing`, nothing yet reads one — that arrives with whatever task
    /// 12 names its own entry point, mirroring `startSync`.
    func abandonReceiptFetch() {
        receiptGeneration &+= 1
        receiptFetcher = nil
    }

    /// True while `generation` still names the dataset the running receipt
    /// fetch belongs to — mirrors `isCurrentSync`; see `receiptGeneration`.
    func isCurrentReceiptFetch(_ generation: Int) -> Bool { generation == receiptGeneration }

    /// **Board #168 — the mailbox survives, by default.**
    ///
    /// The owner reset the app and lost the address every forwarding rule they
    /// had set up by hand pointed at. Measured on the live database: the old
    /// row was gone and a new one existed sixty seconds later, because
    /// `DataSettingsView` deleted the server account first and `POST /register`
    /// has no other behaviour — it only ever mints a new random address.
    ///
    /// The old design was not careless; it was a trade made the wrong way
    /// round. `keychain.wipe()` takes the secret, and the secret is the only
    /// thing that can ever read that mailbox again — so a wipe on its own left
    /// a live address nobody could read, collecting `from` and `subject`
    /// forever. Board #158 called that the orphan and deleted the account to
    /// prevent it. **But an unreadable mailbox costs rows in a table, and a
    /// destroyed address costs the person every rule they set up by hand, with
    /// no way to ask for the same one back.** The cheap failure was being
    /// prevented at the price of the expensive one.
    ///
    /// So the credentials are carried across the wipe, which removes the orphan
    /// rather than trading against it: the address stays reachable, so it is
    /// not orphaned, and it stays the SAME, which is what the owner asked for —
    /// «the address should be one per phone and that's it».
    ///
    /// The bank entry is deliberately NOT reconnected. A reset promises an
    /// empty app and that promise is kept; `registerPrivatEmail` returns
    /// `.alreadyRegistered` when the person sets the mail up again, so they get
    /// their own address back rather than a new one.
    ///
    /// **The reset has no "and the address too" option, deliberately.** It had
    /// a `keepingMailbox: false` parameter for one afternoon, written for a
    /// second button in the reset alert that board #168's screenshot rejected;
    /// board #170 gave the deliberate deletion its own home on the mail screen
    /// and removed the parameter, because a tested-but-uncalled destructive
    /// path reads as an endorsed one and the next hand would have wired it
    /// back here.
    ///
    /// Somebody giving the phone away performs two deliberate acts in the two
    /// places that own them — «Видалити адресу назавжди» on the mail screen,
    /// then this. Neither is a consequence of the other.
    ///
    /// **Custom product groups GO. Board #184, decided rather than
    /// discovered.** A group the person invented is their own work, exactly
    /// like a rule or a category they added, and every one of those is
    /// destroyed here. The mailbox is the single exception and it is an
    /// exception for a reason nothing else shares: the address cannot be
    /// asked for again. A product group can — it takes one tap on the picker
    /// that created it.
    func resetEverything() {
        abandonSync()
        // Same reasoning as `wipeForNewClient`: a `ReceiptFetcher` fetch in
        // flight must not land its next commit in the fresh-install state
        // this method is about to create.
        abandonReceiptFetch()
        try? repository.wipe()
        // Read back after the wipe rather than trusted: a kept key that failed
        // to restore is a mailbox nobody can ever read, and `emailAddressIssued`
        // below must not claim an address this phone can no longer reach.
        let mailboxKept = keychain.wipe(keeping: [
            Self.emailUserIdKey, Self.emailSecretKey, Self.emailAddressKey,
        ]) && privatEmailCredentials != nil
        pinStore.clear()
#if DEBUG
        // The switch and its file are the user's data too — see
        // `CategorizationLog.reset`. Assumed main-actor for the same reason
        // `AppStore.note` is: every route here is a tap.
        MainActor.assumeIsolated { categorizationLog.reset() }
#endif

        // Fresh-install state BEFORE the seed load, so no early exit can leave
        // the app unlocked and "onboarded" sitting over wiped storage.
        budget = nil
        budgetHistory = []
        settings = Settings()
        syncState = SyncState()
        // Board #168. `emailAddressIssued` means "this phone has been given an
        // address at some point", and after a reset that kept the mailbox it
        // still has been — so a fresh `SyncState` would lie in exactly the
        // direction board #111 built this field to prevent: the app would look
        // like a fresh install and offer to create an address, minting a new
        // one while the person's forwarding rule kept feeding the old.
        //
        // `emailCursor` stays at 0 on purpose. The transactions are gone, so
        // every letter has to be consumed again; a carried-over cursor would
        // claim they were already imported and leave the hole `ingestRows`
        // exists to avoid.
        syncState.emailAddressIssued = mailboxKept
        undoStack = []
        isUnlocked = false

        // Same stance as `live()`: a missing seed is a broken bundle, not a
        // recoverable runtime condition. Disagreeing with `live()` about that
        // is how one of them ends up wrong.
        guard let seed = try? SeedLoader.load() else {
            preconditionFailure("reference.json missing from the app bundle")
        }
        transactions = seed.transactions
        banks = seed.banks
        // The seed ships no colours — `init` is where they are normally handed
        // out, and a reset does not run one. Board #57.
        categories = Self.assigningMissingTintIndexes(seed.categories)
        rules = seed.rules
        receipts = seed.receipts
        receiptQueue = []
        // Board #184, and see this method's doc comment: the person's own
        // groups are their work and go with the rest of it. `[]` and not
        // `seed.productGroups` — the seeded taxonomy is not stored here and
        // never was, so re-seeding this would invent twenty-one groups the
        // person had "added".
        customProductGroups = []
        persistNow()
    }
}

/// Guards ALL launch-argument handling in `AppStore.live()` so it runs once per
/// process. See the comment at its only use.
private var hasHandledLaunchArguments = false

extension AppStore {
    /// The store the running app uses. Honours the launch arguments: wipes on
    /// `-resetState`, fakes a finished first run on `-skipOnboarding`.
    static func live() -> AppStore {
        let repo = FileRepository.standard()
        let keychain = Keychain.app
        // Built before the store so the reset paths below can clear it, then
        // handed to the store — one instance for the whole process.
        let pinStore = PinStore(keychain: keychain)
        // ONCE per process, not once per call. `RootView` holds the store as
        // `@State private var store = AppStore.live()`, and SwiftUI evaluates a
        // `@State` initializer expression every time the view struct is
        // constructed — keeping only the first result, but running the
        // expression each time. Every one of those runs used to re-wipe the
        // Keychain, so a `-resetState` launch could destroy the PIN the user
        // had just set halfway through onboarding: `settings.onboarded` stayed
        // true on disk while `isPinSet` went false, and `RootView.phase` pinned
        // itself to `.onboarding` for the rest of the session.
        //
        // The wipe belongs to the launch, not to the store, so it happens on
        // the first construction and never again. Debug-only either way —
        // `Launch.resetState` and `.forgetPin` are `false` in Release.
        //
        // The `skipOnboarding` block below is behind the SAME flag, for the
        // same reason: SwiftUI keeps only the first store, so every later one
        // is a throwaway — and letting it run `persistNow()` wrote five files
        // from a store nothing would ever read, on every `RootView`
        // construction.
        let isFirstLaunchConstruction = !hasHandledLaunchArguments
        hasHandledLaunchArguments = true
        if isFirstLaunchConstruction {
            if Launch.resetState {
                try? repo.wipe()
                keychain.wipe()
                pinStore.clear()
                // `StatsView`'s «Загальна»/«За чеками» toggle lives in
                // `@AppStorage("stats.bySplits")`, which — unlike the file
                // repo, Keychain and PIN store above — nothing else here
                // touches. Left alone, it survives every `-resetState`
                // launch: a UI test that switches to «За чеками» and then
                // fails (or simply ends) before switching back leaves EVERY
                // later test in the same simulator starting from «За
                // чеками» instead of the real default, silently breaking
                // any of them that assume spending-category slices. Demo
                // resets should start from the same UI state every time for
                // the same reason.
                UserDefaults.standard.removeObject(forKey: "stats.bySplits")
                // Same class of key, and a graver one: the categorization
                // log's opt-in switch. A reset that left data collection
                // running would be the one setting a fresh install kept.
                // Fenced because the type does not exist in Release — this
                // block itself does, since `Launch.resetState` is merely
                // `false` there.
#if DEBUG
                CategorizationLog.eraseEverything()
#endif
            }
            if Launch.forgetPin {
                pinStore.clear()
            }
            // After the wipe, or `-resetState -corruptFile x` would delete the
            // very file it was asked to plant. Valid JSON of the wrong shape
            // — which is the corruption this repo has actually met twice, a
            // model that changed under a file already on disk, rather than a
            // truncated write.
            if let name = Launch.corruptFile {
                try? repo.save([["nothingWeKnow": true]], as: name)
            }
            if Launch.stalePlan {
                // Written straight to the file rather than through
                // `setBudget`, which stamps the CURRENT month — the whole
                // point here is a plan belonging to a month that has passed.
                try? repo.save(
                    Budget(incomeBase: .fixed(50_000_00),
                           lines: [.init(id: UUID(), category: "Продукти", percent: 60),
                                   .init(id: UUID(), category: "Квартплата", percent: 40)],
                           month: MonthKey(Date()).advanced(by: -1)),
                    as: "budget")
            }
            if Launch.plan {
                // This month's, so the budget tab renders its filled state and
                // no carry-forward card competes for the screen.
                try? repo.save(
                    Budget(incomeBase: .fixed(50_000_00),
                           lines: [.init(id: UUID(), category: "Продукти", percent: 60),
                                   .init(id: UUID(), category: "Квартплата", percent: 40)],
                           month: MonthKey(Date())),
                    as: "budget")
            }
            if Launch.statements {
                // Two records, because one hides the ordering and the "already
                // known" line: the newest is listed first, and a re-import that
                // added nothing must still read as an import that happened.
                //
                // Invented filenames, per the project's fixture rule — every
                // name in `demo.json` comes off the owner's own statement, and
                // the privacy guard refuses one in Swift source.
                // The ids come from the demo catalogue itself, read here
                // because this runs before the store exists: a record naming
                // ids nothing matches would list "0 операцій" and the delete
                // would have nothing to take, which is the one thing this
                // seed has to make testable.
                let loaded = try? SeedLoader.load()
                let ids = loaded?.transactions.prefix(3).map(\.id) ?? []

                // …and PrivatBank has to be CONNECTED, or there is no screen
                // to put the list on: the banks list renders `connectedBanks`
                // only. A real import connects it as its last act
                // (`applyStatement`), so a seeded import has to as well —
                // otherwise this flag seeds a state the app can never show.
                if var banks = loaded?.banks,
                   let i = banks.firstIndex(where: { $0.id == "privatbank" }) {
                    banks[i].connected = true
                    try? repo.save(banks, as: "banks")
                }
                try? repo.save([
                    StatementImport(filename: "виписка-приклад-1.xlsx",
                                    importedAt: Date().addingTimeInterval(-86_400 * 3),
                                    created: Array(ids), merged: 0,
                                    // The demo catalogue's own span, read
                                    // from it rather than written here: a
                                    // hardcoded pair would drift the day the
                                    // seed is regenerated and the list would
                                    // claim months it does not hold.
                                    from: loaded?.transactions.map(\.date).min(),
                                    to: loaded?.transactions.map(\.date).max()),
                    StatementImport(filename: "виписка-приклад-2.xlsx",
                                    importedAt: Date(),
                                    created: [], merged: 3, from: nil, to: nil),
                ], as: "statementImports")
            }
            if Launch.twoKindRules {
                // An invented merchant, not one from the seed: every name in
                // `demo.json` comes off the owner's own statement and the
                // privacy guard refuses one in Swift source. It has no
                // transactions either, so the rules screen renders it by its
                // key — which is what that screen does for any merchant whose
                // rows have aged out, and is the case worth having on screen.
                let key = MerchantKey.normalize("Маркет-Приклад")
                try? repo.save([
                    Rule(merchantKey: key, category: "Техніка", ambiguous: false, scope: .expense),
                    Rule(merchantKey: key, category: "Зарплата", ambiguous: false, scope: .income),
                    // The control, and the reason it is here rather than left
                    // to the seed: the qualifier is suppressed for a merchant
                    // with ONE rule, and every rule `demo.json` ships is
                    // unscoped — so `scopeNote` returns nil for all five and
                    // "no qualifier appeared" could not fail however the
                    // condition was written. Forcing the qualifier permanently
                    // ON left that test green. A lone SCOPED rule is the only
                    // fixture that can tell the two apart.
                    Rule(merchantKey: MerchantKey.normalize("Сервіс-Приклад"),
                         category: "Послуги", ambiguous: false, scope: .expense),
                ], as: "rules")
            }
        }
        // A missing reference.json means the bundled resource is broken, not a
        // recoverable runtime condition — an empty-collections fallback would
        // silently persist and then win forever over a later, readable seed.
        guard let seed = try? SeedLoader.load() else {
            preconditionFailure("reference.json missing from the app bundle")
        }
        let api: MonobankAPI
#if DEBUG
        if let mode = Launch.stubMonobank { api = MonobankStub(mode: mode) }
        else { api = MonobankClient() }
#else
        api = MonobankClient()
#endif
        let taxCabinetAPI: TaxCabinetAPI
#if DEBUG
        if let mode = Launch.stubTaxCabinet { taxCabinetAPI = TaxCabinetStub(mode: mode) }
        else { taxCabinetAPI = TaxCabinetClient() }
#else
        taxCabinetAPI = TaxCabinetClient()
#endif
        let emailAPI: PrivatEmailAPI
#if DEBUG
        if let mode = Launch.stubPrivatEmail { emailAPI = PrivatEmailStub(mode: mode) }
        else { emailAPI = PrivatEmailClient() }
#else
        emailAPI = PrivatEmailClient()
#endif
        let store = AppStore(repository: repo, seed: seed, keychain: keychain, pinStore: pinStore,
                             api: api, taxCabinetAPI: taxCabinetAPI, emailAPI: emailAPI)
        if isFirstLaunchConstruction {
            // `-skipOnboarding` means "pretend the first run already
            // happened", and board #60's guide is part of a first run;
            // `-noGuide` is the same statement for a test that walks
            // onboarding for real but is about something else.
            if Launch.skipOnboarding || Launch.noGuide { store.markGuideSeen() }
            // Board #107, and it must come AFTER the stamp above rather than
            // being folded into its condition: `-showGuide` is meant to be
            // droppable onto an existing launch list without editing the rest
            // of it, and every such list already carries one of those two.
            if Launch.showGuide {
                store.settings.guideSeenAt = nil
                store.persistNow()
            }
            // Set before anything draws, and written through the ordinary
            // mutation so it persists exactly as a tap on the settings row
            // would — a test that relaunches must find the same language.
            if let language = Launch.language { store.setLanguage(language) }
            if Launch.skipOnboarding {
                if !store.isPinSet { try? store.setPin(Launch.testPin) }
                if !store.banks.contains(where: { $0.id == "monobank" && $0.connected }) {
                    store.connect(bankId: "monobank", token: "test-token")
                }
#if DEBUG
                // A UI test with the email stub needs credentials the way the
                // monobank shortcut above needs `connect` — registration is
                // issue #91's screen and no test here should walk an unbuilt
                // flow. Its own fence: `PrivatEmailStub` does not compile in
                // Release, and this whole `-skipOnboarding` block is not
                // itself behind `#if DEBUG`.
                if Launch.stubPrivatEmail != nil, store.privatEmailCredentials == nil {
                    // Board #111's `-emailKeyLost`: everything below EXCEPT the
                    // credentials, which is precisely the restored-onto-a-new-
                    // phone state — the data file survived a backup and the
                    // `…ThisDeviceOnly` secret did not.
                    if Launch.emailKeyLost {
                        store.syncState.emailAddressIssued = true
                    } else {
                        try? keychain.setString(PrivatEmailStub.credentials.userId,
                                                for: AppStore.emailUserIdKey)
                        try? keychain.setString(PrivatEmailStub.credentials.secret,
                                                for: AppStore.emailSecretKey)
                        try? keychain.setString(PrivatEmailStub.address,
                                                for: AppStore.emailAddressKey)
                    }
                    // The flag a real registration sets (board #91). Without
                    // it the bank is absent from Налаштування → Банки, so no
                    // UI test could reach the email section it now carries —
                    // the same shortcut `connect(bankId: "monobank", …)` takes
                    // just above.
                    if let b = store.banks.firstIndex(where: { $0.id == PrivatMapper.bankId }) {
                        store.banks[b].connected = true
                    }
                }
#endif
#if DEBUG
                // The real onboarding flow always populates real accounts via
                // `verifyAndConnect` → `clientInfo` before any sync can run.
                // This shortcut bypasses that call and `connect(bankId:token:)`
                // falls back to the SEEDED accounts — which under
                // `-noDemoData` is an empty list, since only `demo.json`
                // carries any. Left unfilled, a stubbed sync has no account to
                // ask about, `SyncPlan.next` returns nil on its first call,
                // and the run completes as a silent, instant no-op — nothing
                // an empty-state UI test could ever observe mid-flight.
                if Launch.stubMonobank != nil,
                   let i = store.banks.firstIndex(where: { $0.id == "monobank" }),
                   store.banks[i].accounts.isEmpty {
                    // Mirrors `applyAccounts` inline rather than calling it —
                    // that method is `@MainActor` and `live()` is a plain
                    // synchronous function.
                    store.banks[i].accounts = MonobankStub.accounts.compactMap { account in
                        guard let currency = MonobankMapper.currency(account.currencyCode) else { return nil }
                        return Account(id: account.id, suffix: MonobankMapper.cardSuffix(account),
                                       type: account.type ?? "account", currency: currency,
                                       balance: account.balance, creditLimit: account.creditLimit)
                    }
                    store.persist()
                }
#endif
                store.settings.onboarded = true
                store.settings.startedUsingAt = Date()
                store.isUnlocked = Launch.stage != .locked
                store.persistNow()
            } else if Launch.stage == .onboarding {
                store.settings.onboarded = false
            }
        }
#if DEBUG
        // Task 13's two receipt cards, for the UI tests that need one to
        // already exist rather than land live — see `Launch.seedNoPurchaseReceipt`
        // / `.seedNotPublishedReceipt`. Guarded by register number so a
        // second `live()` call against the same (persisted, non-reset)
        // repository never duplicates the fixture.
        if Launch.seedNoPurchaseReceipt,
           !store.receipts.contains(where: { $0.registerNumber == Self.debugNoPurchaseReceipt.registerNumber }) {
            store.receipts.append(Self.debugNoPurchaseReceipt)
            store.persist()
        }
        if Launch.seedNotPublishedReceipt,
           !store.receipts.contains(where: { $0.registerNumber == Self.debugNotPublishedReceipt.registerNumber }) {
            let receipt = Self.debugNotPublishedReceipt
            store.receipts.append(receipt)
            store.receiptQueue.append(PendingReceipt(
                receiptId: receipt.id,
                check: FiscalCheck(registerNumber: receipt.registerNumber, documentNumber: receipt.documentNumber,
                                   fiscalTime: receipt.fiscalTime, fiscalSum: receipt.fiscalSum, mac: nil),
                scannedAt: Date().addingTimeInterval(-49 * 3600),
                attempts: 5,
                nextAttempt: Date().addingTimeInterval(-3600),
                lastError: "notPublished"))
            store.persist()
        }
        // Board #185. Attached to a real seeded purchase, because an
        // `.itemsWaiting` card that is NOT attached is a `.noPurchase` card —
        // the distinction is the whole point, so the fixture has to carry it.
        if Launch.seedItemsWaitingReceipt,
           !store.receipts.contains(where: { $0.registerNumber == Self.debugItemsWaitingReceipt.registerNumber }),
           let target = store.transactions.first(where: { $0.receiptId == nil && $0.amount < 0 }) {
            var receipt = Self.debugItemsWaitingReceipt
            receipt.fiscalSum = abs(target.amount)
            // One line worth exactly the purchase, so `SplitMath` can confirm
            // it — a fixture whose arithmetic is refused would test the
            // refusal path instead of the sorting one.
            receipt.items = [Receipt.Item(id: UUID(), name: "Тестовий товар В", qty: 1,
                                          price: abs(target.amount), sum: abs(target.amount),
                                          category: nil)]
            store.receipts.append(receipt)
            // The pointer written directly rather than through
            // `attachManually`, which is main-actor isolated and `live()` is
            // not. Safe only because this is a FIXTURE: `attach`'s extra work
            // is dropping whatever receipt the purchase already had, and this
            // branch selects a purchase that has none.
            if let index = store.transactions.firstIndex(where: { $0.id == target.id }) {
                store.transactions[index].receiptId = receipt.id
            }
            store.persist()
        }
#endif
        return store
    }

#if DEBUG
    /// A `.noPurchase` card: items already landed, matching no seeded
    /// transaction, its sum picked to equal the OLD bundled cafe sample's
    /// (287,01 ₴) so a receipt attached by hand against the 97,00 ₴ purchase
    /// still overshoots by exactly 190,01 ₴ — the figure `SplitTests` already
    /// asserts in its refusal copy. Invented seller and item names, never a
    /// real one — same rule `TaxCabinetStub` follows.
    private static let debugNoPurchaseReceipt = Receipt(
        id: UUID(), scannedAt: Date().addingTimeInterval(-3600),
        registerNumber: "5000000001", documentNumber: "5000000001",
        fiscalTime: Date().addingTimeInterval(-3600), fiscalSum: 287_01, sellerName: "",
        items: [
            Receipt.Item(id: UUID(), name: "Тестовий товар А", qty: 1, price: 143_50, sum: 143_50, category: nil),
            Receipt.Item(id: UUID(), name: "Тестовий товар Б", qty: 1, price: 143_51, sum: 143_51, category: nil),
        ],
        registerModel: nil, itemsLandedAt: Date().addingTimeInterval(-3500))

    /// A `.notPublished` card: no items, its `PendingReceipt` already past
    /// `ReceiptSchedule.giveUpAfter`.
    private static let debugNotPublishedReceipt = Receipt(
        id: UUID(), scannedAt: Date().addingTimeInterval(-49 * 3600),
        registerNumber: "5000000002", documentNumber: "5000000002",
        fiscalTime: Date().addingTimeInterval(-49 * 3600), fiscalSum: 120_00, sellerName: "", items: [])

    /// An `.itemsWaiting` card: goods landed, attached to a purchase, split
    /// not confirmed. Its sum and single item are filled in at injection time
    /// from whichever purchase it is attached to. Board #185.
    ///
    /// **A run of one repeated digit, which is not decoration.**
    /// `test_no_fiscal_lookup_key_literal_escapes_the_scrub` requires exactly
    /// that shape of any register or document number bound to the lookup
    /// key's own field names — a real one was found hand-typed into four
    /// files once, and the uniform run is what tells an invented number from
    /// a captured one at a glance. Its two siblings above predate the guard
    /// and are exempted by name; a new fixture has no business joining that
    /// list when conforming costs nothing.
    private static let debugItemsWaitingReceipt = Receipt(
        id: UUID(), scannedAt: Date().addingTimeInterval(-7200),
        registerNumber: "3333333333", documentNumber: "3333333333",
        fiscalTime: Date().addingTimeInterval(-7200), fiscalSum: 0, sellerName: "",
        items: [], registerModel: nil, itemsLandedAt: Date().addingTimeInterval(-600))
#endif
}
