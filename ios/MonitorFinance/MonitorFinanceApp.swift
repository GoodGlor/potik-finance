import SwiftUI

@main
struct MonitorFinanceApp: App {
    // A plain `let`, not `@State`: the App type is constructed once for the
    // whole process (unlike a child View, which SwiftUI may reconstruct on
    // every re-render — see the long comment on `AppStore.live()` about
    // exactly that trap). One store here means `BackgroundRefresh.register`
    // below and `RootView`'s foreground sync share the same `SyncEngine`.
    private let store = AppStore.live()

    init() {
        // Must run before the app finishes launching, or iOS refuses the
        // registration for the rest of the process — see `BackgroundRefresh`.
        BackgroundRefresh.register(store)
        BackgroundRefresh.schedule()
    }

    var body: some Scene {
        WindowGroup { RootView(store: store) }
    }
}

struct RootView: View {
    let store: AppStore
    @State private var lockWindow = LockWindow()
    /// The foreground sync run, held so backgrounding can cancel it.
    ///
    /// Fire-and-forget was the bug: during a legitimate multi-window backfill
    /// the task froze mid-`Task.sleep` with `isSyncing == true`, and every
    /// later `startSync` — including each `BGAppRefreshTask` wake — then
    /// short-circuited on `guard !isSyncing` for the rest of the process.
    ///
    /// Cancelling cannot clear a newer run's spinner. `startSync`'s `defer`
    /// lowers `isSyncing` only while `isCurrentSync` still holds, and it runs
    /// before the call returns — so the next run cannot pass `guard
    /// !isSyncing` until this one has already let go, and a run whose dataset
    /// was wiped meanwhile fails the generation check instead.
    @State private var syncTask: Task<Void, Never>?
    /// The foreground receipt drain, held for the same reason `syncTask` is —
    /// so backgrounding can cancel it rather than leaving it fire-and-forget.
    @State private var receiptTask: Task<Void, Never>?
    /// The email source's own foreground run, held for the same
    /// fire-and-forget reason as `syncTask` — but a SEPARATE task rather than
    /// chained after it: `syncTask` can be the unbounded multi-window
    /// backfill described above, which can run for minutes, and this source
    /// is independent of monobank entirely. Awaiting it after `syncTask`
    /// would make an email-only user (or a UI test with `-noDemoData`, whose
    /// monobank stub alone finishes in seconds but whose full backfill window
    /// still runs) wait out that whole backfill before a single email
    /// purchase could ever appear.
    @State private var emailSyncTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var phase: AppPhase {
        // "Onboarded but no PIN stored" is treated the same as "not onboarded":
        // a Keychain write that silently failed during onboarding must not
        // leave the user behind a lock screen with no PIN that can ever pass.
        if !store.settings.onboarded || !store.isPinSet { return .onboarding }
        return store.isUnlocked ? .unlocked : .locked
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch phase {
            case .onboarding:
                OnboardingFlow()
            case .locked, .unlocked:
                // hideTabs, not a conditional MainView(): the tabs stay
                // mounted (state isn't torn down) while locked, only their
                // bar is removed from the screen and from accessibility —
                // covering the native tab bar chrome pixel-wise still leaves
                // it reachable to XCUITest's isHittable/exists, which walk
                // the accessibility tree, not the render tree. The lock
                // itself is a separate window now (see LockWindow), and a
                // higher window does not hide lower ones from that tree.
                MainView(initialTab: Launch.tab, hideTabs: phase == .locked)
            }
        }
        .environment(store)
        .tint(Theme.green)
        // Board #58. One place, above every screen including onboarding and
        // the lock — and it must sit on `RootView` rather than on `WindowGroup`
        // so that changing it in Налаштування redraws immediately instead of
        // at the next launch. `.system` resolves to nil, which is
        // `preferredColorScheme`'s own word for "do not override".
        .preferredColorScheme(store.settings.appearanceChoice.colorScheme)
        // The whole interface, in one line. SwiftUI resolves every
        // `Text`/`Label`/`navigationTitle` LocalizedStringKey against this,
        // and formats every date and amount with it — so «21 серпня» and
        // «1 240,50 ₴» become "21 August" and "1,240.50 ₴" at the same time.
        // Strings assembled outside a view have no environment to read and go
        // through `L10n` instead.
        .environment(\.locale, store.settings.languageChoice.locale)
        .onAppear { syncLock() }
        .onChange(of: phase) { _, _ in syncLock() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // An app gets seconds of runtime here, which is enough for
                // `Task.sleep` to throw and `startSync`'s `defer` to lower
                // `isSyncing` — so the next wake finds a clean flag instead of
                // one held by a task iOS suspended mid-window.
                syncTask?.cancel()
                syncTask = nil
                emailSyncTask?.cancel()
                emailSyncTask = nil
                receiptTask?.cancel()
                receiptTask = nil
                // Still locks here, board #21 or not: the lock screen is also
                // what iOS photographs for the app switcher, and a preview
                // showing a balance is a leak whatever the grace window says.
                // Coming back is where the grace is spent — see below.
                store.lockForBackground()
                store.persistNow()
                // The phase change above raises the lock on its own; this is
                // for the case where it was already locked and the window
                // was somehow retired (scene reconnect).
                syncLock()
            }
            if newPhase != .background {
                // At `.inactive`, not `.active`: coming back runs background →
                // inactive → active, and spending the grace on the earlier of
                // the two means the tabs are already up as the app animates in
                // rather than the lock visibly dropping away afterwards.
                //
                // Safe on the way OUT, where `.inactive` also fires: nothing
                // has been stamped yet, so this is a no-op until a background
                // has actually happened.
                store.unlockIfWithinGrace()
            }
            if newPhase == .active {
                // The connected/needsReconnect gate — and deliberately no
                // `lastSuccess` gate — lives on `AppStore.startSyncIfConnected`
                // now, so it is unit-testable without simulating `scenePhase`.
                syncTask?.cancel()
                syncTask = Task { await store.startSyncIfConnected() }
                // A SEPARATE task, not chained after the one above: `syncTask`
                // can be the unbounded multi-window backfill (see its own
                // doc comment), which can run for minutes, and this source is
                // independent of monobank — chaining would make an
                // email-only user (or any user, on a slow backfill) wait out
                // the whole thing before a single email purchase could ever
                // land. Same gate family, same fixture guard as the line
                // above — see `AppStore.syncPrivatEmailIfConnected`.
                emailSyncTask?.cancel()
                emailSyncTask = Task { await store.syncPrivatEmailIfConnected() }
                // Same gate, same reasoning, one host over — see
                // `AppStore.fetchDueReceiptsIfAllowed`.
                receiptTask?.cancel()
                receiptTask = Task { await store.fetchDueReceiptsIfAllowed() }
            }
        }
    }

    private func syncLock() {
        if phase == .locked {
            lockWindow.present(store: store)
        } else {
            lockWindow.dismiss()
        }
    }
}
