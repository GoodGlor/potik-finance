import SwiftUI

/// Data-driven: a third bank is a new seed entry, not a new view.
struct BankPickerView: View {
    @Environment(AppStore.self) private var store
    /// Onboarding must let the user re-select a bank that a prior, aborted
    /// run already connected (e.g. Application Support restored from backup
    /// but the Keychain PIN was not) — otherwise the picker itself becomes
    /// the new dead end. Settings' "Додати банк" keeps the default: showing
    /// an already-connected bank there as selectable would be wrong.
    var allowConnected = false
    /// Onboarding's second visit: at least one bank is connected, so the
    /// flow may end here. `nil` everywhere else — settings' picker must
    /// never offer to end an onboarding it is not part of.
    ///
    /// **It was called `onSkip`, and the button said «Пропустити»** (board
    /// #17). It is the ONLY way out of onboarding, and it is offered exactly
    /// when the user has already done the thing onboarding asked for — so the
    /// app was calling their finished setup a thing they had skipped, and
    /// inviting them to abandon it. Nothing is skipped by tapping it; a second
    /// bank is an option, not a step.
    var onFinish: (() -> Void)? = nil
    /// Declared LAST, after the two closure-shaped properties above: with
    /// `onPick` first, a call that labels `allowConnected`/`onSkip` and
    /// leaves `onPick` for a trailing closure fails to compile rather than
    /// silently binding the closure to `onSkip` — but it still fails, and
    /// twice bit the caller in Task 13. Last restores the plain trailing-
    /// closure call `BankPickerView(allowConnected: ..., onSkip: ...) { id in ... }`.
    var onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Підключіть банк").font(Theme.font(26, .bold)).foregroundStyle(Theme.ink)
                        Text("Ми лише читаємо виписку. Переказати гроші застосунок не може.")
                            .font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    }
                    .padding(.horizontal, 6)

                    Card {
                        ForEach(Array(store.banks.enumerated()), id: \.element.id) { i, bank in
                            row(bank)
                            if i < store.banks.count - 1 { Divider().overlay(Theme.hair) }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }

            // Board #19 removed a «Далі». Tapping a row IS the choice now, so
            // there was nothing left for it to confirm — and while it stood, it
            // was the biggest control on the screen and *disabled* until a row
            // was picked, which pointed the eye at a dead button and left the
            // only real way forward as a small green link underneath it.
            //
            // «Готово» inherits the primary slot, and only on the visit where
            // it exists: the screen would otherwise have no prominent control
            // at all, and on that visit finishing is what most people are here
            // to do. It stays absent — not disabled — until a bank is
            // connected, which is the difference between "not yet" and
            // "never", and is why `onFinish` is an Optional.
            //
            // The identifier moved with the word in board #17. A control named
            // for what it no longer does is how a screen ends up disagreeing
            // with itself — board #8 renamed `badgeCount` for the same reason.
            // `test_the_way_out_of_onboarding_is_not_called_skipping` pins the
            // old name absent from app code.
            if let onFinish {
                PrimaryButton(title: "Готово") { onFinish() }
                    .accessibilityIdentifier("bank.done")
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .background(Theme.bg)
            }
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden()
    }

    /// Whether tapping this row does anything — and, since board #19, whether
    /// it shows the chevron that promises it will.
    ///
    /// A static so both branches are reachable without a simulator. The seed
    /// ships two banks and neither is `comingSoon`, so **no UI test can enter
    /// the disabled case at all**: a chevron wrongly drawn on a bank that
    /// cannot be picked would have shipped green. `allowConnected` is the
    /// onboarding-only allowance (re-onboarding after a lost PIN, and the
    /// second visit's token re-paste); Settings' picker leaves it false, where
    /// showing a connected bank as selectable would be wrong.
    static func isSelectable(_ bank: Bank, allowConnected: Bool) -> Bool {
        bank.status != .comingSoon && (allowConnected || !bank.connected)
    }

    private func row(_ bank: Bank) -> some View {
        let enabled = Self.isSelectable(bank, allowConnected: allowConnected)
        // `LocalizedStringKey`, not `String`. It was a `String`, and
        // `Text(someStringVariable)` binds to the VERBATIM overload — so every
        // note here stayed Ukrainian under «English», on a screen whose own
        // heading was translated. All three keys were already in the
        // catalogue; nothing ever read them. Board #85's `PrimaryButton.title`
        // records the same trap, and this is the row it missed.
        let note: LocalizedStringKey = {
            if bank.connected { return "уже підключено" }
            // Board #91: PrivatBank has two ways in now, and «з файлу виписки»
            // named only one of them — on the row whose whole job is to say
            // what tapping it gets you.
            if bank.hasEmailSource { return "листи або файл виписки" }
            switch bank.status {
            // Board #18: «через особистий токен» is a developer's word for it.
            // A person choosing a bank has not met a token yet and cannot tell
            // from that whether this is something the bank sanctions — which is
            // the one thing they actually want to know here.
            //
            // The bank NAMES ITSELF rather than the string saying «monobank»:
            // this branch is keyed on `.available`, not on an id, so a second
            // token bank would otherwise be introduced as monobank's access.
            case .available: return "офіційний доступ \(bank.displayName)"
            case .statement: return "з файлу виписки"
            case .comingSoon: return "скоро"
            }
        }()
        // Board #19: the tap IS the choice. It was a radio button plus a
        // «Далі» — two taps to answer a two-item question, and a pattern that
        // only earns its keep when a choice is worth reviewing before it
        // commits. This one is not: every destination has a back edge, and
        // nothing is connected by arriving there.
        return Button { if enabled { onPick(bank.id) } } label: {
            HStack(spacing: 14) {
                // BRAND colours, and the one place in the app that keeps the
                // same value in both appearances on purpose: monobank's tile
                // is black because monobank is black. Board #58 gave them the
                // hairline instead — the near-black square sits at roughly
                // 1:1 against the dark card and simply vanished, so the shape
                // is drawn by its edge rather than by its fill.
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(bank.id == "monobank" ? Color(red: 0.13, green: 0.13, blue: 0.15)
                                                 : Color(red: 0.78, green: 0.87, blue: 0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Theme.hair, lineWidth: 1)
                    }
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bank.displayName).font(Theme.font(17, .semibold))
                        .foregroundStyle(enabled ? Theme.ink : Theme.inkMuted)
                    Text(note).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                // A chevron where the radio was: the row now goes somewhere,
                // and this is how the app says so on every other row-shaped
                // button it has — a bank, a category, a plan line, a rule, a
                // queue card. A row that cannot be tapped says nothing, rather
                // than showing an affordance it will not honour.
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("bank.row.\(bank.id)")
    }
}
