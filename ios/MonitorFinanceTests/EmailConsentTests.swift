import XCTest
@testable import MonitorFinance

/// Board #113 — the email account is created by a tap, not by a screen.
///
/// The complaint was «I didn't add the mail, I just clicked done, and the mail
/// is already tied», and it was a literal description of the code:
/// `PrivatEmailSetupView` called `registerPrivatEmail` from `.onAppear`, so
/// *arriving* minted a server account. Registration is irreversible three ways
/// at once — the secret is shown exactly once, the account then collects a
/// person's mail, and it spends one of five registrations an hour.
final class EmailConsentTests: XCTestCase {

    /// **The defect, stated as the case that used to register.** Nothing on the
    /// device, nothing on screen — the screen must offer, not act.
    func testAnUntouchedDeviceIsOfferedTheChoice() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: false, address: "", hadIssuedAddress: false),
                       .offer)
    }

    /// The acceptance criterion that keeps the fix from becoming a nuisance:
    /// a device that already has an account is **not asked a second time**.
    func testAnAlreadyRegisteredDeviceIsNeverAskedAgain() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: true, address: "u-x@in.example.test",
                                                    hadIssuedAddress: false),
                       .connected)
    }

    /// Credentials alone are enough — the same widening `registerPrivatEmail`
    /// argues for. A stored pair whose address went missing (a partial write, a
    /// manual reset) is *registered*, and putting it back on the offer screen
    /// would invite a second account onto one device.
    func testStoredCredentialsWithNoAddressAreStillConnected() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: true, address: "", hadIssuedAddress: false),
                       .connected)
    }

    /// **The half that carries the screen across the tap.** The moment
    /// `connect()` writes the issued address into view state the screen must
    /// flip, without waiting for a Keychain read to be observed — otherwise the
    /// person who just tapped «Створити адресу» would be offered it again.
    ///
    /// It also covers the reconnect path, where a failed re-registration leaves
    /// a stale address with no credentials.
    func testAnIssuedAddressFlipsTheScreenOnItsOwn() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: false,
                                                    address: "u-x@in.example.test",
                                                    hadIssuedAddress: false),
                       .connected)
    }

    // MARK: - Board #111 — the third state

    /// **A phone that had an address and lost the secret is not a new phone.**
    ///
    /// The case: a restore onto a new device. `sync.json` comes back, the
    /// secret does not — it is stored `…ThisDeviceOnly`, which is deliberately
    /// excluded from backups and iCloud Keychain. Before this the state was
    /// indistinguishable from a fresh install, so the app offered «Створити
    /// адресу» and replacing the address was one silent tap away.
    func testAPhoneThatLostItsSecretIsOfferedAReissueNotAFirstSetup() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: false, address: "",
                                                    hadIssuedAddress: true),
                       .reissue)
    }

    /// Credentials win. A working connection is never called a reissue just
    /// because the flag says an address was once issued — it says that about
    /// every connected phone.
    func testAWorkingConnectionIsNeverCalledAReissue() {
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: true, address: "",
                                                    hadIssuedAddress: true),
                       .connected)
        XCTAssertEqual(PrivatEmailSetupView.arrival(hasCredentials: false,
                                                    address: "u-x@in.example.test",
                                                    hadIssuedAddress: true),
                       .connected)
    }

    /// **The control.** Every assertion above is only worth something if the
    /// function can return each answer — a rule that always said `.connected`
    /// would pass most of them and reinstate the exact defect. Extended to
    /// three, because a `.reissue` that could never be reached would leave
    /// board #111's warning as unreachable code that reads as done.
    func testTheRuleIsNotConstant() {
        let answers = Set([
            PrivatEmailSetupView.arrival(hasCredentials: false, address: "", hadIssuedAddress: false),
            PrivatEmailSetupView.arrival(hasCredentials: false, address: "", hadIssuedAddress: true),
            PrivatEmailSetupView.arrival(hasCredentials: true, address: "", hadIssuedAddress: false),
        ])
        XCTAssertEqual(answers.count, 3, "the rule must be able to say all three things")
    }
}
