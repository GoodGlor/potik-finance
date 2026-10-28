import SwiftUI
import UIKit

/// The lock lives in its own `UIWindow`, above every presentation.
///
/// It used to be a `.zIndex(1)` overlay inside `RootView`'s ZStack, and that
/// cannot be made safe. A sheet, an alert, a `confirmationDialog` or a
/// scanner is presented by UIKit *above the window's root view controller* —
/// so anything in the SwiftUI view tree is underneath it no matter how high
/// its zIndex. Backgrounding the app with one of those open re-locked the
/// app underneath the very thing that was showing the user's money, and one
/// such bypass (disconnect-a-bank from a locked state) was live and had to be
/// closed by hand.
///
/// Stage 3 adds a filter sheet, a category picker and a QR scanner. Rather
/// than audit each one forever, the lock stops competing: a separate window
/// at `.alert + 1` outranks anything the app can present.
///
/// The tab bar is still hidden separately while locked (`MainView.hideTabs`).
/// A higher window does not remove lower windows from the accessibility tree,
/// so that belt stays on with this brace.
@MainActor
final class LockWindow {
    private var window: UIWindow?

    var isPresented: Bool { window != nil }

    func present(store: AppStore) {
        guard window == nil, let scene = Self.activeScene() else { return }

        // The locale for the same reason as the appearance override below, and
        // found the same way: `RootView`'s environment reaches the app's own
        // window and nothing else, so a person who had pinned the app to
        // English met a Ukrainian PIN pad — on the one screen the app shows
        // before anything else.
        let host = UIHostingController(
            rootView: LockView()
                .environment(store)
                .environment(\.locale, store.settings.languageChoice.locale))
        host.view.backgroundColor = UIColor(Theme.bg)

        let lock = UIWindow(windowScene: scene)
        lock.windowLevel = .alert + 1
        // Board #58. `RootView.preferredColorScheme` reaches the app's own
        // window and nothing else, so a person who had pinned the app to dark
        // met a LIGHT lock screen on a light phone — the one screen the app
        // shows before anything else, in the wrong appearance. A second window
        // takes the override the same way, by hand.
        lock.overrideUserInterfaceStyle = store.settings.appearanceChoice.uiStyle
        lock.rootViewController = host
        lock.isHidden = false
        window = lock
    }

    func dismiss() {
        window?.isHidden = true
        // Dropping the last reference is what actually retires the window;
        // UIKit keeps a hidden one attached to the scene otherwise.
        window = nil
    }

    /// The foreground scene, or any scene at all if none is foreground yet —
    /// `present` can run during launch, before activation.
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
