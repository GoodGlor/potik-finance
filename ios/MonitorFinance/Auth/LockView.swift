import SwiftUI
import UIKit

/// Covers the tabs until the PIN (or Face ID) says otherwise. An overlay,
/// not a root: unlocking reveals state that was never torn down.
struct LockView: View {
    @Environment(AppStore.self) private var store
    @State private var pin = ""
    @State private var shakeToken = 0
    @State private var message: LocalizedStringKey?
    @State private var lockedUntil: Date?
    /// Asked once, on appear. `Biometrics.isAvailable` builds an `LAContext`
    /// and queries the sensor; the answer cannot change while the lock is up,
    /// so reading it from a view body would pay that cost on every redraw.
    @State private var biometrics = false
    /// Face ID is offered once per time this lock is up, and only while the
    /// app is on screen — see `offerFaceIdIfActive`.
    @State private var offeredFaceId = false

    var body: some View {
        // The clock only has to run while there is a countdown to show.
        // Outside a lockout this is a plain, static view.
        Group {
            if let until = lockedUntil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let locked = until > context.date
                    entry(message: locked ? LocalizedStringKey(lockoutText(until: until, now: context.date)) : message,
                          locked: locked)
                        .onChange(of: locked) { _, stillLocked in
                            // Expired: drop back to the static branch and stop the clock.
                            if !stillLocked { lockedUntil = nil }
                        }
                }
            } else {
                entry(message: message, locked: false)
            }
        }
        .onAppear {
            lockedUntil = store.pinLockedUntil
            biometrics = Biometrics.isAvailable
            offerFaceIdIfActive()
        }
        // `UIApplication`, not `@Environment(\.scenePhase)`: this view is
        // hosted in a `UIWindow` this app builds by hand (`LockWindow`), and
        // what SwiftUI reports for `scenePhase` there is not something to bet
        // a security prompt on. The notification is unambiguous.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in offerFaceIdIfActive() }
    }

    /// Offer Face ID when the lock is up AND the app is on screen.
    ///
    /// It used to be an unconditional `onAppear`, and this window appears
    /// while the app is BACKGROUNDING — `RootView` locks on the way out, so
    /// the prompt was asked for by a view nobody could see, to arrive
    /// whenever iOS chose to present it. Board #21 made that matter: with a
    /// grace period most returns dismiss this lock without ever wanting a
    /// prompt, and a Face ID sheet racing that dismissal is the exact
    /// interruption the card is about.
    ///
    /// Once per appearance, not once per activation: someone who dismissed
    /// the sheet and switched away is not handed it again on their way back.
    /// The «Увійти за Face ID» button below is still there for them.
    private func offerFaceIdIfActive() {
        guard UIApplication.shared.applicationState == .active,
              !offeredFaceId, biometrics, store.settings.faceIdEnabled else { return }
        offeredFaceId = true
        Task { await faceId() }
    }

    private func entry(message: LocalizedStringKey?, locked: Bool) -> some View {
        PinEntry(title: "Введіть код",
                 subtitle: "Щоб ніхто, крім вас, не бачив ваші гроші.",
                 message: message,
                 pin: $pin,
                 shakeToken: shakeToken,
                 disabled: locked,
                 onComplete: attempt) {
            if biometrics && store.settings.faceIdEnabled {
                Button {
                    Task { await faceId() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "faceid").font(.system(size: 22))
                        Text("Увійти за Face ID").font(Theme.font(17, .semibold))
                    }
                    .foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lock.faceid")
            }
        }
    }

    private func attempt(_ entered: String) {
        if store.unlock(with: entered) {
            message = nil
        } else {
            lockedUntil = store.pinLockedUntil
            message = lockedUntil == nil ? "Невірний код" : nil
            shakeToken += 1
        }
    }

    /// **iOS draws this sentence, but we choose its language.** The system
    /// alert's own buttons follow the phone; the reason line is ours, so it
    /// follows the person's choice in Settings like the rest of our copy —
    /// and it is assembled outside a view, so it needs `L10n` rather than the
    /// environment.
    private func faceId() async {
        let reason = L10n.t("Увійти в Потік", store.settings.languageChoice)
        if await Biometrics.authenticate(reason: reason) {
            store.unlockWithoutPin()
        }
    }

    /// Translated HERE rather than at the `Text`, because the countdown is
    /// substituted into the format: a `LocalizedStringKey` built from the
    /// finished string would look up a key containing this second's digits and
    /// find nothing. `String(format: L10n.t(...))` is the shape `Derived` uses
    /// for every sentence it assembles, and wrapping the result in a
    /// `LocalizedStringKey` is safe — the lookup misses and falls back to the
    /// already-translated text.
    private func lockoutText(until: Date, now: Date) -> String {
        let s = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        return String(format: L10n.t("Забагато спроб. Спробуйте через %d:%02d", L10n.formatting),
                      s / 60, s % 60)
    }
}
