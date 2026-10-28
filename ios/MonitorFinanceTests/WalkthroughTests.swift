import XCTest
@testable import MonitorFinance

/// Board #107 — the walkthrough that is operated rather than read.
///
/// Almost all of this card is a view, and `WalkthroughUITests` is where it is
/// actually proved. **One rule is not a view**, and it is the one that can
/// silently strand somebody: a step finished by "go to that tab" can never be
/// finished if they are already on it, because no tab change will ever arrive.
///
/// It is not a hypothetical. The walkthrough opens on Головна and one of its
/// steps asks for Головна, so the bug fires in ordinary use, on the owner's
/// first launch, with no way out except «Закрити».
@MainActor
final class WalkthroughTests: XCTestCase {

    /// **The defect, stated as the case that would hang.**
    func testAStepAskingForTheTabYouAreAlreadyOnIsSkipped() {
        // Step 3 asks for Головна (tab 0). Standing there, it must not be
        // where the tour stops.
        let landed = Walkthrough.first(from: 3, tab: 0)
        XCTAssertEqual(landed, 4, "a reachTab step for the current tab cannot ever finish")
        XCTAssertEqual(Walkthrough.steps[landed].advance, .button(title: "Зрозуміло"))
    }

    /// The ordinary opening: the first step is a button, so nothing is skipped
    /// and the tour starts where it is written to start.
    func testTheTourStartsAtItsFirstStep() {
        XCTAssertEqual(Walkthrough.first(from: 0, tab: 0), 0)
        XCTAssertEqual(Walkthrough.first(from: 0, tab: 4), 0)
    }

    /// A step for a DIFFERENT tab is never skipped — the skip must be narrow,
    /// or the tour would fast-forward past the flows it exists to teach.
    func testAStepForAnotherTabIsNotSkipped() {
        // Step 1 asks for Розібрати (tab 4); standing on Головна, it stands.
        XCTAssertEqual(Walkthrough.first(from: 1, tab: 0), 1)
        // …and standing on Розібрати, it is skipped to the budget step.
        XCTAssertEqual(Walkthrough.first(from: 1, tab: 4), 2)
    }

    /// Running off the end is how the tour finishes, so the function must be
    /// allowed to return an index past the last step rather than clamping —
    /// clamping would leave the closing card on screen for ever.
    func testSkippingPastTheEndIsHowItFinishes() {
        XCTAssertEqual(Walkthrough.first(from: Walkthrough.steps.count, tab: 0),
                       Walkthrough.steps.count)
    }

    /// **The card's fence, as a test.** The owner asked for a tour of «the
    /// entire application», which is a program rather than a card. Three flows
    /// were agreed — sort, budget, bank — and a tour that quietly grows to
    /// seven screens is the failure this pins.
    func testTheTourCoversTheThreeAgreedFlowsAndNoMore() {
        let tabs = Walkthrough.steps.compactMap { step -> Int? in
            if case .reachTab(let t) = step.advance { return t }
            return nil
        }
        XCTAssertEqual(tabs, [4, 2, 0], "Розібрати, Бюджет, Головна — and nothing else")
        XCTAssertEqual(Walkthrough.steps.count, 5, "three flows, one opening, one closing")
    }
}
