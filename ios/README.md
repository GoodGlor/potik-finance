# MonitorFinance — iOS

SwiftUI app. Onboarding, PIN + Face ID lock, and bank connections
(monobank by token, PrivatBank by statement file or forwarded email) are
real and persist across launches. All five tabs (Головна, Стрічка, Бюджет,
Статистика, Розібрати) compute from the on-device store. A Debug build
also loads `Resources/demo.json`, a small invented ledger, so a fresh
clone has something to show.

## Run

Xcode is installed but not selected as the active developer directory, so
either `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
once, or prefix the commands below with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

This project builds to **iPhone 17 Pro**, and every command below names it
explicitly. A plain "iPhone 17" simulator also exists on this machine and is
a *different* device: targeting it gets its own install, its own Application
Support container and its own Keychain, so state you set up on one is
invisible on the other. Name the Pro, or you will debug two apps at once.

```bash
xcodebuild -project ios/MonitorFinance.xcodeproj -scheme MonitorFinance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install "iPhone 17 Pro" <path-to>/MonitorFinance.app
xcrun simctl launch "iPhone 17 Pro" ua.monitorfinance.app
```

Or just open `ios/MonitorFinance.xcodeproj`, pick iPhone 17 Pro as the run
destination, and press Run.

### Keychain needs Debug — code signing gotcha

The PIN is stored in the Keychain, which requires the process to carry a
valid code-signature and entitlements even in the simulator. The project
used to set `CODE_SIGNING_ALLOWED = NO` on every target/configuration,
which meant the simulator process had no entitlements at all and *every*
Keychain call failed with `errSecMissingEntitlement` (OSStatus -34018).

Debug configurations now set `CODE_SIGN_IDENTITY = "-"` (ad-hoc signing)
and `CODE_SIGNING_ALLOWED = YES`, which needs no certificate, team, or
Apple ID. **Release configurations were deliberately left alone.** Running
the app or the test suite with `-configuration Release` will fail every
PIN-related test with that same `-34018` error — this is expected, not a
regression, and eats an afternoon if you don't already know about it. Use
Debug (the xcodebuild default) for everything below.

## Launch arguments

Onboarding is a one-way door, so launch arguments let a screen be opened
directly and let every UI test start from a known state:

| argument | effect |
|---|---|
| `-resetState` | wipe Application Support, Keychain items, and lockout state before loading |
| `-skipOnboarding` | set PIN `1111`, connect monobank, open unlocked |
| `-stage onboarding\|locked\|unlocked` | open directly at that phase (`locked` implies `-skipOnboarding`, then shows the lock over it) |
| `-tab N` | 0 Головна · 1 Стрічка · 2 Бюджет · 3 Статистика · 4 Розібрати (e.g. `-tab 2` opens Бюджет directly) |
| `-noBiometrics` | treat Face ID as unavailable (tests never trigger the system prompt) |

```bash
xcrun simctl launch "iPhone 17 Pro" ua.monitorfinance.app -resetState -stage locked
```

## What is real and what is not

Real: the PIN (salted SHA-256 in Keychain, 5-attempt escalating lockout),
Face ID through LocalAuthentication with a PIN fallback, persistence of
settings and banks as JSON in Application Support, the bank picker /
token entry / connected flow, and the Settings › Банки screens
(list, detail, disconnect that keeps history). All five tabs compute from
the seeded ledger: Головна's four cards, Стрічка's month navigation, day
grouping, search and filter sheet, transaction detail with category
editing and merchant-rule creation, the category picker shared across
both, Статистика's week/month/year scopes with the donut, share list and
slice drill-through, and Розібрати's suggestion queue with skip and undo.
Settings' Категорії (rename/merge/delete), Дані (JSON export, app reset)
and Про додаток are real screens over the real store.

Бюджет computes a plan against the live ledger (`Budget/BudgetMath.swift`).
Percentages are shares of an income base the owner picks in a segmented
control: an average over the most recent 1/2/3/6/12 *complete* months
(the in-progress current month is excluded, and a chip says so when fewer
months exist than it asked for), or a typed fixed sum. Each line's actual
spend is read off the same seeded ledger and compared against its planned
₴; a line running over plan (or, for «Заощадження», under it) turns clay
and gets a one-line drift sentence, and the worst drift by ₴ surfaces on
Головна and at the top of the Бюджет tab too. Spend in a category the plan
doesn't name shows up under «Поза планом» with its own total. Saving a
plan creates any category its lines name that the store doesn't already
have — which is how «Заощадження» comes to exist even though the seed
never ships it. The starter plan offered on first open is explicitly
labelled a starting point, not a recommendation.

Networking: `Sync/MonobankClient` pulls statements from the monobank
personal API, `Sync/PrivatEmailClient` talks to the inbound email backend
(a placeholder host in this public copy), and `Receipts/TaxCabinetClient`
looks up fiscal receipts by their QR code. Each one has a stub behind a
launch argument (`-stubMonobank`, `-stubPrivatEmail`, `-stubTaxCabinet`),
and the UI tests run against those.

The demo ledger is `Resources/demo.json`: 62 invented transactions from
January to August 2026 on four cards, `*1001` to `*1004`, plus six sample
receipts. It is **generated, never hand-edited**:
`uv run python scripts/build_demo_sample.py` writes byte-identical output
on every run, and `tests/test_ios_seed.py` checks its shape.
`scripts/build_ios_seed.py` builds the same file from a private bank export
instead (the gitignored `data/finance-monitor.local.xlsx`); the tests that
compare against that export are skipped when it isn't present.

### The lock is its own window, and it hides the tab bar too

Two separate mechanisms, both required. Removing either one reopens a
hole.

**1. The lock is a `UIWindow` at `.alert + 1`** (`Auth/LockWindow.swift`),
not a view in the app's hierarchy. It used to be a `.zIndex(1)` overlay
inside `RootView`'s ZStack, and that cannot be made safe: a sheet, an
alert, a `confirmationDialog` or a scanner is presented by UIKit *above
the window's root view controller*, so no zIndex puts a SwiftUI view on
top of one. Backgrounding the app with any of them open re-locked the app
*underneath* the thing still showing the user's money. One such bypass was
live (disconnect-a-bank from a locked state) and had to be closed by hand.
Rather than audit every future presentation — stage 3 adds a filter sheet,
a category picker and a QR scanner — the lock stops competing.

The window is deliberately **not** made key. It doesn't need to be: hit
testing walks windows by level regardless of key status, and the keypad is
buttons, not a text field. Making it key would mean restoring key status
to the main window on dismiss, which is a race worth not having.

**2. `MainView` is still given `hideTabs: true` while locked**, applying
`.toolbar(.hidden, for: .tabBar)` to each tab individually (attaching it
only to the outer `TabView` is a no-op). A higher window does *not* remove
lower windows from the accessibility tree, and XCUITest's
`isHittable`/`exists` walk that tree, not the render tree — so without
this the tab bar stays reachable to a test even though nobody can see or
touch it. Belt and braces, on purpose.

## Tests

- Unit (`MonitorFinanceTests`, hosted in the app): 1,242 tests — seed
  decoding, repository, store, PIN store, Kyiv month bucketing, derived
  totals and slices, category rules, the exporter, and the budget's
  arithmetic and persistence (`BudgetMathTests`, `BudgetStoreTests`).
- UI (`MonitorFinanceUITests`): 173 tests — onboarding, lock, settings, and
  the five live-data tabs (feed navigation and search, transaction detail
  and category editing, statistics scopes, the queue's skip/undo/done
  flow, and the budget editor and plan-vs-actual view in `BudgetTests`).

```bash
ios/test.sh                                   # everything, ~9 min
ios/test.sh -only-testing:MonitorFinanceTests # unit only, ~20 s
```

**Use the wrapper, not bare `xcodebuild test`.** Besides the cleanup below,
it seeds the file `PrivatFileImportTests` picks — see the next section.

### The one test that needs a file on the device

`PrivatImportTests` walks the PrivatBank import with `-stubPrivatStatement`,
which hands the fixture straight to the importer. That covers the screens
either side of the file picker but never opens it, so the half that only
runs in production — presenting `.fileImporter`, the security-scoped URL it
hands back, reading bytes off disk — went untested.

`PrivatFileImportTests` is that half: it opens the real system Files sheet
and picks a real `.xlsx`, then asserts the fixture's true numbers (12 UAH
rows, cards `*1111, *2222`, 2 foreign-currency rows skipped).

Two things follow from the picker being a remote view:

- **A file has to already be on the device.** A test cannot put one in the
  Files sheet. `ios/seed-privat-statement.sh` writes the fixture into
  «On My iPhone» — decoded out of `PrivatStatementStub.swift`, so there is
  one fixture in the repo, not two. `ios/test.sh` runs it before the suite.
- **One tap is a coordinate.** The sheet publishes its navigation title and
  nothing else — no cells, no search field. So the file is tapped by
  position, and everything either side of that tap is a real assertion. A
  stale coordinate fails on the row counts rather than passing quietly.

Run it alone with:

```bash
ios/test.sh -only-testing:MonitorFinanceUITests/PrivatFileImportTests
```

**Cleanup.** The other reason for the wrapper: XCUITest cannot drive an
app from inside that app's own process, so `xcodebuild` builds and installs
a second app — `MonitorFinanceUITests-Runner`, bundle id
`ua.monitorfinance.uitests.xctrunner` — whose only job is to launch yours
and tap things in it. Xcode never removes it afterwards, so it lingers on
the home screen as a second, near-identically named icon that does nothing
when tapped. `ios/test.sh` uninstalls it when the run ends, pass or fail.

If one has already accumulated:

```bash
xcrun simctl uninstall booted ua.monitorfinance.uitests.xctrunner
```

The equivalent raw command, if you need to pass something the wrapper does
not forward:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project ios/MonitorFinance.xcodeproj -scheme MonitorFinance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Dates are Kyiv dates, always

`Models/Kyiv.swift` defines `Calendar.kyiv`, `TimeZone.kyiv` and
`MonthKey`. **Nothing may bucket, format or compare a transaction date
with `Calendar.current` or `TimeZone.current`.** The seed carries Kyiv
offsets and the Python side groups by Kyiv-local month; a device set to
another timezone would otherwise produce monthly sums that disagree with
the statement the owner reads in their bank app — and the whole budget
subsystem is built on those sums. `KyivTests` pins this with a fixture
that straddles a month boundary (2026-04-01 00:30 Kyiv is 2026-03-31
21:30 UTC), so switching to `Calendar.current` turns it red.

`isHittable`, not `exists`, is what these assert on buttons. An element
below the fold still exists — that distinction is the bug this suite was
written after, and reverting the fix turns the test red.

### Two quirks worth knowing before you add a test

- **SecureField text entry.** On this simulator, XCUITest's synthesized
  `typeText` does not reliably commit into a SwiftUI-bound `SecureField`
  while the software keyboard stays on its opening lowercase-letters page;
  it commits once the keyboard visits another page (e.g. after a digit).
  That's why the PIN/token strings in the tests contain a digit (`"t1"`,
  `"again1"`) instead of being pure lowercase — a field that looks
  untyped-into is usually this, not a real bug.
- **Occasional runner bootstrap flake.** A few runs on this branch have
  died with `Early unexpected exit... test runner crashed before
  establishing connection` and passed unchanged on an immediate rerun.
  Read the log before assuming it's this flake rather than a real
  failure — rerun once, and if it passes, it was the flake.
