import SwiftUI

struct DataSettingsView: View {
    @Binding var path: [SettingsRoute]
    @Environment(AppStore.self) private var store
    @State private var exportURL: URL?
    @State private var exportFailed = false
#if DEBUG
    @State private var logURL: URL?
    @State private var productLogURL: URL?
#endif
    @State private var askingReset = false
    @State private var confirmingReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !store.loadFailures.isEmpty { loadFailureCard }
                Card {
                    // The one route to `SyncDepthView` after onboarding. Same
                    // row shape as `SettingsView.row`, `.contentShape` and
                    // all: without it a tap landing in the Spacer's gap —
                    // which is the middle of the row — never reaches the
                    // button.
                    Button { path.append(.syncDepth) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 20)).foregroundStyle(Theme.green).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Глибина історії")
                                    .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                                Text("Скільки місяців завантажувати з monobank")
                                    .font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.data.depth")
                }
                Card {
                    Text("Експорт").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    Text("Усі операції, категорії та правила одним файлом. Банківські токени й код входу не експортуються — вони не зберігаються у файлах.")
                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    Button("Підготувати файл") { prepareExport() }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.greenWash,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("settings.data.export")
                    if let exportURL {
                        ShareLink(item: exportURL) { Text("Поділитися файлом") }
                            .accessibilityIdentifier("settings.data.share")
                    }
                }
#if DEBUG
                categorizationLogCard
#endif
                Card {
                    Text("Скинути додаток").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    // No «початковий набір» any more: `seed.json` stopped
                    // shipping, so a Release build has nothing to reload, and
                    // `resetEverything` clears the token as well. After this
                    // the app is genuinely empty until the user onboards again.
                    // Board #168 added the second sentence. The copy listed
                    // four things it destroyed and stayed silent about the one
                    // the owner could not get back — so «Видалити все» read as
                    // a complete list and was not one.
                    Text("Видалить код входу, токен monobank, підключені банки й усі ваші рішення. Історію доведеться завантажити заново — після скидання додаток порожній, доки ви не підключите банк ще раз. Адреса для листів залишиться — підключіть пошту знову, і вона буде та сама.")
                        .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    Button("Скинути…") { askingReset = true }
                        .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .accessibilityIdentifier("settings.data.reset")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Дані")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.data")
        // Two gates, not one: the spec asks for a double confirm because this
        // is the only irreversible action in the app.
        .confirmationDialog("Скинути додаток?", isPresented: $askingReset,
                            titleVisibility: .visible) {
            Button("Продовжити", role: .destructive) { confirmingReset = true }
                .accessibilityIdentifier("settings.data.resetContinue")
            Button("Скасувати", role: .cancel) {}
        }
        // Board #168. **One destructive answer, and the address is not part of
        // it.** A second «Видалити все і адресу» button was written here first
        // and removed after looking at it: two red buttons differing by two
        // words, stacked adjacently, with a message directly above them saying
        // «Адреса для листів залишиться» — true of one of them and the exact
        // opposite of the other. On the app's only irreversible action, and on
        // precisely the loss this card exists to repair.
        //
        // Deleting the mailbox on purpose belongs on the mail screen beside
        // «Змінити адресу», where it is a considered act rather than a
        // mis-tap. **Board #170 built it there** — «Видалити адресу назавжди»,
        // calling `deletePrivatEmailAddress`. It does not touch the
        // transactions and this does not touch the address; somebody emptying
        // a phone they are giving away does both, deliberately, in the two
        // places that own them.
        //
        // `resetEverything` lost its `keepingMailbox` parameter with that card:
        // it existed only for the second button removed here, and a tested but
        // uncalled destructive path reads as an endorsed one.
        .alert("Це не можна скасувати", isPresented: $confirmingReset) {
            Button("Видалити все", role: .destructive) { reset() }
                .accessibilityIdentifier("settings.data.resetConfirm")
            Button("Залишити", role: .cancel) {}
        } message: {
            Text("Адреса для листів залишиться — підключіть пошту знову, і вона буде та сама.")
        }
        // Board #158's «Не вдалося видалити адресу» alert stood here. It
        // existed because the reset deleted the server account and that request
        // could fail; board #168 removed the request, so there is nothing left
        // for it to catch. Deleted rather than left unreachable — an alert
        // nothing can present is a claim the screen makes and cannot keep.
        //
        // Its reasoning is not lost: it moves to whichever screen ends up
        // offering a deliberate «видалити адресу», which will need exactly the
        // same shape.
        .alert("Не вдалося підготувати файл", isPresented: $exportFailed) {
            Button("Гаразд", role: .cancel) {}
        }
    }

    /// Board #158 put a server delete first, because after `resetEverything`
    /// there was no secret left to delete the account with. **Board #168
    /// removed the call entirely.**
    ///
    /// The reset now touches the network not at all. Three things follow, and
    /// the third is the one worth keeping in mind before anybody adds a request
    /// back: there is nothing to fail, so the «Не вдалося видалити адресу»
    /// alert and its «Видалити лише з телефона» escape are gone with it; a
    /// person with no signal can always empty their phone; and the reset is now
    /// synchronous in everything that matters, so it cannot half-happen.
    private func reset() {
        store.resetEverything()
    }

    /// Board #68. Shown only when this launch actually failed to read
    /// something, and first on the screen because it outranks an export.
    ///
    /// **What it can honestly offer.** Nothing the person taps fixes this —
    /// recovery needs a build that can read those bytes, and this one cannot.
    /// So the card's job is to say what happened, say that the file was NOT
    /// overwritten, and name the one action that would destroy it: «Скинути
    /// додаток» removes the whole directory, quarantined copies included.
    /// Offering a reassuring button here would be worse than offering none.
    private var loadFailureCard: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.clay)
                Text("Не вдалося прочитати частину даних")
                    .font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
            }
            Text("Під час запуску додаток не зміг прочитати: \(failedTitles). Замість них показано початкові дані.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            Text("Ці файли збережено на пристрої — їх не перезаписано, тож дані ще можна відновити. Не скидайте додаток: скидання видалить і їх.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
        }
        .accessibilityIdentifier("settings.data.loadFailures")
    }

    /// «операції, чеки» — the app's words, not the storage keys.
    private var failedTitles: String {
        store.loadFailures.map(AppStore.fileTitle).joined(separator: ", ")
    }

#if DEBUG
    /// Debug builds only — the whole card, not merely the switch. A Release
    /// build has no `CategorizationLog` type to talk to, which is the point:
    /// the app promises the data never leaves the phone, and a promise kept
    /// by a flag is weaker than one kept by the compiler.
    @ViewBuilder private var categorizationLogCard: some View {
        @Bindable var log = store.categorizationLog
        Card {
            Text("Збір даних категоризації").font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.ink)
            // Says exactly what would leave the device. A vaguer sentence
            // would make this switch impossible to consent to.
            Text("Тільки для тестування. Якщо увімкнути, у файл на цьому пристрої записуються два види рішень. Перший — «цей продавець → ця категорія»: назва продавця, код категорії банку (MCC), банк, підказка Привату, ваша відповідь і час. Другий — товари з чеків: назва товару, що вгадав додаток, що обрали ви, і магазин. Сума НЕ записується — лише знак «+» чи «−». Якщо вказати адресу Apps Script, ці ж рядки надсилаються туди.")
                .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
            Toggle("Записувати рішення", isOn: $log.isEnabled)
                .font(Theme.font(16, .medium)).foregroundStyle(Theme.ink)
                .tint(Theme.green)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.data.log.toggle")
            if log.isEnabled {
                // No example URL: naming a host in app source, even as a hint,
                // trips the guard that keeps this app talking to exactly
                // one server. The tester pastes their own.
                TextField("Адреса Apps Script", text: $log.webhook)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.font(15))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings.data.log.webhook")
                Text(logStatus).font(Theme.font(14)).foregroundStyle(Theme.inkMuted)
                    .accessibilityIdentifier("settings.data.log.status")
                Button("Підготувати JSONL — покупки") { prepareLogExport() }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.greenWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("settings.data.log.export")
                if let logURL {
                    ShareLink(item: logURL) { Text("Поділитися покупками") }
                        .accessibilityIdentifier("settings.data.log.share")
                }
                // Two files, two buttons. They are different data — що куплено
                // vs куди пішли гроші — and merging them into one export would
                // undo the separation the rest of this feature maintains.
                Button("Підготувати JSONL — товари") { prepareProductLogExport() }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.greenWash,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("settings.data.log.exportProducts")
                if let productLogURL {
                    ShareLink(item: productLogURL) { Text("Поділитися товарами") }
                        .accessibilityIdentifier("settings.data.log.shareProducts")
                }
                Button("Очистити журнал") {
                    store.categorizationLog.clear()
                    logURL = nil
                    productLogURL = nil
                }
                    .font(Theme.font(16, .semibold)).foregroundStyle(Theme.clay)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("settings.data.log.clear")
            }
        }
    }

    private var logStatus: LocalizedStringKey {
        let log = store.categorizationLog
        guard log.isFull || log.productsFull else {
            return "\(log.lineCount()) покупок · \(log.productLineCount()) товарів · надіслано \(log.sent) · помилок \(log.failed)"
        }
        // Two whole keys rather than a base plus an appended clause: a
        // concatenation cannot be reordered by a translator, and half a
        // sentence is not a translatable unit.
        return "\(log.lineCount()) покупок · \(log.productLineCount()) товарів · надіслано \(log.sent) · помилок \(log.failed) · журнал заповнений, нові рішення не пишуться"
    }

    private func prepareProductLogExport() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("monitorfinance-product-groups.jsonl")
            try store.categorizationLog.productContents().write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            productLogURL = url
        } catch {
            exportFailed = true
        }
    }

    private func prepareLogExport() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("monitorfinance-categorization.jsonl")
            // The protection option the neighbouring export above is missing:
            // these lines are merchant text, and a temporary file is still a
            // file on the phone.
            try store.categorizationLog.contents().write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            logURL = url
        } catch {
            exportFailed = true
        }
    }
#endif

    private func prepareExport() {
        do {
            exportURL = try store.writeExport()
        } catch {
            // Silence here would look like a button that does nothing.
            exportFailed = true
        }
    }
}
