import Foundation

/// Where the user is. Onboarding runs once; then the lock overlay gates the tabs.
enum AppPhase { case onboarding, locked, unlocked }

/// What `-stubTaxCabinet` asks the fake tax cabinet to do. Top-level, and
/// outside the `#if DEBUG` fence, for the same reason as `AppPhase`: the
/// `#else` branch of `Launch.stubTaxCabinet` still needs the type to exist
/// for its return type, even though only Debug ever reads it.
enum CheckStubMode: String { case ok, notPublished, offline, throttled }

/// Launch arguments, so a screen can be opened directly and every UI test can
/// start clean: `simctl launch … -resetState -skipOnboarding -tab 3`.
enum Launch {
    /// What `-stubMonobank` asks the fake bank to do.
    enum StubMode: String { case ok, fail403, fail429, offline }

    /// Pure, so it can be tested without launching a process. A bare
    /// `-stubMonobank` means `.ok`; so does an unrecognised word, and so does
    /// a following argument that is itself a flag — `-stubMonobank -resetState`
    /// is the order a person naturally writes, and reading `-resetState` as a
    /// mode would silently disable the stub.
    static func stubMode(from args: [String]) -> StubMode? {
        guard let i = args.firstIndex(of: "-stubMonobank") else { return nil }
        guard i + 1 < args.count else { return .ok }
        return StubMode(rawValue: args[i + 1]) ?? .ok
    }

    /// What `-stubPrivatEmail` asks the fake email backend to do.
    enum EmailStubMode: String { case ok, fail401, offline }

    /// Pure, same shape as `stubMode(from:)` above and for the same reason:
    /// testable without a process launch, and a following flag must not be
    /// misread as a mode.
    static func emailStubMode(from args: [String]) -> EmailStubMode? {
        guard let i = args.firstIndex(of: "-stubPrivatEmail") else { return nil }
        guard i + 1 < args.count else { return .ok }
        return EmailStubMode(rawValue: args[i + 1]) ?? .ok
    }

#if DEBUG
    private static let args = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Wipe Application Support, the app's Keychain items and lockout state before loading.
    static var resetState: Bool { args.contains("-resetState") }

    /// Clear only the stored PIN (and its lockout state), leaving Application
    /// Support — banks, transactions, `settings.onboarded` — untouched. Lets
    /// a test reproduce "onboarded, bank connected, but no PIN": the state a
    /// restore from backup leaves, since Application Support is included in
    /// iCloud/iTunes backups but the Keychain PIN deliberately is not.
    static var forgetPin: Bool { args.contains("-forgetPin") }

    /// `-stage onboarding|locked|unlocked`.
    static var stage: AppPhase? {
        switch value(after: "-stage") {
        case "onboarding": return .onboarding
        case "locked": return .locked
        case "unlocked": return .unlocked
        default: return nil
        }
    }

    /// Skip the first-run flow: PIN `testPin`, monobank connected. `-stage
    /// locked` and `-stage unlocked` imply it; `-stage locked` then shows the lock.
    static var skipOnboarding: Bool {
        args.contains("-skipOnboarding") || stage == .locked || stage == .unlocked
    }

    /// 0 Головна · 1 Стрічка · 2 Бюджет · 3 Статистика · 4 Розібрати
    static var tab: Int { value(after: "-tab").flatMap(Int.init) ?? 0 }

    /// Treat Face ID as unavailable — tests never trigger the system prompt.
    static var noBiometrics: Bool { args.contains("-noBiometrics") }

    /// Offer the scanner one extra picker row whose check number `store.scan`
    /// has never seen, so it takes its honest fresh-shell, no-goods branch.
    /// That branch is what EVERY scan on a real device produces, and without
    /// this there is no way to reach it in a simulator at all — the picker
    /// only ever offers checks already in the bundled catalogue.
    static var emptyReceiptSample: Bool { args.contains("-emptyReceiptSample") }

    /// `-noGuide` — start with board #60's guide already stamped seen.
    ///
    /// `-skipOnboarding` does this implicitly (it means "pretend the first run
    /// happened"), but nine UI classes walk onboarding for real and then test
    /// something else entirely. Without the flag each of them would have to
    /// dismiss a sheet it never asked about, in a step that has nothing to do
    /// with what it is checking — and the day the guide gains a page, all nine
    /// would need editing.
    ///
    /// Exactly one test does NOT pass it: the first-run walk in
    /// `OnboardingTests`, which is where the guide belongs.
    static var noGuide: Bool { args.contains("-noGuide") }

    /// Board #107. `-showGuide` — the exact opposite, and it exists because
    /// **`-skipOnboarding` already stamps the guide seen**: it means "pretend
    /// the first run happened", and the first-launch walkthrough is part of a
    /// first run.
    ///
    /// Without this, the only way to reach the walkthrough in a test is to
    /// walk real onboarding — a minute of PIN taps per test, to arrive at the
    /// same state `-skipOnboarding` reaches in a second. It wins over that
    /// stamp, and over `-noGuide`, so it can be added to any existing launch
    /// list without editing it.
    static var showGuide: Bool { args.contains("-showGuide") }

    /// `-lang uk|en` — pin the interface language.
    ///
    /// **Every UI test that reads Ukrainian copy passes this**, and the
    /// alternative was worse than a launch argument. The default is «як у
    /// системі», a simulator's system language is English, and the suite finds
    /// its buttons by their visible Ukrainian labels — so without a pin, three
    /// hundred assertions would depend on a device setting no test names.
    /// Pinning makes the dependency visible, and it is what an English UI test
    /// would use in the other direction.
    static var language: AppLanguage? { value(after: "-lang").flatMap(AppLanguage.init(rawValue:)) }

    /// `-stalePlan` — start with a budget stamped for LAST month, so board
    /// #62's carry-forward-or-re-plan offer is on screen.
    ///
    /// The state cannot otherwise be reached from a test: a plan written
    /// during a test run belongs to the month the run is in, and no test can
    /// move the calendar. The store's own decision logic takes an injected
    /// `now` and is unit-tested with one; this is the only way to see the
    /// card that offers the choice.
    static var stalePlan: Bool { args.contains("-stalePlan") }

    /// `-plan` — start with a budget belonging to THIS month, so the filled
    /// budget screen is on the first frame.
    ///
    /// A launch argument for the same reason as `-stalePlan`: reaching this
    /// state honestly means walking the percent editor, which is a minute of
    /// taps per test to arrive somewhere a test about something else needs to
    /// START. Unlike `-stalePlan` it raises no carry-forward card, which is
    /// exactly the noise a scope test does not want.
    static var plan: Bool { args.contains("-plan") }

    /// `-statements` — start with an imported statement already recorded, so
    /// board #148's «Виписки» list and its two-way delete are on screen.
    ///
    /// The state cannot otherwise be reached from a UI test: arriving at it
    /// honestly means picking a file through the document picker, which a
    /// test cannot drive, and `-stubPrivatStatement` still needs the tap that
    /// opens it. The record is what this list is about, so the record is what
    /// gets seeded.
    static var statements: Bool { args.contains("-statements") }


    /// `-twoKindRules` — one merchant carrying a rule for its spending and
    /// another for its income, so board #81's rules screen can be looked at.
    ///
    /// A launch argument for the same reason as `-stalePlan` and
    /// `-corruptFile`: **no test can reach the state any other way.** Two
    /// rules are taught by answering the same merchant's expense and its
    /// income in the queue, and no merchant in `demo.json` has a pending row
    /// of both kinds — measured, not assumed. Without this the only assertion
    /// left about the screen would be that a single-rule merchant carries no
    /// qualifier, which is the half that was already true.
    static var twoKindRules: Bool { args.contains("-twoKindRules") }

    /// `-corruptFile transactions` — write valid JSON of the wrong shape into
    /// one stored document before the store loads it. Board #68.
    ///
    /// The only way to reach the state from a UI test: a corrupt file has to
    /// exist BEFORE `AppStore.init` runs, and a test process cannot reach
    /// Application Support inside the app's container. Debug-only like every
    /// other launch argument, and it writes through `Repository.save` rather
    /// than a new raw-write API, so nothing exists here that a Release build
    /// could call even if the flag did.
    static var corruptFile: String? { value(after: "-corruptFile") }

    /// Replace the network with a canned bank. Present for every UI test:
    /// without it the suite calls api.monobank.ua, which allows one request a
    /// minute, so the second test in a run fails and the suite needs a live
    /// token to pass at all.
    static var stubMonobank: StubMode? { stubMode(from: args) }

    /// Replace the network with a canned email backend. Same reason as
    /// `stubMonobank`: without it a UI test would talk to the real
    /// PrivatBank-email backend and need live credentials to pass at all.
    static var stubPrivatEmail: EmailStubMode? { emailStubMode(from: args) }

    /// Board #111. **The state a restore onto a new phone leaves**: the data
    /// file came back, the Keychain did not — the secret is stored
    /// `…ThisDeviceOnly`, which is deliberately excluded from backups and
    /// iCloud Keychain.
    ///
    /// It exists because nothing else can produce that state in a simulator.
    /// A UI test cannot restore a backup, and `simctl uninstall` wipes the
    /// Keychain AND the container together, which is the opposite pairing —
    /// and, incidentally, is why the reinstall question this card opens with
    /// cannot be answered on a simulator at all.
    ///
    /// Used with `-stubPrivatEmail`, whose shortcut it deliberately overrides:
    /// bank connected, an address remembered, no credentials.
    static var emailKeyLost: Bool { args.contains("-emailKeyLost") }

    /// `-stubTaxCabinet ok|notPublished|offline|throttled`. The simulator has
    /// no camera, so every UI test scans through the sample picker; without a
    /// stub behind it the suite would talk to the tax service.
    static var stubTaxCabinet: CheckStubMode? {
        guard let i = args.firstIndex(of: "-stubTaxCabinet"), i + 1 < args.count else { return nil }
        return CheckStubMode(rawValue: args[i + 1]) ?? .ok
    }

    static let testPin = "1111"

    /// Start with no transactions at all — the state a real first launch is in
    /// once demo data no longer ships. The only way to reach the loading and
    /// empty screens in a simulator.
    static var noDemoData: Bool { args.contains("-noDemoData") }

    /// How long `MonobankStub` holds its first statement answer under
    /// `-noDemoData`, in seconds. `-stubStatementDelay 600`.
    ///
    /// The default is the 3.5 s the stub used to hardcode, which every UI
    /// suite relying on it keeps. `EmptyStateTests` raises it instead of
    /// racing it: those five tests need the sync to be IN FLIGHT, never to
    /// finish, and `assertLive` reads hittability immediately — so their
    /// usable window was `[launch() returns, t₀ + 3.5 s]` and `launch()`
    /// returns on UI quiescence, which does not wait on a background
    /// `Task.sleep`. A loaded machine could spend the whole margin on app
    /// launch and accessibility bootstrap, and the failure then read as "not
    /// on screen or obstructed" — a view bug that was not there. A delay no
    /// machine can outrun turns the margin into "the stub does not answer
    /// during this test", which cannot race.
    static var stubStatementDelay: Double {
        value(after: "-stubStatementDelay").flatMap(Double.init) ?? 3.5
    }

    /// Feed `ImportStatementView` the invented statement instead of the
    /// system file picker — XCUITest cannot drive the Files sheet.
    static var stubPrivatStatement: Bool { args.contains("-stubPrivatStatement") }

    /// Board #97. `-stubEmailStatement` — a statement is waiting on the
    /// backend, as if somebody had forwarded their export to the issued
    /// address. Off by default so no existing suite grows an import it never
    /// asked for.
    static var stubEmailStatement: Bool { args.contains("-stubEmailStatement") }

    /// Board #97. `-stubNoStatementRoute` — the backend predates this card and
    /// answers 404 for `/statements`, which is what a phone updated ahead of
    /// its server actually meets. Distinct from "nothing is waiting", and the
    /// distinction is the point: one is an empty list, the other is a failing
    /// request that must not reach the screen.
    static var stubNoStatementRoute: Bool { args.contains("-stubNoStatementRoute") }

    /// Board #145. `-stubStatementLink` — PrivatBank emailed a download link
    /// instead of a file, and the bank screen has to offer it.
    static var stubStatementLink: Bool { args.contains("-stubStatementLink") }

    /// Board #175. `-stubRecentLetters` — three invented letters covering the
    /// three states worth telling apart: one that became a transaction, one
    /// the app could not read, and one that is not a bank letter at all.
    ///
    /// Off by default so the «Листів ще немає» state stays reachable, and so
    /// every existing suite goes on seeing the screen it was written against.
    static var stubRecentLetters: Bool { args.contains("-stubRecentLetters") }

    /// Inject a `.noPurchase` receipt card straight into `AppStore.receipts`
    /// at launch, unattached and already carrying items. A UI test cannot
    /// reach this state for real: it needs the tax cabinet's async fetch, and
    /// `fetchDueReceiptsIfAllowed` itself suppresses that under `-stage
    /// locked`/`unlocked` to protect other suites' fixed fixtures (see that
    /// method's own doc comment) — the same launch shape every UI test in
    /// this app uses. Opt-in and named by no other test's launch arguments,
    /// so it changes nothing anywhere else.
    ///
    /// NOT `ReceiptTests`' own business only: `SplitTests.attachCafeReceipt`
    /// consumes this too, as its way to get an item-bearing receipt onto a
    /// purchase without a live scan-and-wait — its two callers start from
    /// this injected fixture rather than a real scan. Changing what this
    /// flag seeds (the fixture's sum in particular — picked to equal the
    /// OLD bundled cafe sample's own, 287,01 ₴) moves `SplitTests`' refusal
    /// copy assertion too.
    static var seedNoPurchaseReceipt: Bool { args.contains("-seedNoPurchaseReceipt") }

    /// Inject a `.notPublished` receipt card: a loose receipt plus a
    /// `PendingReceipt` scanned 49 (simulated) hours ago. `ReceiptSchedule
    /// .hasGivenUp`'s 48-hour boundary cannot be reached by a real UI test
    /// waiting in real time, so this fixture is built already past it.
    static var seedNotPublishedReceipt: Bool { args.contains("-seedNotPublishedReceipt") }

    /// Inject an `.itemsWaiting` receipt card — board #185: a receipt whose
    /// goods have landed, ATTACHED to a seeded purchase, with the split not
    /// yet confirmed.
    ///
    /// A fixture rather than a live scan for the same reason the two above
    /// are one: reaching this state for real means scanning, then waiting for
    /// the tax service to publish, which a UI test cannot do — and it is
    /// precisely the wait this card exists to make survivable.
    static var seedItemsWaitingReceipt: Bool { args.contains("-seedItemsWaitingReceipt") }

    /// Offer TWO waiting statements instead of one — board #187's whole
    /// subject. One is the state that hides the bug: with a single button
    /// there is nothing to tell apart and the screen looks fine.
    static var stubTwoStatements: Bool { args.contains("-stubTwoStatements") }
#else
    // These launch arguments (resetState/skipOnboarding/testPin bypass PIN
    // entry, noBiometrics disables Face ID) must never be reachable from a
    // Release build, so the whole reading path compiles out and these are
    // fixed, harmless stubs instead.
    //
    // **This list is not meant to mirror the Debug branch, and completing it
    // would be wrong.** `emailKeyLost` and `stubStatementDelay` are absent on
    // purpose: every one of their call sites is itself inside `#if DEBUG`
    // (`AppStore`'s email-key branch, and `MonobankStub.swift`, which is
    // fenced end to end), so Release never names them and a stub here would
    // be dead code pretending to be a contract. What must hold is narrower
    // and is what board #151 broke: a `Launch.x` REACHABLE in Release has to
    // be declared in Release. `tests/test_ios_launch_fences.py` checks
    // exactly that, and fences the difference so neither half drifts again.
    static var resetState: Bool { false }
    static var forgetPin: Bool { false }
    static var stage: AppPhase? { nil }
    static var skipOnboarding: Bool { false }
    static var tab: Int { 0 }
    static var noBiometrics: Bool { false }
    static var emptyReceiptSample: Bool { false }
    static var corruptFile: String? { nil }
    static var noGuide: Bool { false }
    /// Board #151. Missing here since #107 added `-showGuide`, which made
    /// **Release stop compiling** — `AppStore`'s call site sits outside a
    /// fence, so Release read a member that did not exist. Debug builds and
    /// the whole test suite are blind to it: they only ever build Debug.
    /// `tests/test_ios_launch_fences.py` now fails on the next one.
    static var showGuide: Bool { false }
    static var stalePlan: Bool { false }
    static var plan: Bool { false }
    static var statements: Bool { false }
    static var twoKindRules: Bool { false }
    static var language: AppLanguage? { nil }

    /// Never a stub in Release. The stub type itself does not compile there.
    static var stubMonobank: StubMode? { nil }

    /// Never a stub in Release. `PrivatEmailStub` itself does not compile there.
    static var stubPrivatEmail: EmailStubMode? { nil }

    /// Never a stub in Release. The stub type itself does not compile there.
    static var stubTaxCabinet: CheckStubMode? { nil }

    static let testPin = "1111"

    /// Release never has demo data to suppress.
    static var noDemoData: Bool { true }

    /// Never a stub in Release. `PrivatStatementStub` itself does not compile there.
    static var stubPrivatStatement: Bool { false }
    static var stubEmailStatement: Bool { false }
    static var stubNoStatementRoute: Bool { false }
    static var stubStatementLink: Bool { false }
    static var stubRecentLetters: Bool { false }

    static var seedNoPurchaseReceipt: Bool { false }
    static var seedNotPublishedReceipt: Bool { false }
    static var seedItemsWaitingReceipt: Bool { false }
    static var stubTwoStatements: Bool { false }
#endif
}
