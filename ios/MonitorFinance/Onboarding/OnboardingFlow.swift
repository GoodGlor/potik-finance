import SwiftUI

enum OnboardingStep: Hashable {
    case setPin
    case confirmPin(String)
    case faceId
    case bankPicker
    case token(String)
    case cards(String)
    case depth(String)
    case connected(String)
    /// Board #91: PrivatBank's row asks letters-or-statement first.
    case privatSource
    case emailSetup
    case importFile
    case importSummary(ImportSummary)
}

/// First run: welcome → set PIN → confirm → Face ID? → then a LOOP through
/// the bank picker — token/cards/depth/connected for a token bank, or a file
/// import for a statement bank — that returns to the picker after each
/// connection so a second (or third) bank can be added. The loop ends only
/// when the picker's «Готово» is tapped, which is offered once at least one
/// bank is connected. Every step is a screen and the back edge exists.
///
/// **The welcome screen is board #16, and the PIN pad used to be the root.**
/// The very first thing the app ever said to anybody was «Придумайте код» —
/// a demand, before a word about what the app is for, from something they had
/// just installed and did not yet have a reason to trust. One screen ahead of
/// it costs a tap and buys the answer to "why am I being asked this".
struct OnboardingFlow: View {
    @Environment(AppStore.self) private var store
    @State private var path: [OnboardingStep] = []
    @State private var mismatch = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView { path.append(.setPin) }
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .setPin:
                    SetPinView(message: mismatch ? "Коди не збігаються — спробуйте ще раз."
                                        : saveFailed ? "Не вдалося зберегти код. Спробуйте ще раз." : nil) { pin in
                        mismatch = false
                        saveFailed = false
                        path.append(.confirmPin(pin))
                    }
                case .confirmPin(let first):
                    ConfirmPinView(first: first) { matched in
                        if matched {
                            do {
                                try store.setPin(first)
                                path.append(.faceId)
                            } catch {
                                saveFailed = true
                                path = [.setPin]
                            }
                        } else {
                            mismatch = true
                            // `path = [.setPin]`, not `removeAll()`. The PIN pad
                            // was the ROOT until board #16, so emptying the path
                            // was how a mismatch got back to it; now that would
                            // land on the welcome screen and the person would be
                            // told nothing about why their second try vanished.
                            path = [.setPin]
                        }
                    }
                case .faceId:
                    FaceIdOfferView { path.append(.bankPicker) }
                case .bankPicker:
                    // allowConnected: re-onboarding after a lost PIN (see the
                    // original comment) — AND the second visit, where the
                    // connected bank's row shows «уже підключено» but stays
                    // tappable for a token re-paste.
                    BankPickerView(
                        allowConnected: true,
                        onFinish: store.connectedBanks.isEmpty ? nil : finishOnboarding
                    ) { bankId in
                        let bank = store.banks.first { $0.id == bankId }
                        if bank?.hasEmailSource == true {
                            path.append(.privatSource)
                        } else if bank?.status == .statement {
                            path.append(.importFile)
                        } else {
                            path.append(.token(bankId))
                        }
                    }
                case .privatSource:
                    PrivatSourceView(onEmail: { path.append(.emailSetup) },
                                     onStatement: { path.append(.importFile) })
                case .emailSetup:
                    // «Далі» back to the picker, exactly like `.connected` and
                    // `.importSummary`: the statement import beside the letters
                    // is then one tap away, which is the whole point of the two
                    // sources not being alternatives.
                    PrivatEmailSetupView(buttonTitle: "Далі") { path.append(.bankPicker) }
                case .token(let bankId):
                    TokenView(bankId: bankId) { path.append(.cards(bankId)) }
                case .cards(let bankId):
                    CardSelectionView(bankId: bankId) { path.append(.depth(bankId)) }
                case .depth(let bankId):
                    SyncDepthView {
                        path.append(.connected(bankId))
                        // First sync of the process: the depth the user just
                        // chose is what it should honour.
                        Task { await store.startSync() }
                    }
                case .connected(let bankId):
                    // «Далі», back to the picker — the flow ends there, on
                    // «Готово», once every wanted bank is in.
                    ConnectedView(bankId: bankId, buttonTitle: "Далі") { path.append(.bankPicker) }
                case .importFile:
                    ImportStatementView { summary in path.append(.importSummary(summary)) }
                case .importSummary(let summary):
                    ImportSummaryView(summary: summary, buttonTitle: "Далі") { path.append(.bankPicker) }
                }
            }
        }
    }

    private func finishOnboarding() {
        store.completeOnboarding()
        // End of onboarding, not launch: a person who never finishes
        // onboarding is never asked.
        Task { await Notifications.requestPermission() }
    }
}

/// The first screen anybody sees. Board #16: it used to be the PIN pad.
///
/// Deliberately one sentence. This is not a tour — the app has nothing to
/// show yet and no data to show it with, so the only honest thing to say is
/// what it will do once a bank is connected. Anything longer is a wall of
/// text between a person and the app they just installed.
struct WelcomeView: View {
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.green)
                .accessibilityHidden(true)
            Text("Потік")
                .font(Theme.font(28, .bold)).foregroundStyle(Theme.ink)
            Text("Бачите, куди йдуть гроші, без ручного обліку.")
                .font(Theme.font(17)).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
            Spacer()
            PrimaryButton(title: "Почати") { onStart() }
                .accessibilityIdentifier("welcome.start")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.title")
    }
}

struct SetPinView: View {
    var message: LocalizedStringKey?
    var onSet: (String) -> Void
    @State private var pin = ""

    var body: some View {
        // Board #16: «Чотири цифри» is the instruction, the rest is the
        // ANSWER to "why are you asking me for one" — which the screen never
        // gave, while being the first thing the app ever said. The two
        // sentences are both here because dropping either leaves a question
        // the person has already asked themselves.
        PinEntry(title: "Придумайте код",
                 subtitle: "Чотири цифри. Ваші фінанси бачитимете лише ви.",
                 message: message, pin: $pin,
                 onComplete: { p in onSet(p); pin = "" }) { EmptyView() }
    }
}

struct ConfirmPinView: View {
    let first: String
    var onResult: (Bool) -> Void
    @State private var pin = ""

    var body: some View {
        PinEntry(title: "Повторіть код",
                 subtitle: "Ще раз, щоб не помилитися.",
                 pin: $pin,
                 onComplete: { p in onResult(p == first) }) { EmptyView() }
    }
}

/// Offered once. Skipped silently where Face ID cannot work (simulator
/// without enrolment, `-noBiometrics`) — the setting stays off and Безпека
/// in settings can turn it on later.
struct FaceIdOfferView: View {
    @Environment(AppStore.self) private var store
    var onDone: () -> Void
    @State private var didAppear = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "faceid").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.green)
            Text("Face ID замість коду?").font(Theme.font(24, .bold)).foregroundStyle(Theme.ink)
            Text("Код залишиться запасним способом.")
                .font(Theme.font(16)).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
            Spacer()
            PrimaryButton(title: "Увімкнути Face ID") {
                Task {
                    if await Biometrics.authenticate(reason: "Щоб входити без коду") {
                        store.setFaceId(true)
                    }
                    onDone()
                }
            }
            .accessibilityIdentifier("onboarding.faceid.enable")
            Button("Пізніше") { onDone() }
                .font(Theme.font(16, .medium)).foregroundStyle(Theme.green)
                .frame(minHeight: 44)
                .accessibilityIdentifier("onboarding.faceid.skip")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(Theme.bg)
        .navigationBarBackButtonHidden()
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            if !Biometrics.isAvailable { onDone() }
        }
    }
}
