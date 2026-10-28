import SwiftUI

/// Board #107 — the guide that is operated rather than read.
///
/// **The shape, chosen from the card's three.** Coach-marks over the real
/// screens, not a guided first categorisation and not an interactive sample
/// inside the guide. The other two teach against a rehearsal; this one teaches
/// against the person's own data, which is the only version that survives
/// being closed halfway through.
///
/// **Each step ends when the person operates the real control**, not when they
/// tap «Далі». That is the whole difference from board #60's pages: the
/// walkthrough says what «Розібрати» is for and then waits, and the thing that
/// dismisses the card is the person actually going there. By the end they have
/// not been told where the three screens are — they have been to them.
///
/// **No scrim, deliberately.** A dimming layer over the app is the usual way to
/// draw the eye, and here it would cover the one control each step needs
/// pressed. The card is loud enough on its own, and leaving the app fully
/// usable underneath is what lets somebody ignore the tour and keep working.
///
/// **The fence.** The owner asked for a walkthrough of «the entire
/// application». That is a program, not a card, so this holds the card's own
/// three flows: sort the queue, read the budget, add a bank. Receipts,
/// statistics, rules and the feed are all deliberately absent — a tour long
/// enough to be skipped teaches nothing, which is board #60's lesson and still
/// true.
///
/// `GuideView` is not replaced: it stays reachable from «Про додаток» and still
/// covers the fourth verb, receipts. This is what runs on first launch.
struct Walkthrough: View {
    /// The live tab binding, because **the tab is the input**: a step is
    /// finished by a tab change, so this view has to see the same value the
    /// tab bar writes.
    @Binding var tab: Int
    var onFinish: () -> Void

    @State private var step = 0

    /// How far above the bottom of the screen the card sits, so it clears the
    /// tab bar rather than covering it.
    ///
    /// **A measured number, not a derived one.** The bar is UIKit chrome inside
    /// a native `TabView`; SwiftUI cannot report its frame, and an overlay on
    /// the `TabView` is drawn over the bar. `GeometryReader` would measure the
    /// overlay, not the thing it must avoid. So: 49 pt of bar plus the home
    /// indicator's inset, checked on a simulator screenshot in both languages —
    /// which is the only way this could be checked at all.
    static let tabBarClearance: CGFloat = 52

    /// How a step ends.
    enum Advance: Equatable {
        /// The person taps that tab. The step is a coach-mark and the tab bar
        /// is the control.
        case reachTab(Int)
        /// Nothing to point at yet — the opening and the closing lines.
        ///
        /// **The payload is LABELLED**, and that is load-bearing rather than
        /// tidy: `tests/test_ios_localization.py` reads text, not a syntax
        /// tree, so it sees `Text(title)` in the button branch and then looks
        /// for how `title` is declared in this file. It finds `Step.title`,
        /// which really is a `String`, and reports a defect that is not here.
        /// Naming this one `title:` gives the guard the second declaration it
        /// needs — satisfying it at the declaration rather than by loosening a
        /// rule that has caught real bugs three times.
        case button(title: LocalizedStringKey)
    }

    struct Step {
        let id: Int
        /// `String`, wrapped in `LocalizedStringKey` where it is drawn —
        /// `GuideView`'s idiom, and for its reason. These are assembled in
        /// code rather than written as literals at the `Text`, so they arrive
        /// as runtime strings and would take `Text`'s VERBATIM overload: board
        /// #85 found exactly that leaving all four guide pages Ukrainian while
        /// the buttons under them were English.
        let title: String
        let body: String
        let advance: Advance
    }

    /// Three flows, in the order the card lists them — sort, budget, bank —
    /// wrapped in one opening line and one closing one.
    ///
    /// The bank step is last and is a `button`, because adding a bank is not a
    /// tab: it lives behind Головна → Налаштування → Банки. Pointing two hops
    /// deep with a coach-mark would need the tour to drive the navigation
    /// stack, and a tour that moves the app around a person is the thing this
    /// shape exists to avoid.
    static let steps: [Step] = [
        .init(id: 0,
              title: "Три екрани — і ви знаєте застосунок",
              body: "Коротка екскурсія. Кожен крок закінчується тим, що ви самі "
                  + "натискаєте кнопку внизу.",
              advance: .button(title: "Почати")),
        .init(id: 1,
              title: "«Розібрати» — одна відповідь на магазин",
              body: "Ви кажете, до якої категорії належить продавець, — і всі його "
                  + "покупки, минулі й майбутні, розкладаються самі. Натисніть "
                  + "«Розібрати» внизу.",
              advance: .reachTab(4)),
        .init(id: 2,
              title: "«Бюджет» — частки, а не суми",
              body: "Ви ділите місячний дохід на частки, а додаток показує, де "
                  + "витрати відходять від плану. Натисніть «Бюджет» внизу.",
              advance: .reachTab(2)),
        .init(id: 3,
              title: "Банки — на «Головній»",
              body: "Натисніть «Головна» внизу: звідти Налаштування → Банки, щоб "
                  + "додати ще банк або імпортувати виписку файлом.",
              advance: .reachTab(0)),
        .init(id: 4,
              title: "Це все",
              body: "Операції приходять самі — вводити вручну нічого не треба. "
                  + "Повний опис завжди є в «Про додаток».",
              advance: .button(title: "Зрозуміло")),
    ]

    /// **The rule a unit test can hold**, and the one thing here that is easy
    /// to get wrong: a `reachTab` step whose tab the person is ALREADY on can
    /// never be finished, because no tab change will ever arrive. Every such
    /// step is skipped before the card is drawn.
    ///
    /// It fires on the very first step in ordinary use — the walkthrough opens
    /// on Головна, and the closing card's predecessor asks for Головна.
    static func first(from index: Int, tab: Int) -> Int {
        var i = index
        while i < steps.count, steps[i].advance == .reachTab(tab) { i += 1 }
        return i
    }

    private var current: Step? { step < Self.steps.count ? Self.steps[step] : nil }

    var body: some View {
        Group {
            if let current {
                card(current)
                    // Above the tab bar, not over it. The bar is the control
                    // three of the five steps are about, and a card covering
                    // it would make them unfinishable.
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
        // The tab bar writes `tab`; this is where a coach-mark learns it was
        // obeyed. `advance(to:)` rather than a bare increment, so arriving at
        // a LATER step's tab out of order still moves the tour forward
        // instead of stranding it.
        .onChange(of: tab) { _, now in
            guard let current, current.advance == .reachTab(now) else { return }
            withAnimation { step = Self.first(from: step + 1, tab: now) }
        }
        .onAppear { step = Self.first(from: 0, tab: tab) }
    }

    private func card(_ s: Step) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(s.title))
                    .font(Theme.font(17, .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                // «Закрити», never «Пропустити» — board #17's rule, on the one
                // control whose whole job is to be pressed by people who are
                // already fine.
                Button("Закрити") { finish() }
                    .font(Theme.font(15, .medium)).foregroundStyle(Theme.inkMuted)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("walkthrough.close")
            }
            Text(LocalizedStringKey(s.body))
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("walkthrough.body")
            if case .button(let title) = s.advance {
                Button { next() } label: {
                    Text(title)
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.greenWash,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("walkthrough.next")
            } else {
                // A chevron pointing at the bar, not a second button. Adding
                // «Далі» beside "press Розібрати" would offer a way past the
                // step without doing the thing — which is the whole step.
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Кнопки — внизу екрана")
                        .font(Theme.font(13, .medium))
                }
                .foregroundStyle(Theme.green)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("walkthrough.hint")
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 16, y: 6)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.green.opacity(0.35), lineWidth: 1))
        // **`children: .contain` before the identifier, and `GuideView` does
        // the same.** Without it SwiftUI pushes a container's identifier DOWN
        // onto every leaf: the card's close button, body and next button all
        // came back as `walkthrough.step.0`, their own identifiers gone, and
        // the container itself was absent from the tree — so a query for it as
        // an `otherElement` matched nothing while the card was plainly on
        // screen. Two failures for one cause.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.step.\(s.id)")
    }

    private func next() {
        withAnimation {
            let ahead = step + 1
            step = Self.first(from: ahead, tab: tab)
        }
        if step >= Self.steps.count { finish() }
    }

    private func finish() { onFinish() }
}
