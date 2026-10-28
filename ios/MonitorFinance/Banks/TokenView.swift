import SwiftUI

/// Paste the token, press connect. The check is real: `client-info` decides
/// whether it belongs, whether it belongs to this person, and what the
/// accounts really are.
struct TokenView: View {
    @Environment(AppStore.self) private var store
    let bankId: String
    var onConnected: () -> Void

    @State private var token = ""
    @State private var error: LocalizedStringKey?
    @State private var connecting = false
    @State private var retryIn: Int = 0
    @State private var newClient: MonobankClientInfo?
    @FocusState private var focused: Bool

    private var bankName: String { store.banks.first { $0.id == bankId }?.displayName ?? bankId }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("Токен \(bankName)").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                        HStack(spacing: 10) {
                            SecureField("Вставте токен сюди", text: $token)
                                .font(Theme.font(16))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused)
                                .accessibilityIdentifier("bank.token.field")
                            Button {
                                if let s = UIPasteboard.general.string { token = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 18))
                                    .foregroundStyle(Theme.green)
                            }
                            .accessibilityIdentifier("bank.token.paste")
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 56)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(error != nil ? Theme.clay : (focused ? Theme.green : Theme.hair), lineWidth: 1.5))
                        if let error {
                            Text(error).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                                .accessibilityIdentifier("bank.token.error")
                        }
                        Text("Токен зберігається лише на цьому пристрої й ніколи нікуди не надсилається, окрім самого банку.")
                            .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    }

                    Card {
                        Text("Де його взяти").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                        // Board #18. Step 1 used to be prose naming an address
                        // with no way to reach it: the person had to leave the
                        // app, find a browser and retype `api.monobank.ua` by
                        // hand, on the one screen where a typo hands their
                        // banking token to whoever registered the near-miss
                        // domain. The step is the link now.
                        linkStep(1, "Відкрийте", Self.portal)
                        step(2, "Натисніть «Отримати токен» і зчитайте QR-код застосунком monobank.")
                        step(3, "Підтвердіть доступ у застосунку.")
                        step(4, "Скопіюйте токен і вставте його у поле вище.")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            // Pinned, never below the fold — the bug the UI suite was born from.
            Button {
                connect()
            } label: {
                HStack(spacing: 10) {
                    if connecting { ProgressView().tint(.white) }
                    Text(buttonTitle)
                        .font(Theme.font(17, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(connecting || retryIn > 0)
            .accessibilityIdentifier("bank.token.connect")
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationTitle(bankName)
        .navigationBarTitleDisplayMode(.inline)
        // The ONLY place `wipeForNewClient` (via `acceptNewClient`) is
        // reachable from: this alert's destructive button, fired only when a
        // person taps it. Cancelling — or dismissing the alert any other
        // way — changes nothing.
        .alert("Інший клієнт monobank", isPresented: Binding(
            get: { newClient != nil },
            set: { if !$0 { newClient = nil } }
        )) {
            Button("Очистити й підключити", role: .destructive) {
                guard let info = newClient else { return }
                store.acceptNewClient(bankId: bankId,
                                      token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                      info: info)
                newClient = nil
                onConnected()
            }
            Button("Скасувати", role: .cancel) { newClient = nil }
        } message: {
            Text("Цей токен належить іншому клієнту monobank. Очистити наявну історію та почати заново?")
        }
    }

    private var buttonTitle: LocalizedStringKey {
        if connecting { return "Перевіряємо токен…" }
        if retryIn > 0 { return "Спробувати за \(retryIn) с" }
        return "Підключити"
    }

    private func connect() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            error = "Вставте токен — поле порожнє."
            return
        }
        error = nil
        focused = false
        connecting = true
        Task {
            switch await store.verifyAndConnect(bankId: bankId, token: t) {
            case .connected:
                connecting = false
                onConnected()
            case .differentClient(let info):
                connecting = false
                newClient = info
            case .failed(let reason):
                connecting = false
                error = Self.message(for: reason)
                if case .rateLimited = reason { startCountdown() }
            }
        }
    }

    /// `LocalizedStringKey`, so `Text(error)` reaches the catalogue.
    static func message(for error: MonobankError) -> LocalizedStringKey {
        switch error {
        case .invalidToken:
            return "Цей токен не підходить. Перевірте, що скопіювали його повністю."
        case .rateLimited:
            return "monobank дозволяє одну перевірку на хвилину. Спробуйте за 60 секунд."
        case .offline:
            return "Немає зв'язку з monobank."
        case .server, .malformed, .windowTooLong, .windowInvalid:
            return "monobank відповів помилкою. Спробуйте пізніше."
        }
    }

    /// Without this the user taps again immediately and earns the same 429.
    private func startCountdown() {
        retryIn = 60
        Task {
            while retryIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                retryIn -= 1
            }
        }
    }

    /// Where monobank hands out a personal token. A `static let` rather than a
    /// literal at the point of use so a test can assert the exact address
    /// without a simulator: this is the one URL in the app a person is asked
    /// to trust with their banking credentials, and «api.mono**b**ank.ua» a
    /// character off is a working domain somebody else could own.
    ///
    /// Non-optional by construction — `URL(string:)` on this constant cannot
    /// fail, and a force unwrap here would be a crash the compiler cannot see.
    /// A nil would render the step as plain text, which is exactly what the
    /// screen did before this card and is a degradation, not a failure.
    static let portal = URL(string: "https://api.monobank.ua")

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            bullet(n)
            Text(text).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
        }
    }

    /// The same row, with the address as the thing you tap.
    @ViewBuilder
    private func linkStep(_ n: Int, _ lead: String, _ url: URL?) -> some View {
        if let url {
            HStack(alignment: .top, spacing: 14) {
                bullet(n)
                Link(destination: url) {
                    HStack(spacing: 6) {
                        // `url.host()` rather than the address written out a
                        // second time: what the person reads and what the tap
                        // opens are then the same string, and cannot drift into
                        // a label that names one domain while opening another.
                        Text("\(lead) \(url.host() ?? url.absoluteString)")
                            .font(Theme.font(15, .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.green)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("bank.token.portal")
                Spacer(minLength: 0)
            }
        } else {
            step(n, "\(lead) api.monobank.ua у браузері.")
        }
    }

    private func bullet(_ n: Int) -> some View {
        Text("\(n)").font(Theme.font(14, .bold)).foregroundStyle(Theme.green)
            .frame(width: 26, height: 26).background(Theme.greenWash, in: Circle())
    }
}
