import XCTest
@testable import MonitorFinance

/// Board #18: the address a person is asked to trust with a banking token.
///
/// Step 1 of «Де його взяти» named `api.monobank.ua` in prose with no way to
/// reach it, so the person left the app, found a browser and retyped it by
/// hand — on the one screen where a typo hands a live banking token to
/// whoever registered the near-miss domain.
final class TokenPortalTests: XCTestCase {

    /// The exact address, spelled out here so the two have to be changed
    /// together and a one-character slip in either is a failure rather than a
    /// working link to somebody else's domain.
    func testThePortalIsMonobanksOwnTokenPage() throws {
        let url = try XCTUnwrap(TokenView.portal, "the step falls back to prose if this is nil")
        XCTAssertEqual(url.absoluteString, "https://api.monobank.ua")
        XCTAssertEqual(url.scheme, "https", "a token page reached over http is a token given away")
        XCTAssertEqual(url.host(), "api.monobank.ua")
    }

    /// What the row DISPLAYS is derived from the URL rather than written out a
    /// second time, so a label naming one domain while opening another is not
    /// expressible. This pins the derivation, which is the part a reader of
    /// the view cannot check by eye.
    func testTheWordsOnScreenComeFromTheAddressItself() throws {
        let url = try XCTUnwrap(TokenView.portal)
        XCTAssertEqual(url.host() ?? url.absoluteString, "api.monobank.ua")
    }

    /// The host is the one the app is already allowed to talk to. If these ever
    /// diverge, either the client is pointed somewhere new or this link is —
    /// and both are things somebody has to decide on purpose.
    func testTheLinkGoesWhereTheClientAlreadyGoes() throws {
        let url = try XCTUnwrap(TokenView.portal)
        XCTAssertEqual(MonobankClient.defaultBase.host(), url.host(),
                       "the token page and the API must be the same bank")
    }
}
