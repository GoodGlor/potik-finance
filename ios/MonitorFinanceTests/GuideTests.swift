import XCTest
@testable import MonitorFinance

/// Board #60. The short guide's content and its one piece of state.
///
/// The presentation is in `OnboardingTests` (the first run) and
/// `SettingsTests` (re-opening it); what is here is everything that can be
/// asked without a simulator.
@MainActor
final class GuideTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(_ repository: Repository = MemoryRepository()) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [], categories: [],
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    // MARK: seen, once

    func testAFreshInstallHasNotSeenIt() {
        let store = makeStore()
        XCTAssertNil(store.settings.guideSeenAt)
        XCTAssertFalse(store.settings.hasSeenGuide)
    }

    func testDismissingItStampsTheTime() {
        let store = makeStore()
        store.markGuideSeen(now: t0)
        XCTAssertEqual(store.settings.guideSeenAt, t0)
        XCTAssertTrue(store.settings.hasSeenGuide)
    }

    /// Re-opening it from Налаштування must not move the stamp. The date says
    /// when the guide was FIRST read, and a screen that rewrote it every time
    /// somebody looked would be recording the last visit under the name of the
    /// first — a small lie, in the one field that could answer "did the first
    /// run explain anything".
    func testReReadingItDoesNotMoveTheStamp() {
        let store = makeStore()
        store.markGuideSeen(now: t0)
        store.markGuideSeen(now: t0 + 86_400)
        XCTAssertEqual(store.settings.guideSeenAt, t0)
    }

    /// No `persistNow()` — the debounce is what has to do the work. The first
    /// version of this test called it by hand and stayed green when
    /// `markGuideSeen`'s own `persist()` was deleted: it was testing
    /// `persistNow`, not the mutation. `BudgetStoreTests` records that trap;
    /// this is it happening again.
    func testItStaysSeenAcrossARelaunch() async throws {
        let repo = MemoryRepository()
        let store = makeStore(repo)
        store.markGuideSeen(now: t0)

        try await Task.sleep(for: .milliseconds(1_200))   // past the 300 ms debounce

        XCTAssertTrue(makeStore(repo).settings.hasSeenGuide,
                      "a guide that came back every launch would be the app not listening")
    }

    /// A reset is a fresh start, and that includes being shown the guide
    /// again — somebody who wiped the app is in the position the guide was
    /// written for.
    func testAResetPutsThePersonBackBeforeTheGuide() {
        let store = makeStore()
        store.markGuideSeen(now: t0)
        store.resetEverything()
        XCTAssertFalse(store.settings.hasSeenGuide)
    }

    // MARK: what it says

    func testFourPagesEachSayingOneThing() {
        XCTAssertEqual(GuideView.pages.count, 4)
        XCTAssertEqual(GuideView.pages.map(\.id), [0, 1, 2, 3],
                       "the tags the TabView selects on")
        for page in GuideView.pages {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.body.isEmpty)
            XCTAssertFalse(page.icon.isEmpty)
        }
    }

    /// The four verbs the app actually has, one per page. A guide that
    /// explained three of them and something else would be the kind of thing
    /// that reads fine and teaches the wrong app.
    func testThePagesCoverTheFourThingsTheAppDoes() {
        let text = GuideView.pages.map { $0.title + " " + $0.body }.joined(separator: "\n")
        for subject in ["банку", "Розібрати", "Бюджет", "чек"] {
            XCTAssertTrue(text.contains(subject), "no page mentions \(subject)")
        }
    }

    /// Board #17's rule, which this card inherits: the way out of something a
    /// person is allowed to be finished with must not tell them they are
    /// missing out. Asserted on the copy, because the copy is the whole point.
    func testNothingInTheGuideCallsItselfSkipping() {
        let text = (GuideView.pages.map { $0.title + $0.body }).joined()
        XCTAssertFalse(text.contains("Пропустити"))
    }
}
