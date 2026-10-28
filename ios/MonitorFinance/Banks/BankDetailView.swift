import SwiftUI

struct BankDetailView: View {
    @Environment(AppStore.self) private var store
    let bankId: String
    @Binding var path: [SettingsRoute]
    @State private var confirming = false
    /// Board #148 — which statement the two-way delete dialog is about.
    /// A value rather than a Bool: the dialog names the file and states the
    /// cost, and both come from the record.
    @State private var deletingStatement: StatementImport?
    @State private var forgettingEmail = false
    @State private var changingAddress = false
    /// Board #170 — «Видалити адресу назавжди», the one act that leaves this
    /// phone with no mailbox at all.
    @State private var deletingAddress = false
    /// Board #166 — «Прибрати операції», for a bank already disconnected.
    @State private var removingRows = false
    /// Board #171 — which link is being fetched, so its own row spins and the
    /// others do not. A `Bool` would have made every link on the card look
    /// busy while one of them was.
    @State private var downloadingLink: Int?
    @State private var linkError: LocalizedStringKey?
    /// Board #145 — a download link PrivatBank emailed instead of a file.
    @State private var statementLinks: [PrivatEmailStatementLink] = []
    /// `LocalizedStringKey` for the same reason `PrivatEmailSetupView.error`
    /// is — it holds that view's `message(for:)` output, and a `String` would
    /// take `Text`'s verbatim overload and never reach the catalogue.
    @State private var emailError: LocalizedStringKey?
    /// Board #170. Which action the message under the card belongs to, so its
    /// escape hatch offers the right second-best answer. Both failures look
    /// identical — the same request, the same errors — and before this the
    /// screen answered every one of them with «Все одно видати нову адресу»,
    /// which is the wrong offer to somebody who asked for no address at all.
    @State private var emailRetry: EmailRetry = .change

    private enum EmailRetry { case change, delete }

    private var bank: Bank? { store.banks.first { $0.id == bankId } }

    /// Hoisted out of the `ViewBuilder`, where a compound condition costs real
    /// type-checking time — SourceKit gave up on the inline version.
    private var showsAccounts: Bool {
        guard let bank else { return false }
        return bank.connected && !bank.accounts.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // An email-only connection has no accounts at all — a letter
                // carries no balance to build one from — so this card would
                // otherwise render as a lone heading. `ConnectedView` already
                // guards its own copy of the same list.
                //
                // **`connected` too, and a screenshot is why.** Board #166 made
                // a disconnected bank's screen reachable, and the first thing
                // on it was «Картки»: four balances frozen at the moment of
                // disconnection, above four live toggles choosing which cards
                // to download — for a bank that downloads nothing. Same class
                // of defect board #165 fixed on Home, newly visible because
                // this route is new. The card is a control surface, not a
                // record of where the history came from.
                // Board #171, and a screenshot moved it here. A waiting
                // statement is the one thing on this screen that needs acting
                // on now — and it was BELOW the mail settings, off the bottom
                // of the display, so somebody who opened this screen *because*
                // a statement arrived met a wall of settings first.
                //
                // It only became worth fixing with this card: while the link
                // was informational, its position cost a scroll. Now it
                // carries the action, and the action was the thing out of
                // sight. Settings are permanent and can wait; this cannot.
                ForEach(statementLinks) { link in statementLinkCard(link) }
                if showsAccounts { accountsCard }
                if bank?.hasEmailSource == true { emailSection }
                if bank?.status == .statement {
                    Button { path.append(.importStatement) } label: {
                        Text("Імпортувати виписку")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.importStatement")
                }
                if !store.statementImports.isEmpty { statementsSection }
                // Board #166. A bank already disconnected has nothing left to
                // disconnect, and its rows are the only reason this screen is
                // reachable at all — `pastBanks` lists it precisely because
                // they are still here. Offering «Відключити банк» would be a
                // button that does nothing to a bank that is already off.
                if bank?.connected == false {
                    Text("Цей банк відключено. Нових операцій не буде — старі можна залишити або прибрати.")
                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("bank.past.status")
                    Button { removingRows = true } label: {
                        Text("Прибрати операції")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.past.removeRows")
                } else {
                    Button { confirming = true } label: {
                        Text("Відключити банк")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.disconnect")
                    // Board #157. Two NAMED answers and no default — the shape
                    // board #148 established for a statement file, copied rather
                    // than redesigned. Keeping the history stays the default;
                    // what was missing was the other answer being offered at all.
                    .confirmationDialog("Відключити \(bank?.displayName ?? "")?", isPresented: $confirming, titleVisibility: .visible) {
                        Button("Відключити банк") { disconnectBank(removingTransactions: false) }
                            .accessibilityIdentifier("bank.disconnect.confirm")
                        // `.destructive` on this one alone. The other answer takes
                        // nothing away, and two red buttons would make the choice
                        // look like a formality between identical outcomes.
                        Button("Відключити разом з операціями", role: .destructive) {
                            disconnectBank(removingTransactions: true)
                        }
                        .accessibilityIdentifier("bank.disconnect.withTransactions")
                        Button("Скасувати", role: .cancel) {}
                    } message: {
                        Text(disconnectCostMessage)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle(bank?.displayName ?? bankId)
        .navigationBarTitleDisplayMode(.inline)
        // Board #166. The same question «Відключити разом з операціями» asks,
        // put back within reach — and an `.alert` rather than a dialog for the
        // reason board #170 recorded: a `confirmationDialog` can render as a
        // popover, where iOS drops the cancel button and a destructive answer
        // is the only one on screen.
        //
        // Attached HERE rather than to the button that opens it: that button
        // lives inside an `if`, and a modifier cannot hang off an `if` in a
        // ViewBuilder — the compiler says «instance member 'alert' cannot be
        // used on type 'View'», which does not sound like what it means.
        .alert("Прибрати операції?", isPresented: $removingRows) {
            Button("Прибрати", role: .destructive) {
                store.removeTransactions(ofBank: bankId)
                // Back to the list: the bank has no rows left, so `pastBanks`
                // has already dropped it and this screen is about to describe
                // something that is not there.
                path = [.settings, .banks]
            }
            .accessibilityIdentifier("bank.past.removeRows.confirm")
            Button("Залишити", role: .cancel) {}
        } message: {
            // The same count the disconnect dialog states, from the same
            // `bankDisconnectCost` — one source, so the number and its Ukrainian
            // grammar cannot drift between the two screens.
            Text(removeRowsCostMessage)
        }
        // The confirmationDialog is UIKit-presented above RootView's ZStack —
        // including the lock overlay. Backgrounding re-locks the app but does
        // not itself dismiss a dialog already on screen, so close it here the
        // moment we're no longer unlocked, or "Відключити" stays tappable
        // over a locked app with no PIN required. Both dialogs, or the newer
        // one inherits exactly the bug the older one was fixed for.
        // Board #145. One request, on arrival, and only for a bank that has an
        // email source. `privatEmailStatementLinks` swallows a 404 — an older
        // backend simply has no links — so this cannot put an error on a
        // screen about something the person never asked for.
        .task {
            guard bank?.hasEmailSource == true else { return }
            statementLinks = await store.privatEmailStatementLinks()
        }
        .onChange(of: store.isUnlocked) { _, unlocked in
            if !unlocked {
                confirming = false
                forgettingEmail = false
                // Board #158's dialog, added under the rule the comment above
                // states: it is the destructive one now, so leaving it out
                // would put «Видати нову» over a locked app.
                changingAddress = false
                // Boards #170 and #166. Alerts rather than dialogs, but the
                // rule is the same one and for the same reason — a destructive
                // answer must not stay tappable over a locked app. Every
                // presentation on this screen is listed here on purpose; the
                // one left out is the one that reproduces the bug.
                deletingAddress = false
                removingRows = false
            }
        }
    }

    /// Board #148 — «Виписки», the list the owner asked for.
    ///
    /// Newest first: the reason somebody opens this is almost always the file
    /// they imported last, and a chronological list puts it at the bottom of
    /// a growing column.
    private var statementsSection: some View {
        Card {
            Text("Виписки").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
            ForEach(store.statementImports.reversed()) { record in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        // The filename is the person's own — their file, off
                        // their disk — so it is DATA and never translated,
                        // the same rule as a merchant or a card suffix.
                        Text(record.filename)
                            .font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("bank.statement.name")
                        Spacer(minLength: 8)
                        Button { deletingStatement = record } label: {
                            Text("Видалити")
                                .font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bank.statement.delete")
                    }
                    // Both numbers, because one of them alone means neither:
                    // "412 операцій" hides that a re-import added nothing, and
                    // the merged count alone hides what the file actually
                    // brought.
                    // The period the file COVERS, asked for by the owner and
                    // the more useful of the two dates: which months a
                    // statement holds is what tells you whether you still
                    // need it, and the day you happened to import it does not.
                    if let span = statementPeriod(record) {
                        Text(span)
                            .font(Theme.font(13)).foregroundStyle(Theme.inkSoft)
                            .accessibilityIdentifier("bank.statement.period")
                    }
                    Text(statementDetail(record))
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("bank.statement.detail")
                }
                .padding(.vertical, 2)
                // Looked at on a simulator: a record with a period line is
                // three lines tall, and without a rule the next filename
                // reads as a fourth line of the same entry.
                if record.id != store.statementImports.first?.id {
                    Divider().overlay(Theme.hair)
                }
            }
        }
        .confirmationDialog(deletingStatement?.filename ?? "",
                            isPresented: Binding(get: { deletingStatement != nil },
                                                 set: { if !$0 { deletingStatement = nil } }),
                            titleVisibility: .visible) {
            // Two named actions and no default, because the owner asked for
            // the question rather than a choice made on their behalf: «ask
            // the user whether to delete just the file or with transactions».
            Button("Видалити лише файл") {
                if let record = deletingStatement { store.forgetStatementImport(record.id) }
                deletingStatement = nil
            }
            Button("Видалити разом з операціями", role: .destructive) {
                if let record = deletingStatement { store.deleteStatementImport(record.id) }
                deletingStatement = nil
            }
            Button("Скасувати", role: .cancel) { deletingStatement = nil }
        } message: {
            // **The cost, before the tap.** A person who reads what they lost
            // afterwards was never given the choice — the same reason the
            // budget scope card states its cost up front.
            Text(deletionCostMessage)
        }
    }

    /// «за 3 січ – 28 серп 2026», or nil when the file carried no period.
    ///
    /// Nil rather than a placeholder: a statement whose period could not be
    /// read says nothing about its months, and inventing a dash for that is
    /// worse than one fewer line. Both dates carry the year only when they
    /// disagree, because «3 січ 2026 – 28 серп 2026» is the same fact twice.
    private func statementPeriod(_ record: StatementImport) -> String? {
        guard let from = record.from, let to = record.to else { return nil }
        let sameYear = KyivFormat.string(from, "yyyy") == KyivFormat.string(to, "yyyy")
        let start = KyivFormat.string(from, sameYear ? "d MMM" : "d MMM yyyy")
        let end = KyivFormat.string(to, "d MMM yyyy")
        return String(format: L10n.t("за %@ – %@", store.settings.languageChoice), start, end)
    }

    private func statementDetail(_ record: StatementImport) -> String {
        let when = KyivFormat.string(record.importedAt, "d MMMM yyyy")
        let live = store.statementDeletionCost(record).rows
        let language = store.settings.languageChoice
        // `Plural.operations`, never "%lld операцій": Ukrainian takes three
        // forms and 2–4 is «операції». A screenshot is what caught «3
        // операцій» here — no assertion in this repo would have.
        let counted = Plural.operations(live, language)
        if record.merged > 0 {
            return when + " · " + counted + " · "
                + String(format: L10n.t("%lld вже було", language), record.merged)
        }
        return when + " · " + counted
    }

    private var deletionCostMessage: String {
        guard let record = deletingStatement else { return "" }
        let cost = store.statementDeletionCost(record)
        let language = store.settings.languageChoice
        // `String(format:)` around a LITERAL key, never interpolation into
        // one: an interpolated key is a key no catalogue can ever contain, so
        // the string would silently fall through untranslated.
        if cost.rows == 0 {
            return L10n.t("Операцій із цього файлу вже немає — залишиться прибрати сам запис.",
                          language)
        }
        let counted = Plural.operations(cost.rows, language)
        if cost.decided > 0 {
            return String(format: L10n.t("Зникнуть %@, з них %lld ви вже розібрали.", language),
                          counted, cost.decided)
        }
        return String(format: L10n.t("Зникнуть %@.", language), counted)
    }

    private var accountsCard: some View {
        Card {
            Text("Картки").font(Theme.font(17, .medium)).foregroundStyle(Theme.inkSoft)
            ForEach(bank?.accounts ?? []) { a in
                HStack {
                    // On the leaf, and NOT `bank.account.\(a.suffix)`: a card
                    // suffix is the owner's own, and an identifier built from
                    // one puts it in every test that queries the row. The test
                    // only needs to know accounts render at all.
                    Text(a.suffix).font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("bank.account")
                    Text(a.type).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(a.balance.uah).font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                        if let limit = a.creditLimit {
                            Text("ліміт \(limit.uah)").font(Theme.font(12)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    if bank?.status == .available {
                        Toggle("", isOn: Binding(
                            get: { a.syncEnabled != false },
                            set: { store.setSyncEnabled(bankId: bankId, accountId: a.id, $0) }))
                            .labelsHidden()
                            .tint(Theme.green)
                            .accessibilityIdentifier("bank.account.toggle")
                            // A runtime LABEL built from the model, not an
                            // identifier and not a literal — the no-suffix rule
                            // binds identifiers, not what VoiceOver reads aloud
                            // for this person's own card.
                            .accessibilityLabel("Синхронізувати \(a.suffix)")
                    }
                }
                .frame(minHeight: 44)
            }
        }
    }

    /// Board #91. Everything here is read from LOCAL state — the stored
    /// address, the rows whose `externalId` carries the letter prefix, and the
    /// newest of those. No request on appear: what a person wants from a
    /// settings screen is what their phone actually holds, and «Перевірити» is
    /// the one control that goes and asks for more.
    private var emailSection: some View {
        Card {
            Text("Листи з Приват24").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            // Gated on CREDENTIALS alone, never on credentials-and-address —
            // the same widening `registerPrivatEmail` argues for. A stored pair
            // whose address went missing is connected, and calling it «Не
            // підключено» would offer to register a second account.
            if store.privatEmailCredentials != nil {
                if let address = store.privatEmailAddress {
                    Text(verbatim: address)
                        .font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("bank.email.address")
                }
                // Three branches of `Text(LocalizedStringKey)` rather than one
                // `Text(someString)`: a String variable takes the verbatim
                // overload, and the two fixed lines would never reach the
                // catalogue. Only the counted line is verbatim, and it is
                // digits and a numeric date — nothing to translate.
                if store.syncState.emailNeedsReconnect {
                    Text("Доступ більше не діє — підключіть пошту заново.")
                        .font(Theme.font(14)).foregroundStyle(Theme.clay)
                        .accessibilityIdentifier("bank.email.status")
                } else if store.syncState.emailPaused {
                    // Board #158. Above `emailNeedsReconnect`? No — below it,
                    // deliberately. A dead secret outranks a pause: resuming
                    // would not help, and telling somebody their import is
                    // merely paused when the address can never work again is
                    // the more expensive of the two wrong answers.
                    Text("Імпорт вимкнено. Адреса жива й далі приймає листи.")
                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("bank.email.status")
                } else if store.privatEmailRowCount > 0 {
                    Text(verbatim: PrivatEmailSetupView.arrived(store))
                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("bank.email.status")
                } else {
                    Text("Листів ще немає.")
                        .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                        .accessibilityIdentifier("bank.email.status")
                }
                // A dead secret makes «Перевірити» useless — every request
                // 401s — and the line above has just told the person to
                // connect again, so this is where that becomes possible. It
                // only navigates: the setup screen owns the forget-and-
                // re-register, so nothing irreversible happens on a screen
                // whose button says «Перевірити» to everyone else.
                if store.syncState.emailNeedsReconnect {
                    Button { path.append(.emailSetup) } label: {
                        Text("Підключити заново")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.reconnect")
                } else {
                    Button { Task { await store.syncPrivatEmail() } } label: {
                        Text("Перевірити")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // Board #158. A paused import makes «Перевірити» a button
                    // that does nothing — `syncPrivatEmail` returns straight
                    // away — and a control that answers a tap with silence is
                    // how somebody concludes the app is broken.
                    .disabled(store.isEmailSyncing || store.syncState.emailPaused)
                    .accessibilityIdentifier("bank.email.check")
                }
                // Board #112 — the door that was missing. `PrivatEmailSetupView`
                // already draws everything a person needs to redo a forwarding
                // rule (the address, a copy button, both methods step by step,
                // the confirmation code), and once connected and healthy this
                // screen had NO route to it: «Підключити пошту» is the
                // not-connected branch and «Підключити заново» the dead-secret
                // one. So the only visible way to touch the email setup again
                // was «Відключити пошту», which destroys the address — and
                // «no way to change the mail» was a fair description.
                //
                // Safe to send somebody there precisely because of board #113:
                // arriving at that screen acts on nothing, so this button only
                // navigates.
                // The two captions are a PAIR and only work as one. Either
                // sentence alone is a fact; together they are the distinction
                // the owner could not see, which is why they are written as a
                // contrast — «та сама» against «буде інша».
                //
                // Each is bound to ITS button by a tighter `VStack` rather than
                // left to the `Card`'s uniform 12pt: looked at on a simulator,
                // an evenly spaced caption sits as close to the NEXT button as
                // to its own, and the one that must not be misread is the one
                // between them. Colour alone was not enough.
                //
                // Before the tap, not only inside the confirmation dialog: a
                // consequence somebody reads after choosing is not what let
                // them choose. «Перевірити» deliberately gets none — it is the
                // safe, obvious one, and a third grey line stops all three
                // being read.
                VStack(alignment: .leading, spacing: 2) {
                    Button { path.append(.emailSetup) } label: {
                        Text("Як налаштувати пересилання")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.instructions")
                    Text("Адреса залишиться та сама.")
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("bank.email.instructions.cost")
                }
                VStack(alignment: .leading, spacing: 2) {
                    // Board #158, and this was caught by LOOKING at the screen
                    // rather than by any assertion. This button kept `clay`
                    // from when it deleted the account, so the paused state
                    // rendered «Відновити пошту» — the safest action on the
                    // card — in the same red as «Змінити адресу», the only
                    // one that destroys anything. A colour is a claim, and
                    // three red things in a column say none of them matters
                    // more than the others.
                    Button { forgettingEmail = true } label: {
                        Text(store.syncState.emailPaused ? "Відновити пошту" : "Відключити пошту")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.disconnect")
                    // Board #158. The old line said «Адреса перестане приймати
                    // листи, нова буде інша» — and after this card that would
                    // be a lie in both halves. Disconnecting stops the import
                    // and nothing else: the address goes on accepting letters,
                    // the forwarding rule can stay where it is, and resuming
                    // brings back the same address with no registration.
                    Text(store.syncState.emailPaused
                         ? "Адреса та сама — імпорт почнеться з того місця, де спинився."
                         : "Адреса залишиться вашою й далі прийматиме листи. Пересилання можна не чіпати.")
                        .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("bank.email.disconnect.cost")
                }
                // Board #158. The ONLY path that ends an address, kept apart
                // from the pause above and labelled for what it costs. It is
                // also the answer to a leaked address, which is the reason it
                // has to exist at all rather than being folded into the
                // disconnect the owner asked to make harmless.
                VStack(alignment: .leading, spacing: 2) {
                    Button { changingAddress = true } label: {
                        Text("Змінити адресу")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.changeAddress")
                    Text("Стара адреса перестане приймати листи. Пересилання у своїй пошті доведеться перенаправити.")
                        .font(Theme.font(13)).foregroundStyle(Theme.clay)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("bank.email.changeAddress.cost")
                }
                // Board #170. The one act that leaves this phone with NO
                // mailbox — for somebody giving the phone away or leaving the
                // app, who today can only swap one address for another.
                //
                // **It sits below a rule, and that is the whole design.** Two
                // clay buttons a row apart, differing by one word, is the
                // shape board #168's screenshot rejected in the reset alert;
                // reproducing it here would be building the same trap on the
                // screen the trap was moved to avoid. The rule says these are
                // not two flavours of one action. The label carries
                // «назавжди», which appears nowhere else in the app, and each
                // button keeps its own caption bound to it by a tight `VStack`
                // — board #112's fix, for the same reason: an evenly spaced
                // caption sits as close to the next button as to its own.
                Divider().overlay(Theme.hair).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Button { deletingAddress = true } label: {
                        Text("Видалити адресу назавжди")
                            .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.deleteAddress")
                    // Says the irrecoverable part, because it is the part that
                    // separates this from the button above it: `POST /register`
                    // only ever mints a new random address, and the backend has
                    // no call that gives an old one back.
                    Text("Пошта вимкнеться, і цієї адреси більше не буде. Нова, якщо колись знадобиться, буде інша.")
                        .font(Theme.font(13)).foregroundStyle(Theme.clay)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("bank.email.deleteAddress.cost")
                }
                if let emailError {
                    Text(emailError).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                        .accessibilityIdentifier("bank.email.error")
                    // Board #158's shape, restored by #170: a failed request
                    // asks rather than proceeding anyway, and the escape is
                    // offered SECOND because forgetting locally leaves the old
                    // address alive and still collecting this person's letters.
                    // The offer follows the action that failed — «видати нову»
                    // is no answer at all to somebody who asked for none.
                    Button {
                        switch emailRetry {
                        case .change: changeAddress(force: true)
                        case .delete: deleteAddress(force: true)
                        }
                    } label: {
                        Text(emailRetry == .change
                             ? "Все одно видати нову адресу"
                             : "Видалити лише з телефона")
                            .font(Theme.font(15, .semibold)).foregroundStyle(Theme.clay)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bank.email.forgetAnyway")
                    if emailRetry == .delete {
                        // The cost of the escape, before it is taken. #158 wrote
                        // this sentence for the reset and #168 removed the only
                        // screen that could show it; this is the same warning
                        // for the same orphan.
                        Text("Адреса залишиться живою на сервері й далі прийматиме листи, а прочитати їх буде нікому.")
                            .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("bank.email.forgetAnyway.cost")
                    }
                }
            } else if store.syncState.emailAddressIssued {
                // Board #111. This phone had an address and no longer holds
                // the secret — a restore onto a new phone. Calling that «Не
                // підключено» beside a «Підключити пошту» button describes a
                // first-time setup, and it is not one: the next address will
                // be a different address, and somebody's forwarding rule still
                // points at the old.
                Text("Ключ до адреси не зберігся").font(Theme.font(15)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("bank.email.status")
                Button { path.append(.emailSetup) } label: {
                    Text("Видати нову адресу")
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bank.email.reissue")
                Text("Нова адреса буде іншою — пересилання у вашій пошті треба буде замінити.")
                    .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("bank.email.reissue.cost")
            } else {
                Text("Не підключено").font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                    .accessibilityIdentifier("bank.email.status")
                Button { path.append(.emailSetup) } label: {
                    Text("Підключити пошту")
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bank.email.connect")
            }
        }
        // Board #158. No longer destructive and no longer a `.destructive`
        // role: nothing is deleted, so a red button would be telling the
        // person something the action does not do. Resuming needs no
        // confirmation at all — it costs nothing — but it shares the dialog so
        // the two states cannot drift apart in the button that opens them.
        .confirmationDialog(store.syncState.emailPaused ? "Відновити пошту?" : "Відключити пошту?",
                            isPresented: $forgettingEmail, titleVisibility: .visible) {
            if store.syncState.emailPaused {
                Button("Відновити") { store.resumePrivatEmail() }
                    .accessibilityIdentifier("bank.email.disconnect.confirm")
            } else {
                Button("Відключити") { store.pausePrivatEmail() }
                    .accessibilityIdentifier("bank.email.disconnect.confirm")
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text(store.syncState.emailPaused
                 ? "Листи, що надійшли за цей час, підтягнуться."
                 : "Нові листи не завантажуватимуться. Адреса залишиться вашою, пересилання можна не чіпати — увімкнути можна будь-коли.")
        }
        .confirmationDialog("Змінити адресу?", isPresented: $changingAddress,
                            titleVisibility: .visible) {
            Button("Видати нову", role: .destructive) { changeAddress(force: false) }
                .accessibilityIdentifier("bank.email.changeAddress.confirm")
            Button("Скасувати", role: .cancel) {}
        } message: {
            // Said before the tap, and said completely: this is the one action
            // in the app whose consequence lands OFF the phone, in a mailbox
            // this app cannot reach.
            Text("Стару адресу буде видалено — листи на неї більше не дійдуть. У своїй пошті пересилання треба буде перенаправити на нову. Історія покупок залишиться.")
        }
        // Board #170. **An `.alert`, not a `.confirmationDialog`, and the
        // screenshot is why.** The dialog rendered as a POPOVER — iOS drops the
        // cancel button in that presentation, so the only thing on screen was
        // «Видалити», in red, over a four-line message that pushed it to the
        // edge of the display. One visible answer, and it destroys something
        // that cannot be brought back.
        //
        // An alert cannot become a popover. Two buttons lay out side by side
        // with the safe one on the left, which is the shape board #168 settled
        // on for «Скинути додаток» — the app's other irreversible action, so
        // the two now agree.
        //
        // **One destructive answer.** The second is offered only after a failed
        // request, and only then: board #158's shape.
        .alert("Видалити адресу назавжди?", isPresented: $deletingAddress) {
            Button("Видалити", role: .destructive) { deleteAddress(force: false) }
                .accessibilityIdentifier("bank.email.deleteAddress.confirm")
            Button("Скасувати", role: .cancel) {}
        } message: {
            // Two sentences, because an alert body longer than that is not
            // read: the part that cannot be undone, and the fear this alert
            // raises whose answer is no. The forwarding rule and the switched
            // -off import are already on the button's own caption, said before
            // the tap that opened this.
            Text("Повернути саме цю адресу вже не можна — нова буде інша. Історія покупок залишиться на телефоні.")
        }
    }

    /// Board #157. The cost, before the tap — not reported after it.
    ///
    /// `String(format:)` around a LITERAL key, never interpolation into one:
    /// an interpolated key is a key no catalogue can contain, so the string
    /// would silently ship untranslated. `deletionCostMessage` says the same
    /// thing about the statement version, for the same reason.
    private var disconnectCostMessage: String {
        let language = store.settings.languageChoice
        let cost = store.bankDisconnectCost(bankId: bankId)

        // What the bank leaves behind on this phone, which differs by bank: a
        // statement-only bank never had a token, so promising to delete one
        // would name something that was never stored.
        let keeps: String
        if bank?.status == .available {
            keeps = L10n.t("Токен буде видалено з пристрою.", language)
        } else if bank?.hasEmailSource == true, store.privatEmailCredentials != nil {
            // Board #158. This used to read «Адреса для листів перестане
            // працювати», and it was true then — the button deleted the
            // account. It says the opposite now on purpose: somebody who read
            // the old sentence has to be TOLD the rule changed, not left to
            // infer it from its absence.
            keeps = L10n.t("Адреса для листів залишиться — її можна змінити лише окремо.", language)
        } else {
            keeps = ""
        }

        if cost.rows == 0 {
            let none = L10n.t("Операцій від цього банку немає.", language)
            return keeps.isEmpty ? none : none + " " + keeps
        }
        // `Plural.operations`, never "%lld операцій": Ukrainian takes three
        // forms and 2–4 is «операції». A screenshot is what caught «3
        // операцій» in the statement dialog — no assertion in this repo
        // would have.
        let counted = Plural.operations(cost.rows, language)
        let body: String
        if cost.decided > 0 {
            body = String(format: L10n.t("Можна прибрати %@, з них %lld ви вже розібрали — або залишити всі.", language),
                          counted, cost.decided)
        } else {
            body = String(format: L10n.t("Можна прибрати %@ — або залишити всі.", language), counted)
        }
        return keeps.isEmpty ? body : body + " " + keeps
    }

    /// Board #166. Same count, same `Plural.operations`, said for a bank that
    /// is already off — so no «Токен буде видалено» half, because there is no
    /// disconnect left to perform and nothing else to take away.
    private var removeRowsCostMessage: String {
        let language = store.settings.languageChoice
        let cost = store.bankDisconnectCost(bankId: bankId)
        let counted = Plural.operations(cost.rows, language)
        guard cost.decided > 0 else {
            return String(format: L10n.t("Зникнуть %@.", language), counted)
        }
        // The number the person actually cares about — a row they categorized,
        // split or skipped carries work no re-import gives back. Board #157's
        // argument, and the string it already wrote.
        return String(format: L10n.t("Зникнуть %@, з них %lld ви вже розібрали.", language),
                      counted, cost.decided)
    }

    private func disconnectBank(removingTransactions: Bool) {
        // Rows first, then the bank: `disconnect` persists, so doing it in
        // this order means one write rather than two, and no window in which
        // the file on disk holds a disconnected bank that still owns rows.
        if removingTransactions {
            store.removeTransactions(ofBank: bankId)
        }
        store.disconnect(bankId: bankId)
        // Land back on the banks list, not wherever the stack happened to be —
        // this is the "logical home" for both disconnect and reconnect.
        path = [.settings, .banks]
    }


    /// Board #145 — PrivatBank emailed a link, and this is where the person
    /// meets it — and board #171, which lets them say «yes, fetch it».
    ///
    /// The owner: «the statement should be downloaded automatically, and not
    /// the user to download it and paste it somewhere. In the application,
    /// just ask whether to download it to the application or not.» **That last
    /// sentence is the design**: the ask stays, and this card is where it is
    /// asked. Nothing is fetched on arrival and nothing sweeps in the
    /// background; a tap is the only thing that follows a link.
    ///
    /// #171 re-measured #145's three reasons and two were already solved by
    /// #145 itself — Amazon's wrapper is unwrapped at parse time, «Контакти»
    /// is excluded by anchor text before anything is stored. The third was
    /// real: the stored URL is a redirector, and the backend now walks the
    /// chain by hand, checking every hop against `privatbank.ua`.
    ///
    /// **«Відкрити посилання» stays, and stays reachable.** A link the server
    /// cannot follow — expired, or answering something that is not a
    /// spreadsheet — is still worth opening by hand, because the person may
    /// have a Privat24 session the server does not. Removing the manual path
    /// in favour of the automatic one would take the fallback away exactly
    /// when it is needed.
    ///
    /// The HOST is shown, not the whole URL. The backend has already unwrapped
    /// Amazon's click tracker and checked the destination is PrivatBank's own,
    /// but a person cannot judge a 200-character tracking URL — the host is
    /// the part that answers "where is this taking me?".
    private func statementLinkCard(_ link: PrivatEmailStatementLink) -> some View {
        Card {
            Text("Виписка чекає на сайті банку")
                .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            Text("ПриватБанк надіслав не файл, а посилання. Можна завантажити виписку сюди — або відкрити посилання й зробити це самому.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            // Board #187. The host is `privatbank.ua` for EVERY link, so with
            // two waiting it said nothing about which was which. The arrival
            // time is the only thing that differs — a link carries no filename
            // and no period until it is followed, which is the download itself.
            Text(verbatim: "\(link.host) · \(PrivatEmailSetupView.stamp.string(from: link.receivedAt))")
                .font(Theme.font(14, .medium)).foregroundStyle(Theme.inkMuted)
                .textSelection(.enabled)
                .accessibilityIdentifier("bank.statementLink.host.\(link.id)")
            // The offer, and the primary action: this is the thing the owner
            // asked for, so it is the filled button and the manual route below
            // is the plain one.
            Button { download(link) } label: {
                HStack(spacing: 10) {
                    if downloadingLink == link.id { ProgressView().controlSize(.small) }
                    Text("Завантажити в додаток")
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.greenWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(downloadingLink != nil)
            // Keyed by id, for the same reason the statement buttons now are:
            // every link's button carried one identifier, so two waiting links
            // were one reachable element and this bug was untestable.
            .accessibilityIdentifier("bank.statementLink.download.\(link.id)")
            if let linkError {
                Text(linkError).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                    .accessibilityIdentifier("bank.statementLink.error")
                // Said only when the automatic path has actually failed,
                // because until then it is an instruction nobody needs.
                Text("Спробуйте відкрити посилання — можливо, воно відкриється у вашому браузері.")
                    .font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
            }
            if let url = URL(string: link.url) {
                Link(destination: url) {
                    Text("Відкрити посилання")
                        .font(Theme.font(15, .semibold)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("bank.statementLink.open")
            }
            Button {
                Task {
                    await store.forgetStatementLink(link)
                    statementLinks.removeAll { $0.id == link.id }
                }
            } label: {
                Text("Приховати")
                    .font(Theme.font(15, .semibold)).foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(downloadingLink != nil)
            .accessibilityIdentifier("bank.statementLink.dismiss")
        }
        // NO identifier on the Card itself. A container's
        // `accessibilityIdentifier` is pushed DOWN onto its leaves, so one
        // here would rename every child and `bank.statementLink.host` would
        // never be found — which is exactly what happened, and a screenshot
        // showing the card on screen while the query timed out is how it was
        // caught.
    }

    /// Board #171. Fetch and import, and say which half failed.
    ///
    /// The link is dropped from the card only on success. A failed download
    /// leaves it exactly where it was, because «Відкрити посилання» right
    /// underneath is the fallback — and a card that vanished after failing
    /// would take the fallback with it.
    private func download(_ link: PrivatEmailStatementLink) {
        downloadingLink = link.id
        linkError = nil
        Task {
            defer { downloadingLink = nil }
            do {
                _ = try await store.downloadStatementLink(link)
                statementLinks.removeAll { $0.id == link.id }
            } catch let error as PrivatEmailError {
                // The backend answers 422 when it refused to make the request
                // or what came back was not a spreadsheet — an expired link,
                // most often. `message(for:)` already renders every case.
                linkError = PrivatEmailSetupView.message(for: error)
            } catch {
                // A parse failure, not a network one: the file arrived and
                // `PrivatStatementParser` could not read it. Saying «не
                // вдалося завантажити» here would send somebody to check their
                // connection about a file that is already on the phone.
                linkError = "Файл завантажився, але прочитати його не вдалося."
            }
        }
    }

    private func changeAddress(force: Bool) {
        Task {
            switch await store.changePrivatEmailAddress(force: force) {
            case .disconnected:
                emailError = nil
                // Straight to setup: an address that has just been destroyed
                // with nothing offered in its place is the state this card
                // exists to prevent.
                path.append(.emailSetup)
            case .failed(let reason):
                emailRetry = .change
                emailError = PrivatEmailSetupView.message(for: reason)
            }
        }
    }

    /// Board #170. The same destruction as `changeAddress`, and deliberately
    /// **not** followed by the same navigation: this person asked for no
    /// address, so sending them to the setup screen would answer a different
    /// question than the one they were asked. Staying here leaves the mail card
    /// in its «Не підключено» branch, which is now the truth.
    private func deleteAddress(force: Bool) {
        Task {
            switch await store.deletePrivatEmailAddress(force: force) {
            case .disconnected:
                emailError = nil
            case .failed(let reason):
                emailRetry = .delete
                emailError = PrivatEmailSetupView.message(for: reason)
            }
        }
    }
}
