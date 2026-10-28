import SwiftUI

/// The one place that says what sync is doing. Four states: working with a
/// count, working without one, needs a new token, or the reason the last run
/// stopped. Silence is what is left, and it now means "nothing has gone wrong
/// and nothing is running" rather than "something failed and we are not
/// telling you" — which is what a failed first run used to look like on an
/// empty app: no spinner, no error, no explanation, permanently.
///
/// **Board #165 — the two monobank lines ask whether monobank is connected.**
/// Neither `disconnect` clearing the state nor `startSync` refusing to write it
/// can cover a `sync.json` restored onto a phone with no monobank connection:
/// no sync and no disconnect ever runs there, and the file arrives already
/// holding the old phone's complaint. The gate belongs here as well as there.
///
/// The EMAIL line is deliberately not gated the same way — an email-only person
/// has no monobank connection by definition, and their status is the one thing
/// on this view still telling them anything.
struct SyncStatusView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.monobankIsConnected, store.syncState.needsReconnect {
            // No spinner here either: a rejected token means everything has
            // stopped and only the user can restart it. A spinner beside
            // «підключіть заново» would say the opposite.
            line("monobank відхилив токен — підключіть заново", Theme.clay, spinner: false)
        } else if store.syncState.emailNeedsReconnect {
            // Same shape and same reason as the line above, for the other
            // source: a 401 stops the letters for good and only the person can
            // restart it. Above `syncProgress` deliberately — something that
            // needs a decision outranks something that is merely running, and
            // without this the letters just stop with nothing anywhere saying
            // why, which is the exact failure this view was built to end.
            line("ПриватБанк не приймає доступ — підключіть пошту заново", Theme.clay, spinner: false)
        } else if let progress = store.syncProgress {
            line("Завантажуємо покупки… \(progress.done) з \(progress.total)", Theme.inkSoft)
        } else if store.isSyncing {
            // Reachable exactly for «Усе, що є», where there is no planned
            // total to count against — `syncProgress` returns nil there rather
            // than pinning at «2 з 2». Before that it was dead code:
            // `syncProgress` was non-nil whenever `isSyncing` was true.
            line("Завантажуємо покупки…", Theme.inkSoft)
        } else if store.monobankIsConnected,
                  let stop = SyncEngine.Stop(rawValue: store.syncState.lastStop ?? ""),
                  let message = stop.userMessage.map { LocalizedStringKey($0) } {
            // No spinner: nothing is running, and one spinning next to «Немає
            // зв'язку» would read as "still trying". Pull-to-refresh is the
            // recovery affordance and it already exists on Home and on the
            // feed's empty state — only the explanation was missing.
            line(message, Theme.clay, spinner: false)
        }
    }

    /// `LocalizedStringKey`, not `String`. It was a `String`, and
    /// `Text(someStringVariable)` binds to the VERBATIM overload — so the one
    /// place in the app that says what sync is doing said it in Ukrainian on an
    /// English phone, under an English heading. `SyncEngine.Stop.userMessage`
    /// is a runtime `String`, so its caller names the key explicitly; the rest
    /// are literals and localise where they are written.
    private func line(_ text: LocalizedStringKey, _ colour: Color, spinner: Bool = true) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(colour)
            }
            Text(text).font(Theme.font(14)).foregroundStyle(colour)
        }
        .accessibilityIdentifier("sync.status")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }
}
