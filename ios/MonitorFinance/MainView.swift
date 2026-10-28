import SwiftUI

struct MainView: View {
    /// Confirmations live here rather than in the queue screen, so the badge and
    /// the home card agree with the queue without passing anything between tabs.
    var initialTab: Int = 0
    /// The lock overlay covers the tabs visually, but a plain background isn't
    /// itself an accessibility element: the native tab bar chrome stays in the
    /// accessibility tree regardless of what's drawn on top of it. Hiding the
    /// tab bar itself (rather than fighting the overlay) is what actually
    /// removes it from that tree while locked, without tearing MainView down.
    var hideTabs = false
    @Environment(AppStore.self) private var store
    @State private var tab: Int
    /// Board #60, now board #107's walkthrough. Raised once, here, rather than
    /// from `completeOnboarding`: it points at the five tabs, so it has to
    /// appear OVER them, and at the moment onboarding finishes this shell does
    /// not exist yet.
    ///
    /// **Same gate as the sheet it replaces** (`hasSeenGuide`, stamped by
    /// `-noGuide`), which is what lets every existing UI test go on suppressing
    /// the first-launch interruption with the argument it already passes.
    @State private var showingGuide = false

    init(initialTab: Int = 0, hideTabs: Bool = false) {
        self.initialTab = initialTab
        self.hideTabs = hideTabs
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        // Counted once for the badge and the Home card together. Both want the
        // same two numbers, and `queueCardCount` walks every pending row to
        // produce one of them — asking twice would do that twice on every
        // render of the shell, which is every render in the app.
        let cards = store.queueCardCount
        let purchases = store.pendingRowCount
        // The visibility modifier is per-tab-content, not on the TabView
        // itself — attaching it only to the outer TabView is a no-op, so
        // every tab carries it individually.
        return TabView(selection: $tab) {
            // Both scales, board #8. The card leads with the same number the
            // badge shows — the work — and names the purchases behind it.
            HomeView(cards: cards, purchases: purchases,
                     openQueue: { tab = 4 }, openBudget: { tab = 2 })
                .tabItem { Label("Головна", systemImage: "house") }
                .tag(0)
                .toolbar(hideTabs ? .hidden : .visible, for: .tabBar)

            FeedView()
                .tabItem { Label("Стрічка", systemImage: "list.bullet") }
                .tag(1)
                .toolbar(hideTabs ? .hidden : .visible, for: .tabBar)

            BudgetView()
                .tabItem { Label("Бюджет", systemImage: "chart.pie") }
                .tag(2)
                .toolbar(hideTabs ? .hidden : .visible, for: .tabBar)

            StatsView()
                .tabItem { Label("Статистика", systemImage: "chart.bar") }
                .tag(3)
                .toolbar(hideTabs ? .hidden : .visible, for: .tabBar)

            QueueView { tab = 0 }
                .tabItem { Label("Розібрати", systemImage: "tray.and.arrow.down") }
                // Cards, not rows (board #8): the badge promised twelve things
                // to do and the screen showed four, because it counted
                // purchases while the queue asks one question per card.
                .badge(cards)
                .tag(4)
                .toolbar(hideTabs ? .hidden : .visible, for: .tabBar)
        }
        // `hideTabs` is the lock: a sheet must never open over, or instead of,
        // the lock screen. The lock is its own window and outranks any
        // presentation, so the guide would be invisible and waiting — and
        // `markGuideSeen` would have fired on a screen nobody saw.
        .onAppear { raiseGuideIfNeeded() }
        // …and again when the lock lifts. The tabs stay MOUNTED while locked
        // (that is what `hideTabs` is for), so `onAppear` fires exactly once —
        // and if that once happened behind the lock, the guide would be
        // suppressed for the whole session. Someone who quits mid-guide and
        // comes back to the PIN pad is precisely the person still owed it.
        .onChange(of: hideTabs) { _, _ in raiseGuideIfNeeded() }
        // Board #132. ONE recogniser, on the window, installed here — where
        // the tab lives — instead of five SwiftUI gestures on five screens.
        // `WindowSwipe.swift` carries the reasoning; the short version is that
        // a `DragGesture` cannot decline by direction, so it took the touch
        // off the ScrollView on every fast flick.
        //
        // `hideTabs ? nil : move` is the same nil the lock already relied on:
        // a swipe under the lock screen must do nothing.
        .background {
            WindowSwipeInstaller(page: hideTabs ? nil : move)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        // Board #107. An OVERLAY, not the sheet it replaces, and that is the
        // card's whole point: a sheet covers the app, and three of the five
        // steps are finished by pressing something the app is showing. It sits
        // over the tab bar's own chrome, so the card carries its own bottom
        // padding to clear it — see the measurement note in `Walkthrough`.
        .overlay(alignment: .bottom) {
            if showingGuide, !hideTabs {
                Walkthrough(tab: $tab) {
                    showingGuide = false
                    store.markGuideSeen()
                }
                .padding(.bottom, Walkthrough.tabBarClearance)
            }
        }
    }

    /// Board #63. One tab along, clamped at both ends.
    ///
    /// Handed down through the environment rather than applied here, so it can
    /// be attached INSIDE each tab's `NavigationStack` — see `tabSwipe()`.
    /// `nil` while the lock is up: the tabs stay mounted behind it, and a
    /// closure that still worked would move the app underneath the lock.
    private func move(_ delta: Int) {
        let next = tab + delta
        // The ends do not wrap. Wrapping would put Розібрати one swipe to the
        // left of Головна — the tab with the badge on it, and the one place an
        // accidental arrival costs the most.
        guard (0...4).contains(next) else { return }
        withAnimation(.easeOut(duration: 0.2)) { tab = next }
    }

    /// The lock is its own window and outranks any presentation, so a sheet
    /// raised while locked would be invisible AND would stamp itself seen on a
    /// screen nobody saw.
    private func raiseGuideIfNeeded() {
        guard !hideTabs, !store.settings.hasSeenGuide else { return }
        showingGuide = true
    }
}

// MARK: - the tab swipe (boards #63, #115, #131, #132)
//
// Nothing lives here any more, and that is the shape of board #132's fix.
//
// The gesture used to be a SwiftUI `DragGesture` under `highPriorityGesture`,
// applied by a `.tabSwipe()` modifier on each of the five tab roots — five
// gestures, an environment key to reach `moveTab` from inside them, and a
// conditional `enabled:` for the one screen that embeds another. All of it was
// there to work around the one thing a `DragGesture` cannot do: decline a
// touch by direction. Because it could not, it took every fast vertical flick
// off the `ScrollView`, which is the freeze the owner reported.
//
// One `UIPanGestureRecognizer` on the window replaces the lot — see
// `WindowSwipe.swift`. It is installed once, by `MainView`, which is where the
// tab it moves already lives.
