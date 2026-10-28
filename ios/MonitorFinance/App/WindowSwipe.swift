import SwiftUI
import UIKit

/// Board #132 — the tab swipe as a UIKit recogniser, attached to the WINDOW.
///
/// ## The bug, as the owner diagnosed it
///
/// > «If I slowly and smoothly scroll down everything works … but if I make
/// > short swipes up or down, it works once or doesn't respond at all.»
///
/// Cost does not care how fast a finger moves; a recogniser does. What the app
/// had was `highPriorityGesture(DragGesture(minimumDistance: 40))`, and a
/// SwiftUI `DragGesture` **has no direction** — it begins on any drag past 40
/// pt, and high priority means beginning takes the touch away from the
/// `ScrollView`. A quick vertical flick crosses 40 pt inside a single event
/// batch, so the gesture wins the race, `onEnded` then finds the movement
/// vertical and does nothing, and the scroll never happens. A slow drag lets
/// the scroll view claim the touch first, which is exactly why slow works.
///
/// ## Why the obvious fix is not available
///
/// `simultaneousGesture` was tried when board #63 built this and is recorded
/// in `TabSwipe`'s own comment: nearly every screen here is full-width
/// `Button`s, a horizontal drag across one never leaves its bounds, and
/// without high priority the button takes the touch and fires as a TAP — a
/// left swipe on Головна opened Бюджет by pressing the card it crossed.
///
/// So the gesture must beat a **button** without beating the **ScrollView**,
/// and no SwiftUI gesture can express that: the choice is made before anyone
/// knows which direction the finger is going.
///
/// ## What UIKit can say that SwiftUI cannot
///
/// A `UIPanGestureRecognizer` answers three questions separately, and this
/// card needs all three answered differently:
///
///  - `gestureRecognizerShouldBegin` — **is this mine?** Asked once movement
///    has a direction, so a vertical flick is declined before it can claim
///    anything.
///  - `shouldRecognizeSimultaneouslyWith` — **may the scroll view keep
///    panning?** Yes, always. That is what removes the freeze.
///  - `cancelsTouchesInView` — **does the button under the finger still
///    fire?** No, once this recogniser has begun. That is what
///    `simultaneousGesture` could not do, and the whole reason a UIKit
///    recogniser is worth the trouble.
///
/// ## The attachment point, which is what three earlier attempts got wrong
///
/// Recorded on the card: on a `.background` view it never fired (a background
/// sits *behind* the content, so the button in front took the touch); on the
/// nearest view controller's view it still never began, even with the
/// direction gate removed entirely.
///
/// A recogniser only sees touches that hit-test to its own view or a
/// descendant. The **window** is the ancestor of everything, including the
/// content in front, so a recogniser there sees every touch on the screen by
/// construction. It is the one attachment point that cannot be wrong for the
/// reason the other three were.
///
/// ## How the attachment point was settled
///
/// Not by reasoning. A temporary probe installed exactly this recogniser and
/// wrote every callback to a file — because the app and the XCUITest runner
/// are separate processes and only the runner's stdout reaches `xcodebuild`,
/// so an earlier `print` version produced no output at all and looked exactly
/// like a recogniser that never fired. What it reported settled three
/// questions the dead ends could not:
///
///     attached to window
///     shouldBegin vx=0    vy=-1039  -> false     ← the flick that froze
///     shouldBegin vx=0    vy=-603   -> false     ← the slow drag
///     shouldBegin vx=-800 vy=0      -> true      ← a real sideways swipe
///     ended dx=-175 dy=0
///
/// The probe is gone; a debug file-writer in shipping code is what the
/// file-protection guard exists to refuse, and it was right to.
final class WindowSwipeRecognizer: NSObject, UIGestureRecognizerDelegate {

    /// How far, and how much more horizontal than vertical, before a drag is a
    /// tab change. Board #63 chose both by trying them on a simulator; they
    /// are carried over unchanged so this card changes the MECHANISM and not
    /// the feel.
    static let minimumDistance: CGFloat = 80
    static let ratio: CGFloat = 2

    /// The interactive-pop edge belongs to the navigation controller, and a
    /// swipe starting inside it is a back gesture. Carried over from board
    /// #63 for the same reason it was kept there.
    static let edge: CGFloat = 60

    /// **The whole of board #132's fix, as a function.**
    ///
    /// Everything else in this file is plumbing — finding the window, keeping
    /// one recogniser, letting the scroll view through. This is the rule the
    /// old `DragGesture` could not express, and the reason a fast flick froze
    /// the queue: it is asked of the VELOCITY, which has a direction from the
    /// first movement, rather than of the distance travelled, which does not.
    ///
    /// Pure, and static, because it is the one part a unit test can hold. The
    /// rest needs a thumb.
    static func isMine(velocity: CGPoint, startX: CGFloat, pushed: Bool) -> Bool {
        guard !pushed else { return false }
        guard startX > edge else { return false }
        return abs(velocity.x) > abs(velocity.y) * ratio
    }

    /// Set by the modifier on every SwiftUI update; `nil` means this screen is
    /// not the one on top, or the app is locked.
    var page: ((Int) -> Void)?

    private weak var attached: UIWindow?
    private var pan: UIPanGestureRecognizer?

    func attach(to window: UIWindow) {
        guard attached !== window else { return }
        detach()
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.delegate = self
        // The point of the exercise. A recogniser that begins has decided the
        // drag is horizontal, and the button it began over must not also fire.
        recognizer.cancelsTouchesInView = true
        window.addGestureRecognizer(recognizer)
        attached = window
        pan = recognizer
    }

    func detach() {
        if let pan, let attached { attached.removeGestureRecognizer(pan) }
        pan = nil
        attached = nil
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let dx = recognizer.translation(in: nil).x
        let dy = recognizer.translation(in: nil).y
        guard let page, abs(dx) > Self.minimumDistance, abs(dx) > abs(dy) * Self.ratio else {
            return
        }
        page(dx < 0 ? 1 : -1)
    }

    /// **Anything covering the tabs keeps its own gestures and nothing else.**
    ///
    /// This is the one behaviour the old per-screen `.tabSwipe()` got for
    /// free: the modifier sat on each tab's ROOT inside its `NavigationStack`,
    /// so a pushed detail or a presented sheet simply covered it. A window
    /// recogniser has no such boundary — it is an ancestor of everything — so
    /// the boundary has to be asked for.
    ///
    /// **Both halves are needed, and the sheet half is the one that is easy to
    /// miss.** A sheet carries its own `NavigationStack` at depth 1, so a
    /// depth test alone calls it "not covered" and a swipe inside the budget
    /// scope editor would change the tab behind it.
    ///
    /// Asked of UIKit rather than tracked in SwiftUI state: a stack's depth
    /// and a presented controller are what "covered" MEANS, and mirroring
    /// either into a second place is a second place to get out of sync.
    static func isCovered(_ window: UIWindow?) -> Bool {
        guard let root = window?.rootViewController else { return false }
        if root.presentedViewController != nil { return true }
        return deepestNavigation(root)?.viewControllers.count ?? 0 > 1
    }

    private static func deepestNavigation(_ vc: UIViewController) -> UINavigationController? {
        // Depth-first through presented and child controllers: the stack that
        // matters is the one the person is looking at, which is the deepest,
        // not the first one encountered.
        var found: UINavigationController? = vc as? UINavigationController
        for child in vc.children + [vc.presentedViewController].compactMap({ $0 }) {
            if let deeper = deepestNavigation(child),
               deeper.viewControllers.count > (found?.viewControllers.count ?? 0) {
                found = deeper
            }
        }
        return found
    }

    // MARK: - UIGestureRecognizerDelegate

    /// **Yes, always.** Every other recogniser on screen — the scroll view's
    /// pan, a button's touch, a swipe action — goes on doing its job, and this
    /// one only ever adds a decision on top. Refusing here is what made the
    /// SwiftUI version freeze the queue.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // …and while UIKit is handing us every conflicting pair, make the
        // TAP-like ones wait for us.
        //
        // **`cancelsTouchesInView` is not enough, and the suite caught it.**
        // That flag stops touches reaching a VIEW; SwiftUI's Button is driven
        // by its own gesture recogniser, which goes on receiving them — so a
        // left swipe across Головна's budget card recognised as a swipe AND
        // pressed the card, which is board #63's original bug arriving by a
        // new route. Three tests failed on exactly that.
        //
        // `require(toFail:)` is the relationship that expresses it, and it can
        // only be set from the OTHER recogniser — which is why it is done
        // here, in the one callback where UIKit hands us that recogniser.
        // The cost is that a tap now resolves on touch-up rather than
        // touch-down, which is when a button fires anyway.
        if !(other is UIPanGestureRecognizer), let pan {
            other.require(toFail: pan)
        }
        return true
    }

    /// **The question a `DragGesture` cannot be asked.**
    ///
    /// By the time this runs the touch has moved, so it has a direction — and
    /// a vertical flick is declined here, before it can take anything from the
    /// scroll view. That is the whole fix.
    ///
    /// A pure-vertical drag has `dx == 0`, so the ratio test rejects it
    /// without needing a special case; a stationary touch never gets here at
    /// all, because a pan recogniser does not ask until it has movement.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
              page != nil else { return false }
        return Self.isMine(velocity: recognizer.velocity(in: nil),
                           startX: recognizer.location(in: nil).x,
                           pushed: Self.isCovered(attached))
    }
}

/// A zero-sized view whose only job is to reach the window.
///
/// SwiftUI has no way to name the hosting window, and `UIApplication`'s scene
/// list is the wrong answer under multiple scenes and in a test runner. A view
/// in the hierarchy knows its own window the moment it is in one, which is
/// what `didMoveToWindow` reports.
struct WindowSwipeInstaller: UIViewRepresentable {
    var page: ((Int) -> Void)?

    func makeCoordinator() -> WindowSwipeRecognizer { WindowSwipeRecognizer() }

    func makeUIView(context: Context) -> UIView {
        let view = ReportingView()
        view.isUserInteractionEnabled = false   // it must never take a touch itself
        view.onWindow = { [weak coordinator = context.coordinator] window in
            guard let window else { coordinator?.detach(); return }
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Re-read every update: `moveTab` becomes nil when the app locks, and a
        // stale closure would move tabs underneath the lock screen.
        context.coordinator.page = page
    }

    static func dismantleUIView(_ view: UIView, coordinator: WindowSwipeRecognizer) {
        coordinator.detach()
    }

    final class ReportingView: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow?(window)
        }
    }
}
