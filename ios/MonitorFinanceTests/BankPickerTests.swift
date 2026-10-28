import XCTest
@testable import MonitorFinance

/// Board #19: a bank row answers on one tap, so the row itself has to say
/// whether tapping it will do anything.
///
/// The chevron and the tap are now driven by the same predicate, which means
/// a row can no longer promise a destination it will not go to. **Both
/// branches are tested here rather than in the UI**, because the seed ships
/// exactly two banks and neither is `comingSoon`: a chevron wrongly drawn on
/// an unpickable bank would have shipped through a green UI suite.
final class BankPickerTests: XCTestCase {

    private func bank(_ status: BankStatus, connected: Bool = false) -> Bank {
        Bank(id: "test-bank", displayName: "Тестовий банк", status: status,
             connected: connected, accounts: [])
    }

    // MARK: what may be tapped

    func testAnUnconnectedBankIsSelectableEverywhere() {
        for allow in [true, false] {
            XCTAssertTrue(BankPickerView.isSelectable(bank(.available), allowConnected: allow))
            XCTAssertTrue(BankPickerView.isSelectable(bank(.statement), allowConnected: allow))
        }
    }

    /// «скоро» is not an invitation. It stays unpickable however it is reached
    /// — `allowConnected` widens which CONNECTED banks may be re-picked, and
    /// must not quietly widen this too.
    func testABankThatIsNotReadyIsNeverSelectable() {
        for allow in [true, false] {
            XCTAssertFalse(BankPickerView.isSelectable(bank(.comingSoon), allowConnected: allow))
            XCTAssertFalse(BankPickerView.isSelectable(bank(.comingSoon, connected: true),
                                                      allowConnected: allow))
        }
    }

    /// Settings' picker: offering a bank that is already connected as if it
    /// were a new one is how a person ends up re-doing setup they finished.
    func testAConnectedBankIsNotOfferedAgainInSettings() {
        XCTAssertFalse(BankPickerView.isSelectable(bank(.available, connected: true),
                                                   allowConnected: false))
    }

    /// Onboarding's exception, and the reason it exists: a run that connected
    /// a bank and then lost its PIN restores Application Support without the
    /// Keychain, so the picker is where re-onboarding has to re-paste a token.
    /// Without this the picker itself becomes the new dead end.
    func testOnboardingMayReofferAConnectedBank() {
        XCTAssertTrue(BankPickerView.isSelectable(bank(.available, connected: true),
                                                  allowConnected: true))
    }

    // MARK: the seed the screen actually draws

    /// The precondition the UI tests rest on, stated where it can be seen: if
    /// a `comingSoon` bank is ever seeded, the UI suite starts covering the
    /// disabled branch and this test says so rather than silently passing.
    func testTheSeedShipsNoBankTheUiSuiteCouldTestTheDisabledCaseWith() throws {
        let banks = try SeedLoader.load().banks
        XCTAssertFalse(banks.isEmpty, "precondition: the picker has rows to draw")
        XCTAssertTrue(banks.allSatisfy { $0.status != .comingSoon },
                      "a seeded «скоро» bank makes the disabled row reachable from a UI test")
        XCTAssertTrue(banks.allSatisfy { BankPickerView.isSelectable($0, allowConnected: true) },
                      "every seeded bank must be pickable on a first run")
    }

    // MARK: which bank has two ways in

    /// Board #91. Keyed on the ID, not on `.status`, and THAT is the claim: a
    /// second `.statement` bank would have a file to import and no email
    /// backend behind it, so offering it a two-way choice would promise a
    /// source that does not exist. `bank(.statement)` is exactly that bank —
    /// same status, different id — which is why both branches are reachable
    /// here without a simulator.
    func testOnlyPrivatBankHasASecondSource() {
        let privat = Bank(id: "privatbank", displayName: "ПриватБанк",
                          status: .statement, connected: false, accounts: [])
        XCTAssertTrue(privat.hasEmailSource)
        XCTAssertFalse(bank(.statement).hasEmailSource,
                       "a statement bank that is not PrivatBank has no letters to offer")
        XCTAssertFalse(bank(.available).hasEmailSource)
    }

    /// The seeded id and the mapper's must be the same string, or the picker
    /// sends people to a choice screen for a bank the sync half never writes.
    func testTheSeededPrivatBankIsTheOneWithLetters() throws {
        let banks = try SeedLoader.load().banks
        XCTAssertEqual(banks.filter(\.hasEmailSource).map(\.id), [PrivatMapper.bankId])
    }
}
