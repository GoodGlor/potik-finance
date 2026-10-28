import SwiftUI

/// The one pad every PIN screen uses: title, four dots, keys, an optional
/// message line and a caller-supplied footer (Face ID button, nothing, …).
/// The owner holds the digits; `shakeToken` changing shakes the dots and
/// clears them, so a wrong entry is felt, not just read.
struct PinEntry<Footer: View>: View {
    // `LocalizedStringKey`, not `String`: `Text(someStringVariable)` takes
    // the verbatim overload, which left «Придумайте код» Ukrainian on an
    // English phone — the first screen the app ever shows.
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    @Binding var pin: String
    var shakeToken: Int = 0
    var disabled = false
    var onComplete: (String) -> Void
    @ViewBuilder var footer: Footer

    @State private var shakes: CGFloat = 0
    @State private var shakeClearWork: DispatchWorkItem?
    @State private var completeWork: DispatchWorkItem?
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]
    /// Deliberately larger than the 44pt minimum: the keypad is the only
    /// control on this screen, so letting it take the room means the leftover
    /// space stops reading as a hole.
    private let keyHeight: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            // Two flexible spacers, not one. With only the lower spacer the
            // header glued itself to the top and every leftover point on a
            // tall screen collected into a single dead band above the keypad
            // — about a third of the screen on a 6.3", which reads as an
            // unfinished layout rather than a deliberately airy one. Splitting
            // the leftover evenly centres the header in the space it has, at
            // any screen size, without a magic number to re-tune per device.
            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Text(title).font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(Theme.font(16)).foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.green, lineWidth: 2)
                        .background(Circle().fill(i < pin.count ? Theme.green : .clear))
                        .frame(width: 18, height: 18)
                }
            }
            .modifier(Shake(animatableData: shakes))
            .padding(.top, 32)
            .padding(.bottom, 12)

            Text(message ?? " ")
                .font(Theme.font(15, .medium))
                .foregroundStyle(Theme.clay)
                .accessibilityIdentifier("pin.message")
                .padding(.bottom, 28)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                ForEach(keys, id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: keyHeight)
                    } else {
                        Button { tap(key) } label: {
                            // A digit, not copy — `verbatim` says so.
                            Text(verbatim: key)
                                .font(Theme.font(28, .medium))
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: keyHeight)
                                .background(key == "⌫" ? Color.clear : Theme.card,
                                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityIdentifier(key == "⌫" ? "pin.delete" : "pin.key.\(key)")
                    }
                }
            }
            .opacity(disabled ? 0.4 : 1)

            footer
                .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(Theme.bg)
        .onChange(of: shakeToken) { _, _ in
            withAnimation(.default) { shakes += 1 }
            // A shake means the entry is being discarded — any completion
            // still pending for it must not fire.
            completeWork?.cancel()
            completeWork = nil
            shakeClearWork?.cancel()
            let work = DispatchWorkItem { pin = "" }
            shakeClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        .onDisappear {
            shakeClearWork?.cancel()
            completeWork?.cancel()
        }
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            // The entry is no longer complete — drop any completion that was
            // waiting to fire for the digits we're now taking back. Also drop
            // any pending shake-clear: a fast retype inside that window must
            // not have its fresh digits wiped out from under it.
            completeWork?.cancel()
            completeWork = nil
            shakeClearWork?.cancel()
            shakeClearWork = nil
            if !pin.isEmpty { pin.removeLast() }
        } else if pin.count < 4 {
            pin.append(key)
            if pin.count == 4 {
                completeWork?.cancel()
                let done = pin
                let work = DispatchWorkItem { onComplete(done) }
                completeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
    }
}

/// Horizontal jitter driven by an animatable count of shakes.
struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: amount * sin(animatableData * .pi * shakesPerUnit), y: 0))
    }
}
