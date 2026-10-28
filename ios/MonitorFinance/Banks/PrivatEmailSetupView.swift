import SwiftUI

/// Board #91. The screen that makes board #90's email source reachable: it
/// registers this device, shows the address the backend issued, says what to do
/// with it, and then waits — surfacing the forwarding confirmation code the
/// moment it arrives, because a Gmail rule is never activated without one.
///
/// **Board #113: registration happens behind a button, not on appear.**
/// Arriving is not agreeing. Until PR #123 this screen registered in
/// `.onAppear`, so merely opening it minted a server account — «I didn't add
/// the mail, I just clicked done, and the mail is already tied» was a literal
/// description of the code. Registration is irreversible in three ways at once:
/// the backend shows the secret exactly once, the account then collects a
/// person's mail, and it spends one of the five registrations an hour this IP
/// gets.
///
/// **#91's lesson survives the move.** The call is still an UNSTRUCTURED
/// `Task`, never `.task`: `.task` is cancelled when the view goes away and
/// `URLSession` is cancellation-aware, so a back-tap during the ~1 s request
/// would abort it *after* the backend had already created the account. A button
/// changes what starts the call, not how it is run.
struct PrivatEmailSetupView: View {
    @Environment(AppStore.self) private var store
    /// `LocalizedStringKey` for the same reason `ImportSummaryView.buttonTitle`
    /// is: both callers pass a literal («Далі», «Готово»), and a `String` here
    /// would take the non-localising `Text` overload one layer down.
    var buttonTitle: LocalizedStringKey
    var onContinue: () -> Void

    @State private var address = ""
    /// `LocalizedStringKey`, not `String`. `Text(someStringVariable)` binds to
    /// the VERBATIM overload and would ship Ukrainian to an English reader —
    /// the exact bug board #85 found in `PrimaryButton` and that `TokenView`'s
    /// error line still has.
    @State private var error: LocalizedStringKey?
    /// Two flags, not one. `registering` is the once-per-device call the
    /// address card waits on; `checking` is any later refresh. One shared flag
    /// made «Перевірити» replace the address with «Створюємо адресу…» — a lie
    /// about an address that already exists.
    ///
    /// **Starts `false`, and rises only on the branch that actually registers.**
    /// It started `true` while registration was automatic; leaving it that way
    /// would put «Створюємо адресу…» on screen for one frame under an offer
    /// that has created nothing — the single most misleading frame this screen
    /// could draw.
    @State private var registering = false
    @State private var checking = false
    @State private var confirmations: [PrivatEmailConfirmation] = []
    /// Board #97 — statements waiting on the backend, without their bytes.
    @State private var statements: [PrivatEmailStatement] = []
    /// Board #175 — the last few letters, so «нічого не прийшло» and «прийшло
    /// й не зрозуміли» stop looking identical.
    @State private var recent: [PrivatEmailRecentLetter] = []
    /// Board #174. `nil` means "follow the default" — open while nothing has
    /// arrived, closed once something has. A tap sets it, and a tap is the
    /// only thing that does: this is a reading position, not a preference, so
    /// it is deliberately not persisted.
    @State private var instructionsOpen: Bool?
    /// **WHICH statement is downloading, not WHETHER one is. Board #187.**
    ///
    /// It was a `Bool`, so while one file moved every button on the card
    /// showed a spinner and claimed to be working. With one statement waiting
    /// that is indistinguishable from correct, which is why it survived —
    /// exactly the state this card is about. Board #171 hit the same thing
    /// with links and reached the same answer.
    @State private var importingId: Int?
    @State private var imported: ImportSummary?
    @State private var didStart = false
    /// Latches on the first copy and never resets. The address does not
    /// change, so "you have copied this" stays true — and a checkmark that
    /// timed back out would leave a person who tabbed away to their mailbox
    /// wondering whether the tap registered.
    @State private var copied = false

    /// Numeric on purpose — `dd.MM.yyyy HH:mm` reads the same in both
    /// languages, so there is nothing here for the interface language to change
    /// and no reason to reach for `L10n.formatting`. Same argument
    /// `ImportSummaryView.day` makes.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.timeZone = PrivatStatementParser.kyiv
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// Board #113. What this screen does on arrival, and the whole rule behind
    /// it: **an account is created by a tap, never by a screen appearing.**
    ///
    /// - `.offer` — nothing exists on this device. Explain, and wait.
    /// - `.reissue` — **board #111.** This phone was given an address once and
    ///   no longer holds the secret for it. A new one can be issued, but it
    ///   will not be the same address, and the forwarding rule sitting in
    ///   somebody's mailbox still points at the old one. Silent replacement is
    ///   the failure this case exists to prevent.
    /// - `.connected` — an account already exists, so there is nothing left to
    ///   agree to. No second consent; the screen reads and shows.
    ///
    /// The `address` half is what carries the screen across the tap that
    /// registers — the issued address lands in `@State` and the view flips,
    /// with no Keychain read to be observed. It also covers the pre-existing
    /// reconnect path, where a failed re-registration leaves a stale address
    /// behind with no credentials.
    ///
    /// A static function rather than a computed property because it is the one
    /// rule worth pinning in a unit test, and a view's private state is not
    /// reachable from one.
    enum Arrival: Equatable { case offer, reissue, connected }

    /// `hadIssuedAddress` has **no default**, deliberately. A defaulted
    /// parameter is exactly how both of board #128's call sites went on
    /// silently giving the old answer after the function learned a new one.
    static func arrival(hasCredentials: Bool, address: String,
                        hadIssuedAddress: Bool) -> Arrival {
        if hasCredentials || !address.isEmpty { return .connected }
        return hadIssuedAddress ? .reissue : .offer
    }

    private var arrival: Arrival {
        Self.arrival(hasCredentials: store.privatEmailCredentials != nil,
                     address: address,
                     hadIssuedAddress: store.syncState.emailAddressIssued)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if arrival == .offer {
                        offerCard
                    } else if arrival == .reissue {
                        reissueCard
                    } else {
                        // Board #174. **Status first, setup second**, and the
                        // measurable complaint behind it: the screen's length
                        // did not change as the person succeeded. Three walls
                        // of instructions stood above the one card that says
                        // whether any of it worked, at the same size on the
                        // hundredth visit as on the first — so the thing a
                        // returning person came to see was the thing they had
                        // to scroll past everything else to reach.
                        //
                        // The order is now: who I am (the address), what needs
                        // me (a code, a statement), whether it is working, and
                        // — folded away once it demonstrably is — how to set
                        // it up.
                        addressCard
                        if !confirmations.isEmpty { confirmationCard }
                        if !statements.isEmpty || imported != nil { statementCard }
                        statusCard
                        instructionsSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            PrimaryButton(title: buttonTitle, action: onContinue)
                .accessibilityIdentifier("email.done")
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationTitle("Листи з Приват24")
        .navigationBarTitleDisplayMode(.inline)
        // Board #113: appearing does nothing when there is no account. With one
        // already on this device there is nothing to consent to, so the screen
        // goes and reads — `load()`, which cannot reach a registration at all.
        // `didStart` keeps it to one run.
        .onAppear {
            guard !didStart else { return }
            didStart = true
            guard store.privatEmailCredentials != nil else { return }
            // Synchronously, from the Keychain: a returning person's address is
            // then on screen in the first frame rather than after a round trip.
            address = store.privatEmailAddress ?? ""
            Task { await load() }
        }
    }

    /// Board #113. What a silent registration used to hide, said out loud: what
    /// gets created, who reads the letters, and how to undo it.
    private var offerCard: some View {
        Card {
            Text("Створити адресу для листів")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text("Ми створимо на сервері окрему адресу лише для вас. Листи ПриватБанку читатиме сервер, а покупки з них з'являться на цьому телефоні.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            Text("Відключити можна будь-коли: Налаштування → Банки → ПриватБанк. Адреса тоді перестане приймати листи.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            if let error {
                Text(error).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("email.error")
            }
            // ABOVE the button, not under it. Looked at on a simulator, a
            // reassurance printed below the control reads as a caption on an
            // act already taken; above it, it is the precondition it actually
            // states — and it is the sentence that makes «Далі» obviously free.
            Text("Поки ви не натиснете кнопку, нічого не створено.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
            // The button names the ACT, not the destination. «Підключити пошту»
            // already exists on `BankDetailView` and only navigates there;
            // reusing it here would make one phrase mean two things, one of
            // them irreversible.
            //
            // Deliberately the QUIETER of the two buttons on screen: the loud
            // one at the bottom is «Далі», which costs nothing and can be
            // undone by walking back in. Loud for the reversible act, quiet for
            // the irreversible one is the right way round on a consent screen.
            Button { Task { await connect() } } label: {
                HStack(spacing: 10) {
                    if registering { ProgressView().controlSize(.small) }
                    Text(offerTitle).font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(registering)
            .accessibilityIdentifier("email.connect")
        }
    }

    private var offerTitle: LocalizedStringKey {
        error == nil ? "Створити адресу" : "Спробувати ще раз"
    }

    /// Board #111. The same offer, with the one fact that makes it a different
    /// decision: **the address will not be the same one.**
    ///
    /// Reached when this phone was issued an address and no longer holds the
    /// secret — a restore onto a new phone, because the secret is stored
    /// `…ThisDeviceOnly` and is deliberately left out of backups. Before this
    /// card that state rendered as an ordinary first-time offer, so tapping it
    /// replaced the address in silence while the forwarding rule in somebody's
    /// own mailbox went on sending to the dead one. Sync simply stopped, and
    /// nothing anywhere said why.
    ///
    /// The old rule is named because it is the only part that needs a person's
    /// hands: it is in their mail provider, not in this app, and no amount of
    /// tapping here will repoint it.
    private var reissueCard: some View {
        Card {
            Text("Потрібна нова адреса")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text("Цей телефон уже мав адресу для листів, але ключ до неї не зберігся — так буває після перенесення на новий телефон.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            // The consequence, and the reason this is not just a retry button.
            Text("Нова адреса буде ІНШОЮ. Старе пересилання у вашій пошті й далі надсилатиме листи на стару адресу, доки ви не заміните її на нову — інакше листи просто перестануть надходити.")
                .font(Theme.font(15)).foregroundStyle(Theme.ink)
                .accessibilityIdentifier("email.reissue.warning")
            if let error {
                Text(error).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("email.error")
            }
            Text("Поки ви не натиснете кнопку, нічого не створено.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
            // Names the act, and names it differently from «Створити адресу»:
            // this one replaces something, and a button that reads the same as
            // the first-time one would hide exactly the difference the card
            // above spent three sentences drawing.
            Button { Task { await connect() } } label: {
                HStack(spacing: 10) {
                    if registering { ProgressView().controlSize(.small) }
                    Text(reissueTitle).font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(registering)
            .accessibilityIdentifier("email.reissue")
        }
    }

    private var reissueTitle: LocalizedStringKey {
        error == nil ? "Видати нову адресу" : "Спробувати ще раз"
    }

    private var addressCard: some View {
        Card {
            Text("Ваша адреса").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            if registering {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Створюємо адресу…").font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                }
                .frame(minHeight: 44)
            } else if !address.isEmpty {
                // The address gets the FULL WIDTH and the copy button gets its
                // own row. Sharing one `HStack` with an icon left a real
                // address — `u-0123456789abcdef@in.potik.space`, sixteen hex
                // characters longer than the stub's — wrapping onto three
                // lines and breaking mid-word into «…potik.spac / e».
                //
                // Monospaced, because this is a string a person has to compare
                // character by character against what they pasted, and a
                // proportional font makes `l`/`1` and `0`/`O` a guess.
                // `.byCharAr` is not set: the wrap points are the natural ones,
                // and with the whole width available they are enough.
                Text(verbatim: address)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("email.address")
                // A full-width button, not a 44pt icon: copying IS the action
                // this screen exists for — the address has to reach a mailbox
                // on another device — and it was the smallest target on it.
                Button {
                    UIPasteboard.general.string = address
                    copied = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 16))
                        Text(copied ? "Скопійовано" : "Скопіювати адресу")
                            .font(Theme.font(16, .semibold))
                    }
                    .foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("email.copy")
            }
            if let error {
                Text(error).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("email.error")
            }
            Text("Адреса належить лише вам. Листи читає сервер, а покупки з них потрапляють на цей телефон.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
        }
    }

    /// Shown only when there is one. The mail provider sends its confirmation
    /// code to the issued address, which the person cannot open — so it appears
    /// here in full, subject and body, rather than being parsed for a number
    /// that a change of wording would silently stop finding.
    private var confirmationCard: some View {
        Card {
            Text("Код підтвердження").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            ForEach(confirmations, id: \.id) { letter in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: letter.subject)
                        .font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                    // The identifier goes on the BODY, not on the enclosing
                    // VStack: an identifier on a stack surfaces as an
                    // `otherElement`, so `app.staticTexts["email.confirmation"]`
                    // would silently never match. It is also the half a test
                    // should read — the code itself.
                    Text(verbatim: letter.body)
                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("email.confirmation")
                    Text(verbatim: Self.stamp.string(from: letter.receivedAt))
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// **Board #174 — the setup half, folded away once it has worked.**
    ///
    /// The owner: «Make the Privat Bank settings more understandable, because
    /// they are too confusing, there are a lot of things.»
    ///
    /// `privatEmailRowCount > 0` already answers «is this working», so it
    /// decides the default: open while nothing has arrived, closed once
    /// something has. **A default, not a lock** — `instructionsOpen` overrides
    /// it the moment somebody taps, because a person whose letters stopped
    /// needs to re-read exactly the instructions their own success just hid.
    ///
    /// The state is not persisted. It is a reading position rather than a
    /// preference, and a stored one would outlive the reason it was set.
    @ViewBuilder
    private var instructionsSection: some View {
        Button { instructionsOpen = !instructionsAreOpen } label: {
            HStack(spacing: 8) {
                Text(instructionsAreOpen ? "Сховати налаштування" : "Як налаштувати пересилання")
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                Image(systemName: instructionsAreOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("email.instructions.toggle")
        if instructionsAreOpen {
            forwardingCard
            fileCard
        }
    }

    /// Open while nothing has arrived; closed once something has. See
    /// `instructionsSection` for why this is a default rather than a setting.
    private var instructionsAreOpen: Bool {
        instructionsOpen ?? (store.privatEmailRowCount == 0)
    }

    /// End to end, because a person doing this is switching between two apps
    /// and cannot hold a summary in their head. It is the only way letters
    /// arrive, and the only one where a step can be missed silently — a rule
    /// that is never confirmed looks exactly like a rule that works, until the
    /// letters do not come.
    ///
    /// **Board #172 stopped numbering these.** There were three «Спосіб N»
    /// cards; one of them did not work and was deleted, and the remaining two
    /// are not alternatives at all — this is how purchases start arriving, and
    /// the other is how everything from before today gets here. A number
    /// implies a sequence to work through and a choice between equals, and
    /// neither was true.
    private var forwardingCard: some View {
        Card {
            Text("Пересилання з вашої пошти")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text("Листи ПриватБанку залишаються у вас, а копія приходить сюди.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            step(1, "Скопіюйте адресу кнопкою вище.")
            // Named because it is the step people lose the most time on: the
            // Gmail app has no forwarding settings at all, so somebody
            // following this on a phone hits a dead end with nothing saying
            // why.
            step(2, "Відкрийте налаштування пошти НА КОМП'ЮТЕРІ. У Gmail: «Налаштування» → «Пересилання та POP/IMAP» → «Додати адресу пересилання». У застосунку Gmail цього пункту немає.")
            step(3, "Вставте скопійовану адресу й підтвердьте.")
            step(4, "Пошта надішле на неї код підтвердження. Поверніться сюди, натисніть «Перевірити» — код з'явиться на цьому екрані.")
            step(5, "Введіть код у налаштуваннях пошти та увімкніть пересилання.")
            // The one thing that goes wrong quietly and costs privacy rather
            // than function: forwarding everything works, so nobody notices.
            Text("Порада: там же створіть фільтр за відправником ПриватБанку й позначте «пересилати». Інакше сюди йтиме вся ваша пошта, а не лише листи банку.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
        }
    }

    /// Board #97. Shown only when something is actually waiting — an offer to
    /// import history a person has not sent is an instruction, and the
    /// instruction has its own card below.
    private var statementCard: some View {
        Card {
            if let imported {
                Text("Виписку завантажено").font(Theme.font(17, .semibold))
                    .foregroundStyle(Theme.green)
                    .accessibilityIdentifier("email.statement.done")
                // `verbatim`: two counts, nothing for the interface language
                // to change — and `Plural` already carries both languages.
                Text(verbatim: Self.importedLine(imported, store.settings.languageChoice))
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("email.statement.summary")
            } else {
                Text("Надійшла виписка").font(Theme.font(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("email.statement.waiting")
                Text("Файл, який ви надіслали на цю адресу, готовий до завантаження. Покупки, які вже є в застосунку, не додадуться вдруге.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                ForEach(statements) { item in
                    Button { Task { await importStatement(item) } } label: {
                        HStack(spacing: 10) {
                            if importingId == item.id { ProgressView().controlSize(.small) }
                            VStack(alignment: .leading, spacing: 3) {
                                // **The filename, verbatim.** It is the bank's
                                // own text or the person's own, so it is DATA
                                // — never a localisation key, never rewritten.
                                // It is also the only thing that differs
                                // between two waiting statements today.
                                Text(verbatim: item.filename)
                                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Text(verbatim: Self.statementDetail(item, store.settings.languageChoice))
                                    .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // Still all-or-nothing: two imports at once would race the
                    // same `imported` summary and the same dedup pass. What
                    // changed is that only the one actually working says so.
                    .disabled(importingId != nil)
                    // Keyed by id. Every button carried the SAME identifier,
                    // so with two statements waiting a UI test could only ever
                    // reach the first — it could not have caught this bug.
                    .accessibilityIdentifier("email.statement.import.\(item.id)")
                }
            }
        }
    }

    /// Board #97's second box: the instructions name this path.
    ///
    /// Its own card rather than a line inside the forwarding one, because it
    /// answers a different question. Forwarding is "how do purchases start
    /// arriving"; this is "how does everything BEFORE today get here", and
    /// connecting the email source only ever captures letters from now on.
    /// Board #172's reason for dropping the numbers: these two are not
    /// alternatives, and «Спосіб 1 / Спосіб 3» said they were.
    ///
    /// **Board #173 rewrote the steps, and waited for #171 to land first.**
    /// The old copy described a world where PrivatBank sends a FILE. Board
    /// #145 measured that it usually does not — a statement request produces a
    /// letter carrying a download LINK — so somebody following the old steps
    /// ordered a statement, got something that matched none of them, and
    /// waited for a button that never appeared. The failure was silent from
    /// their side, which is the worst kind of wrong instruction.
    ///
    /// Two things the old copy left out, both of which cost the person time:
    ///
    /// * **The forward is manual.** The Gmail filter is
    ///   `subject:(Операція за карткою)` by the owner's own decision, so a
    ///   statement letter is not caught by the forwarding rule at all. The
    ///   steps silently depended on that and never said so.
    /// * **Both arrivals end at the same place.** A file and a link both
    ///   finish as an imported statement; only the middle differs, and after
    ///   board #171 the link path is a button rather than a trip to a browser.
    private var fileCard: some View {
        Card {
            Text("Історія одним файлом")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text("Пересилання ловить лише нові покупки. Щоб перенести те, що було раніше, замовте виписку в Приват24 і перешліть її сюди листом.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                .accessibilityIdentifier("email.file.instructions")
            step(1, "У Приват24 замовте виписку за потрібний період у форматі Excel.")
            // The step that was missing, and the reason «Спосіб 3» quietly
            // failed: the forwarding rule filters on «Операція за карткою», so
            // it never catches a statement letter. This one has to be sent by
            // hand, and nothing said so.
            step(2, "Банк надішле її вам на пошту. Перешліть цього листа на адресу вище САМІ — правило пересилання ловить лише повідомлення про покупки, а не виписки.")
            step(3, "Поверніться сюди й натисніть «Перевірити».")
            // Both arrivals, both explained, and the difference is one line
            // each. Board #145 measured that the link is the usual one, so it
            // is named first.
            Text("Банк надсилає або посилання, або сам файл. Якщо прийшло посилання — на екрані ПриватБанку з'явиться «Виписка чекає на сайті банку» з кнопкою «Завантажити в додаток». Якщо прийшов файл — він з'явиться тут кнопкою «Завантажити виписку».")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                .accessibilityIdentifier("email.file.linkNote")
            Text("Файл зберігається на сервері не довше тижня і видаляється одразу після завантаження.")
                .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
        }
    }

    /// What tells two waiting statements apart. Board #187.
    ///
    /// **Size and arrival, because the PERIOD is not knowable here.** The span
    /// a statement covers lives inside the xlsx, and the app learns it by
    /// parsing the file — which is the download this line exists to help
    /// somebody choose. Board #97 put the parser on the phone and left the
    /// server a pipe, so there is no field to read. `StatementImport.from`/`.to`
    /// solve this one step later, for files already imported.
    ///
    /// So this shows what is actually known, and claims nothing more. **A
    /// guessed period would be worse than no period** — somebody would pick a
    /// file by it.
    static func statementDetail(_ item: PrivatEmailStatement, _ language: AppLanguage) -> String {
        let kb = max(1, Int((Double(item.sizeBytes) / 1024).rounded()))
        return "\(kb) \(L10n.t("КБ", language)) · \(stamp.string(from: item.receivedAt))"
    }

    /// The counts, in the person's language. Shared shape with `arrived(_:)`.
    static func importedLine(_ summary: ImportSummary, _ language: AppLanguage) -> String {
        let added = Plural.operations(summary.imported, language)
        guard summary.merged > 0 else { return added }
        return "\(added) · \(String(format: L10n.t("уже було: %lld", language), summary.merged))"
    }

    private var statusCard: some View {
        Card {
            if store.privatEmailRowCount > 0 {
                Text("Листи надходять").font(Theme.font(17, .semibold)).foregroundStyle(Theme.green)
                    .accessibilityIdentifier("email.status")
                // `verbatim`: a count and a numeric timestamp, nothing the
                // interface language could change — and a plain `Text(arrived)`
                // would take the same overload anyway, which is worth saying
                // out loud rather than relying on.
                Text(verbatim: Self.arrived(store)).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            } else {
                Text("Листів ще немає").font(Theme.font(17, .semibold)).foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("email.status")
                Text("Перший лист прийде після наступної покупки.")
                    .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
            }
            Button { Task { await check() } } label: {
                HStack(spacing: 10) {
                    if checking { ProgressView().controlSize(.small) }
                    Text(checkTitle).font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(checking || registering)
            .accessibilityIdentifier("email.check")
            // Board #175. Under the status, inside the same card: this IS the
            // status in detail, and a card of its own would say it was a
            // separate subject.
            //
            // **Nothing when nothing arrived.** «Листів ще немає» is a
            // complete answer, and replacing it with an empty list would turn
            // a sentence somebody can read into a shape they have to
            // interpret.
            if !recent.isEmpty {
                Divider().overlay(Theme.hair).padding(.vertical, 2)
                Text("Останні листи").font(Theme.font(15, .medium)).foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(recent) { letter in recentLetterRow(letter) }
            }
        }
    }

    /// Board #175. One letter: when, what it was about, and **what the app
    /// made of it**.
    ///
    /// The sender is deliberately absent. It is the same sender every time —
    /// that is what a forwarding rule filtered on the bank means — so a column
    /// repeating «ПриватБанк» three times costs a line each and says nothing.
    /// The subject and the outcome are what differ.
    private func recentLetterRow(_ letter: PrivatEmailRecentLetter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // `verbatim`: a subject is the BANK's words about the person's own
            // purchase — their data, like a merchant or a card suffix, and
            // never translated. A plain `Text` would bind to this overload
            // anyway; saying so stops somebody "fixing" it into a key.
            Text(verbatim: letter.subject)
                .font(Theme.font(15)).foregroundStyle(Theme.ink)
                .lineLimit(2)
                .accessibilityIdentifier("email.recent.subject")
            HStack(spacing: 6) {
                Text(verbatim: Self.stamp.string(from: letter.receivedAt))
                    .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                Text(verbatim: "·").font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                Text(Self.outcome(of: letter))
                    .font(Theme.font(13, .medium))
                    // The one row that must not read like the others. A letter
                    // that arrived and was not understood is the single most
                    // useful thing this list can say, and today it is
                    // invisible — the count simply fails to move.
                    .foregroundStyle(letter.parseFailed ? Theme.clay : Theme.inkMuted)
                    .accessibilityIdentifier("email.recent.outcome")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the app made of one letter, in the person's language.
    ///
    /// `parseFailed` is checked FIRST: a Privat letter that did not parse is
    /// filed `kind == "transaction"` by the backend — it is unmistakably bank
    /// content — so reading the kind first would call a failure a success.
    static func outcome(of letter: PrivatEmailRecentLetter) -> LocalizedStringKey {
        if letter.parseFailed { return "не вдалося прочитати" }
        switch letter.kind {
        case "transaction": return "операція додана"
        case "forwarding_confirmation": return "код підтвердження"
        case "statement_link": return "виписка"
        // Everything else, including a kind this build has never heard of. An
        // unknown value is displayable without ceremony, which is why `kind`
        // is a String and not an enum — a backend that learns a new one must
        // not make an older phone fail to decode the whole list.
        default: return "не банківський лист"
        }
    }

    /// A count and a numeric timestamp — the one line with nothing for the
    /// interface language to change, which is why it is rendered verbatim.
    /// Shared with `BankDetailView`'s section rather than written twice: both
    /// screens answer the same question and must not drift into two answers.
    static func arrived(_ store: AppStore) -> String {
        // «4 операції», not a bare «4» — looked at on a simulator, the number
        // alone next to a timestamp reads as an id or a code. `Plural` carries
        // both languages, so this stays verbatim without staying Ukrainian.
        //
        // `operations`, not `purchases`: a letter arrives for a salary and for
        // a transfer between your own cards too, and that helper's own doc
        // comment draws exactly this line.
        let counted = Plural.operations(store.privatEmailRowCount, store.settings.languageChoice)
        guard let newest = store.privatEmailNewestDate else { return counted }
        return "\(counted) · \(stamp.string(from: newest))"
    }

    /// What «Перевірити» does. After a FAILED registration there are no
    /// credentials, and refreshing would ask `/status` with none — which comes
    /// back `.unauthorized` and painted «Доступ більше не діє. Відключіть
    /// пошту…» over a screen where nothing was ever connected. Retrying the
    /// registration is what the person actually wants there, and the button
    /// says so.
    private func check() async {
        if store.privatEmailCredentials == nil {
            await connect()
        } else if store.syncState.emailNeedsReconnect {
            // The secret is dead: `/status` and `/letters/pending` will 401
            // forever, so refreshing is not a road back and the person would
            // be told to «підключіть заново» by a screen offering no way to.
            // Forgetting first IS that way — `changePrivatEmailAddress`
            // treats a 401 from DELETE as "already gone", so this cannot
            // orphan a live account — and `connect()` then registers a fresh
            // address. Board #158: this is a genuine address CHANGE, not a
            // disconnect, and it is the one case where the person has no
            // choice — the old secret is dead, so the old address is
            // unreachable whatever anybody prefers.
            _ = await store.changePrivatEmailAddress(force: true)
            await connect()
        } else {
            await refresh()
        }
    }

    private var checkTitle: LocalizedStringKey {
        if store.privatEmailCredentials == nil { return "Спробувати ще раз" }
        if store.syncState.emailNeedsReconnect { return "Підключити заново" }
        return "Перевірити"
    }

    /// **The tap.** The one path on this screen that can create an account, and
    /// the reason it is a separate function from `load()` rather than a branch
    /// inside one: board #113's separation is then something a reader — and a
    /// source guard — can see, instead of a condition they have to evaluate.
    /// `tests/test_ios_consent.py` walks the call graph out of every appear
    /// hook, and the version of this file that had one `prepare()` doing both
    /// jobs is exactly the version it cannot clear.
    ///
    /// Reached from «Створити адресу» and from «Перевірити»'s two retry
    /// branches — every one of them a deliberate act.
    private func connect() async {
        // Cleared on the way IN, so a retry does not run under the message
        // that explained the last attempt's failure.
        error = nil
        registering = true
        // Safe to call unconditionally: `registerPrivatEmail` answers
        // `.alreadyRegistered` while credentials are stored rather than minting
        // a second account, so a double tap costs nothing.
        switch await store.registerPrivatEmail() {
        case .registered(let issued), .alreadyRegistered(let issued):
            address = issued
        case .failed(let reason):
            error = Self.message(for: reason)
            registering = false
            return
        }
        // Lowered BEFORE the refresh, not in a `defer`: a `defer` would run
        // after `refresh()` returns, so the address card would sit on its
        // «Створюємо адресу…» spinner for the whole first read — hiding the
        // address that had just arrived, which is the one thing this screen
        // exists to show.
        registering = false
        await refresh()
    }

    /// Everything the screen can learn about an account that **already exists**.
    /// The only thing `.onAppear` is allowed to reach, and it creates nothing.
    private func load() async {
        error = nil
        if address.isEmpty { address = store.privatEmailAddress ?? "" }
        await refresh()
    }

    /// Everything the screen can learn, plus one sync run.
    ///
    /// `syncPrivatEmail`, not the gated `…IfConnected`: the fixture guard on
    /// that one exists to keep a bundled-dataset UI suite from having rows
    /// appear under it, and a person standing on this screen having tapped
    /// «Перевірити» is exactly the deliberate act it is not meant to block.
    private func refresh() async {
        checking = true
        defer { checking = false }
        if address.isEmpty {
            // The stored pair outlived its address (a partial write, a manual
            // reset). `/status` is the backend's own answer and writes it back
            // into the Keychain on the way through.
            address = (try? await store.privatEmailStatus().email) ?? ""
        }
        do {
            confirmations = try await store.privatEmailPending().confirmations
            error = nil
        } catch let known as PrivatEmailError {
            error = Self.message(for: known)
        } catch {
            self.error = Self.message(for: .offline(""))
        }
        // Board #97, and deliberately NOT in the do-block above.
        //
        // A backend that predates this card has no `/statements` route, so it
        // answers 404 — and folding that in with the confirmation fetch would
        // paint «Сервер відповів помилкою» over a screen whose every other
        // part works, breaking the forwarding-code flow the moment the phone
        // updated ahead of the server. An absent capability is not an error;
        // it is an empty list.
        //
        // A real failure is not lost either: `privatEmailStatements` still
        // flags a dead secret through `noteIfUnauthorized` on its way past.
        statements = (try? await store.privatEmailStatements()) ?? []
        // Board #175, and outside the do-block for the same reason as the
        // line above: a backend predating the route answers 404, and an
        // absent capability is not an error worth painting over a working
        // screen. `privatEmailRecentLetters` already swallows it and still
        // flags a dead secret on the way past.
        recent = await store.privatEmailRecentLetters()
        await store.syncPrivatEmail()
    }

    /// Board #97. Fetch, parse, and stop offering it.
    ///
    /// The failure is reported on this screen rather than thrown away: a
    /// person who forwarded the wrong file needs to be told that, and the
    /// statement stays on the server for them to replace.
    private func importStatement(_ item: PrivatEmailStatement) async {
        importingId = item.id
        defer { importingId = nil }
        do {
            imported = try await store.importEmailedStatement(item)
            statements.removeAll { $0.id == item.id }
        } catch let known as PrivatEmailError {
            error = Self.message(for: known)
        } catch {
            // A parse failure, not a transport one — the file arrived and was
            // not a statement this app can read.
            self.error = "Не вдалося прочитати цей файл. Перевірте, що це виписка з Приват24 у форматі Excel."
        }
    }

    /// `LocalizedStringKey`, so `Text(error)` reaches the catalogue. The
    /// `String`-returning twin in `TokenView.message(for:)` does not, and a
    /// `String`-typed error is exactly how a screen quietly stays Ukrainian.
    static func message(for error: PrivatEmailError) -> LocalizedStringKey {
        switch error {
        case .unauthorized:
            // Says what reconnecting COSTS, because it is not free: the new
            // account gets a new address, so the forwarding rule has to be
            // pointed at it again.
            return "Доступ більше не діє. Підключіть заново — адреса буде нова."
        case .rateLimited:
            return "Забагато спроб поспіль. Спробуйте за годину."
        case .offline:
            return "Немає зв'язку із сервером."
        case .server, .malformed:
            return "Сервер відповів помилкою. Спробуйте пізніше."
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(Theme.font(14, .bold)).foregroundStyle(Theme.green)
                .frame(width: 26, height: 26).background(Theme.greenWash, in: Circle())
            Text(text).font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
        }
    }
}
