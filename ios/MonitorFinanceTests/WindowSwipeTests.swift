import XCTest
@testable import MonitorFinance

/// Board #132 — the rule that decides whether a drag is a tab change.
///
/// **The owner diagnosed this one, and the diagnosis is the whole card:**
///
/// > «If I slowly and smoothly scroll down everything works … but if I make
/// > short swipes up or down, it works once or doesn't respond at all.»
///
/// Cost does not care how fast a finger moves. A recogniser does. What the app
/// had was a SwiftUI `DragGesture(minimumDistance: 40)` under
/// `highPriorityGesture`, and a `DragGesture` **has no direction** — it begins
/// on any drag past 40 pt and then takes the touch off the `ScrollView`. A
/// quick vertical flick crosses 40 pt inside one event batch, so the gesture
/// wins the race, finds the movement vertical, does nothing — and the scroll
/// never happens. A slow drag lets the scroll view claim first, which is
/// exactly why slow worked.
///
/// `isMine` is that fix as a function: asked of the **velocity**, which has a
/// direction from the first movement, rather than of the distance travelled,
/// which does not.
///
/// **What this file cannot prove.** Two earlier XCUITest attempts are recorded
/// on the card and both were dishonest — one passed against the unfixed code,
/// the other failed for the wrong reason (a fast flick carries inertia and
/// legitimately scrolls further than a slow drag). Synthesised gestures do not
/// reproduce a thumb. So the RULE is tested here, the surrounding behaviour by
/// `TabSwipeTests`, and the symptom itself still needs the owner's phone.
final class WindowSwipeTests: XCTestCase {

    private func velocity(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private let mid: CGFloat = 200

    /// **The bug, stated as the case that used to be claimed.**
    ///
    /// A fast vertical flick has a large `vy` and essentially no `vx`. The old
    /// gesture took it anyway, because 40 pt of travel is 40 pt of travel in
    /// any direction.
    func testAFastVerticalFlickIsNotATabChange() {
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(0, -1_039),
                                                    startX: mid, pushed: false),
                       "the flick that froze the queue must be declined")
    }

    /// …and a slow one, which is the case that always worked. Both answers
    /// have to be the same, or the fix would only have moved the boundary.
    func testASlowVerticalDragIsNotATabChangeEither() {
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(0, -603),
                                                    startX: mid, pushed: false))
    }

    /// **Speed must not decide.** The rule is about direction, and the same
    /// horizontal intent has to be honoured at any pace — the measured
    /// velocities here are from the diagnostic run on a simulator.
    func testAHorizontalSwipeIsATabChangeAtAnySpeed() {
        for vx in [CGFloat(-800), -185, 185, 800] {
            XCTAssertTrue(WindowSwipeRecognizer.isMine(velocity: velocity(vx, 0),
                                                       startX: mid, pushed: false),
                          "vx=\(vx) is a sideways swipe")
        }
    }

    /// A scroll that drifted sideways is still a scroll. The 2:1 ratio is
    /// board #63's, carried over unchanged so this card changed the mechanism
    /// and not the feel.
    func testADiagonalDragStaysAScroll() {
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(300, -300),
                                                    startX: mid, pushed: false))
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(500, -300),
                                                    startX: mid, pushed: false),
                       "1.7:1 is not 2:1 — the ratio is the line")
        XCTAssertTrue(WindowSwipeRecognizer.isMine(velocity: velocity(700, -300),
                                                   startX: mid, pushed: false))
    }

    /// The left edge belongs to `NavigationStack`'s interactive pop.
    func testTheLeftEdgeIsNotOurs() {
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(800, 0),
                                                    startX: 10, pushed: false))
        XCTAssertTrue(WindowSwipeRecognizer.isMine(velocity: velocity(800, 0),
                                                   startX: 61, pushed: false))
    }

    /// **Anything covering the tabs keeps its own gestures and nothing else.**
    ///
    /// The old per-screen modifier got this free: it sat on each tab's root
    /// inside its `NavigationStack`, so a pushed detail or a presented sheet
    /// simply covered it. One recogniser on the window has no such boundary,
    /// so the boundary has to be asked for — and forgetting to would change
    /// tab underneath a bank detail, or underneath the budget scope editor.
    func testACoveredScreenIsNotOurs() {
        XCTAssertFalse(WindowSwipeRecognizer.isMine(velocity: velocity(800, 0),
                                                    startX: mid, pushed: true))
    }

    /// **The control.** Every assertion above is worth something only if the
    /// rule can say both things — one that always answered `false` would pass
    /// most of this file while removing the swipe from the app entirely.
    func testTheRuleIsNotConstant() {
        let answers = Set([
            WindowSwipeRecognizer.isMine(velocity: velocity(800, 0), startX: mid, pushed: false),
            WindowSwipeRecognizer.isMine(velocity: velocity(0, -800), startX: mid, pushed: false),
        ])
        XCTAssertEqual(answers.count, 2, "the rule must be able to say both things")
    }
}
