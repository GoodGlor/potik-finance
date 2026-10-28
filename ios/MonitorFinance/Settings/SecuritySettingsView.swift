import SwiftUI

struct SecuritySettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: [SettingsRoute]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    Toggle(isOn: Binding(
                        get: { store.settings.faceIdEnabled },
                        set: { on in
                            if on {
                                Task { if await Biometrics.authenticate(reason: "Щоб входити без коду") { store.setFaceId(true) } }
                            } else {
                                store.setFaceId(false)
                            }
                        })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Face ID").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                            Text(Biometrics.isAvailable ? "Замість коду при вході" : "Недоступно на цьому пристрої")
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    .tint(Theme.green)
                    .disabled(!Biometrics.isAvailable)
                    .accessibilityIdentifier("settings.faceid")
                }
                Card {
                    Toggle(isOn: Binding(
                        get: { store.settings.locksImmediately },
                        set: { store.setLockImmediately($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Блокувати одразу").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                            // Says what the OTHER position does, because that
                            // is the one it is in by default and the one whose
                            // behaviour is surprising if unexplained.
                            Text(store.settings.locksImmediately
                                 ? "Код при кожному поверненні в застосунок"
                                 : "Перша хвилина після виходу — без коду")
                                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    .tint(Theme.green)
                    .accessibilityIdentifier("settings.lockImmediately")
                }
                Card {
                    Button { path.append(.changePin) } label: {
                        HStack {
                            Text("Змінити код").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.changePin")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Безпека")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Current → new → confirm, all on the same pad. Mismatch goes back to "new".
/// Pushed onto Home's shared settings path; `onDone` pops just this route.
struct ChangePinFlow: View {
    @Environment(AppStore.self) private var store
    var onDone: () -> Void
    private enum Step { case current, new, confirm, done }
    @State private var step: Step = .current
    @State private var pin = ""
    @State private var newPin = ""
    @State private var message: LocalizedStringKey?
    @State private var shakeToken = 0

    var body: some View {
        Group {
            switch step {
            case .current:
                PinEntry(title: "Поточний код", subtitle: "Спершу підтвердьте, що це ви.",
                         message: message, pin: $pin, shakeToken: shakeToken, onComplete: { p in
                    if store.verifyPin(p) { message = nil; pin = ""; step = .new }
                    else { message = "Невірний код"; shakeToken += 1 }
                }) { EmptyView() }
            case .new:
                PinEntry(title: "Новий код", subtitle: "Чотири цифри.",
                         message: message, pin: $pin, onComplete: { p in
                    newPin = p; pin = ""; message = nil; step = .confirm
                }) { EmptyView() }
            case .confirm:
                PinEntry(title: "Повторіть новий код", subtitle: "Ще раз, щоб не помилитися.",
                         pin: $pin, onComplete: { p in
                    if p == newPin {
                        do {
                            try store.setPin(p)
                            step = .done
                        } catch {
                            message = "Не вдалося зберегти код. Спробуйте ще раз."
                            pin = ""
                            step = .new
                        }
                    } else {
                        message = "Коди не збігаються — спробуйте ще раз."; pin = ""; step = .new
                    }
                }) { EmptyView() }
            case .done:
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 48, weight: .light)).foregroundStyle(Theme.green)
                    Text("Код змінено").font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                    PrimaryButton(title: "Готово", action: onDone)
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                .background(Theme.bg)
            }
        }
        .navigationTitle("Зміна коду")
        .navigationBarTitleDisplayMode(.inline)
    }
}
