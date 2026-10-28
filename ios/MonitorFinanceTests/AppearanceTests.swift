import XCTest
import SwiftUI
@testable import MonitorFinance

/// Board #58. The app had one appearance; it now follows the system by
/// default and can be pinned to light or dark by hand.
///
/// The mapping and the persistence are here; the palette's own numbers are in
/// `StatsColourTests`, which measures both schemes.
@MainActor
final class AppearanceTests: XCTestCase {

    private func makeStore(_ repository: Repository = MemoryRepository()) -> AppStore {
        let seed = SeedBundle(transactions: [], banks: [], categories: [],
                              rules: [], receipts: [], productGroups: [])
        return AppStore(repository: repository, seed: seed,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    func testAFreshInstallFollowsTheSystem() {
        let store = makeStore()
        XCTAssertNil(store.settings.appearance, "nothing written until somebody chooses")
        XCTAssertEqual(store.settings.appearanceChoice, .system)
        XCTAssertNil(store.settings.appearanceChoice.colorScheme,
                     "nil is `preferredColorScheme`'s own word for «do not override»")
    }

    func testTheTwoManualChoicesPinTheScheme() {
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
    }

    /// The lock is a second `UIWindow` (`LockWindow`), and
    /// `preferredColorScheme` reaches only the window SwiftUI owns. Without
    /// this mapping a person who pinned the app to dark met a light lock
    /// screen — the first thing the app shows, in the wrong appearance.
    ///
    /// `.unspecified` is UIKit's word for the nil `colorScheme` returns, so
    /// the two must agree about which case means "do not override".
    func testTheLockWindowTakesTheSameChoice() {
        XCTAssertEqual(Appearance.system.uiStyle, .unspecified)
        XCTAssertEqual(Appearance.light.uiStyle, .light)
        XCTAssertEqual(Appearance.dark.uiStyle, .dark)
        for choice in Appearance.allCases {
            XCTAssertEqual(choice.colorScheme == nil, choice.uiStyle == .unspecified,
                           "\(choice) means one thing to SwiftUI and another to UIKit")
        }
    }

    func testEveryChoiceIsOfferedAndNamed() {
        XCTAssertEqual(Appearance.allCases, [.system, .light, .dark],
                       "the order the picker shows, with the default first")
        for choice in Appearance.allCases {
            XCTAssertFalse(choice.title.isEmpty)
            XCTAssertNotEqual(choice.title, choice.rawValue,
                              "\(choice) would appear on screen as an English identifier")
        }
    }

    /// The point of persisting it: a choice that did not survive a relaunch
    /// would be a preference the app forgets every morning.
    ///
    /// No `persistNow()`, on purpose — the debounce is what has to do the
    /// work. `BudgetStoreTests` records why: every persistence test that calls
    /// `persistNow()` by hand stays green when the `persist()` call is deleted
    /// from the mutation it claims to be testing.
    func testTheChoiceSurvivesARelaunch() async throws {
        let repo = MemoryRepository()
        let store = makeStore(repo)
        store.setAppearance(.dark)
        XCTAssertEqual(store.settings.appearanceChoice, .dark, "in memory at once")

        try await Task.sleep(for: .milliseconds(1_200))   // past the 300 ms debounce

        let next = makeStore(repo)
        XCTAssertEqual(next.settings.appearanceChoice, .dark)
        XCTAssertEqual(next.settings.appearanceChoice.colorScheme, .dark)
    }

    /// And going back to «Як у системі» has to be a real choice, not just
    /// "nothing chosen": it must be written, so a later build cannot read the
    /// absence as "never asked" and start guessing.
    func testChoosingTheSystemAgainIsItselfWrittenDown() {
        let store = makeStore()
        store.setAppearance(.dark)
        store.setAppearance(.system)

        XCTAssertEqual(store.settings.appearance, .system, "written, not cleared")
        store.persistNow()
        XCTAssertEqual(store.settings.appearanceChoice, .system)
    }

    /// Every `Theme` colour is dynamic now. A `static let` that was left as a
    /// plain `Color` would look right in the light scheme and be invisible in
    /// the dark one — which is exactly the failure nobody notices until a
    /// screenshot, so it is asserted rather than eyeballed.
    func testEveryPaletteColourActuallyRespondsToTheAppearance() {
        let palette: [(String, Color)] = [
            ("bg", Theme.bg), ("card", Theme.card), ("ink", Theme.ink),
            ("inkSoft", Theme.inkSoft), ("inkMuted", Theme.inkMuted),
            ("clay", Theme.clay), ("clayLight", Theme.clayLight),
            ("green", Theme.green), ("greenWash", Theme.greenWash),
            ("hair", Theme.hair), ("cardShadow", Theme.cardShadow),
        ]
        for (name, colour) in palette {
            let light = UIColor(colour).resolvedColor(with: .init(userInterfaceStyle: .light))
            let dark = UIColor(colour).resolvedColor(with: .init(userInterfaceStyle: .dark))
            XCTAssertNotEqual(light, dark, "Theme.\(name) is the same in both appearances")
        }
    }
}
