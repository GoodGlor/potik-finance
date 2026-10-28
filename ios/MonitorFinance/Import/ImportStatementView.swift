import SwiftUI
import UniformTypeIdentifiers

/// «Імпорт виписки» — the statement-bank's counterpart of TokenView: an
/// explanation card, one big button, inline errors, never alerts.
struct ImportStatementView: View {
    @Environment(AppStore.self) private var store
    var onImported: (ImportSummary) -> Void
    @State private var error: LocalizedStringKey?
    @State private var pickingFile = false

    private static let xlsx = UTType(filenameExtension: "xlsx") ?? .data

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("Виписка ПриватБанку").font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                        step(1, "У Приват24 відкрийте картку → «Виписка».")
                        step(2, "Виберіть період і збережіть файл Excel (.xlsx).")
                        step(3, "Поверніться сюди й виберіть цей файл.")
                        if let error {
                            Text(error).font(Theme.font(14, .medium)).foregroundStyle(Theme.clay)
                                .accessibilityIdentifier("import.error")
                        }
                        Text("Файл читається лише на цьому пристрої й нікуди не надсилається.")
                            .font(Theme.font(15)).foregroundStyle(Theme.inkSoft)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }

            PrimaryButton(title: "Вибрати файл") { choose() }
                .accessibilityIdentifier("import.choose")
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationTitle("ПриватБанк")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [Self.xlsx]) { result in
            handle(result)
        }
    }

    private func choose() {
        error = nil
#if DEBUG
        if Launch.stubPrivatStatement {
            // An invented name, per the project's fixture rule — and a
            // recognisable one, so a UI test asserting the board #148 list
            // is asserting against something it chose rather than a blank.
            importData(PrivatStatementStub.sampleData, filename: "виписка-приклад.xlsx")
            return
        }
#endif
        pickingFile = true
    }

    private func handle(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            // A plain Cancel in the Files sheet can be delivered here as
            // `CocoaError.userCancelled` on this OS — changing your mind is
            // not a failure, so it must not paint an error on the card.
            if (err as? CocoaError)?.code != .userCancelled {
                error = LocalizedStringKey(PrivatImportError.cantReadFile.userMessage)
            }
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                error = LocalizedStringKey(PrivatImportError.cantReadFile.userMessage)
                return
            }
            // Board #148: the picked file's own name, which is what the
            // person will recognise in the list. Taken here because it is the
            // only place that ever sees the URL.
            importData(data, filename: url.lastPathComponent)
        }
    }

    private func importData(_ data: Data, filename: String) {
        do {
            error = nil
            onImported(try store.importPrivatStatement(data, filename: filename))
        } catch let known as PrivatImportError {
            error = LocalizedStringKey(known.userMessage)
        } catch {
            self.error = LocalizedStringKey(PrivatImportError.cantReadFile.userMessage)
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
