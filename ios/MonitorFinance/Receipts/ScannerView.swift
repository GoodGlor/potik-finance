import SwiftUI
import VisionKit

/// Розібрати's one scanner (D2). A fiscal QR carries no purchase to point back
/// at — the join is sum and wall-clock minute, worked out afterwards by
/// `ReceiptMatch` — so there is nothing here for a PER-PURCHASE scan button
/// to mean, and this is the app's only scanner now.
///
/// Hands the caller a parsed `FiscalCheck`; turning that into a scanned
/// receipt (`store.scan`) and dismissing the sheet are both the caller's
/// job, not this view's own — the same division the old `onAttach` kept.
///
/// The caller MUST dismiss on `onScanned`: `handled` below latches after the
/// first check and never re-arms, so a caller that leaves this view up
/// afterward is left holding a scanner that silently ignores every further
/// tap or recognised frame — no error, no diagnostic, just a dead screen.
struct ScannerView: View {
    var onScanned: (FiscalCheck) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Every simulator reports `false` here — there is no camera to scan
    /// with — so the sample picker is the only path a UI test (or a
    /// developer without a device plugged in) can ever exercise.
    private let cameraSupported = DataScannerViewController.isSupported

    /// Hidden behind a long-press on the title on a real device (spec); the
    /// simulator has no camera at all, so there it is simply always on.
    @State private var showSampleAffordance: Bool
    /// Starts expanded when there is no camera, so a UI test that taps
    /// `scanner.sample` and then a row in the same breath always finds the
    /// row already there rather than racing a first tap that opens it.
    @State private var showSampleList: Bool
    @State private var scanError: String?
    /// A recognised QR (camera) keeps calling back on every later frame, and
    /// a tap on a sample row cannot be un-tapped mid-animation — both must
    /// still only ever hand the caller ONE check. Never reset back to
    /// `false` — see this type's own doc comment: the caller dismissing on
    /// `onScanned` is what keeps a latched-but-still-visible scanner from
    /// ever being reachable.
    @State private var handled = false

    init(onScanned: @escaping (FiscalCheck) -> Void) {
        self.onScanned = onScanned
        _showSampleAffordance = State(initialValue: !DataScannerViewController.isSupported)
        _showSampleList = State(initialValue: !DataScannerViewController.isSupported)
    }

    /// The bundled catalogue as `demo.json` ships it — three distinct check
    /// numbers, so no dedup is needed and nothing the user attaches can ever
    /// appear here as a fourth row.
    ///
    /// `-emptyReceiptSample` adds one row `store.scan` has never seen before,
    /// so it takes the fresh-shell path every real scan on a device takes;
    /// see `Launch.emptyReceiptSample`.
    private var samples: [Receipt] {
        #if DEBUG
        store.sampleReceipts + (Launch.emptyReceiptSample ? [Self.unrecognisedSample] : [])
        #else
        store.sampleReceipts
        #endif
    }

    /// A document number no bundled sample carries, so `store.scan` takes
    /// its fresh-shell branch — the branch every real scan takes on a
    /// device.
    ///
    /// `#if DEBUG` because its only reader is `Launch.emptyReceiptSample`,
    /// which is itself Debug-only. Inert in Release either way; a test
    /// fixture compiled into a shipping binary is still a test fixture in a
    /// shipping binary.
    #if DEBUG
    private static let unrecognisedSample = Receipt(
        id: UUID(), scannedAt: Date(), registerNumber: "3000000009", documentNumber: "1000000009",
        fiscalTime: ISO8601DateFormatter().date(from: "2026-08-21T12:00:00+03:00")!,
        fiscalSum: 100_00, sellerName: "Незнайома каса", items: [])
    #endif

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if cameraSupported {
                    QRScannerRepresentable { payload in handle(payload) }
                        .ignoresSafeArea()
                } else {
                    Theme.bg.ignoresSafeArea()
                    Text("Камера недоступна в симуляторі")
                        .font(Theme.font(15)).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 12) {
                    if let scanError {
                        // `Theme.scrim`, not `Theme.ink.opacity(…)`: `ink` is
                        // near-white in dark appearance, so this line was
                        // white text on a white background for anybody in dark
                        // mode. A camera feed has no appearance to follow.
                        Text(LocalizedStringKey(scanError))
                            .font(Theme.font(14)).foregroundStyle(Theme.onScrim)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if showSampleAffordance { sampleSection }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Board #102. The camera runs full-bleed under the bar, so
                    // this title had nothing behind it but the viewfinder and
                    // was drawn in `Theme.ink` — dark text over whatever the
                    // lens happened to be pointing at. White on a fixed scrim
                    // is legible against a white wall and a dark room alike;
                    // `Theme.ink` stays for the simulator's plain background,
                    // where there is an appearance to follow.
                    Text("Сканування чека")
                        .font(Theme.font(17, .semibold))
                        .foregroundStyle(cameraSupported ? Theme.onScrim : Theme.ink)
                        .padding(.horizontal, cameraSupported ? 12 : 0)
                        .padding(.vertical, cameraSupported ? 5 : 0)
                        .background {
                            if cameraSupported { Capsule().fill(Theme.scrim) }
                        }
                        // Reachable on device without a long enough finger:
                        // this is the one place the fallback lives once a
                        // real camera is present.
                        .onLongPressGesture(minimumDuration: 0.5) { showSampleAffordance = true }
                }
                ToolbarItem(placement: .cancellationAction) {
                    // The way out of this screen, over the same feed and with
                    // the same problem — a control nobody can find is worse
                    // than a title nobody can read.
                    Button("Скасувати") { dismiss() }
                        .foregroundStyle(cameraSupported ? Theme.onScrim : Theme.green)
                        .padding(.horizontal, cameraSupported ? 10 : 0)
                        .padding(.vertical, cameraSupported ? 4 : 0)
                        .background {
                            if cameraSupported { Capsule().fill(Theme.scrim) }
                        }
                        .accessibilityIdentifier("scanner.cancel")
                }
            }
            // On the `ZStack`, not the `NavigationStack` — every existing
            // screen marker in this app (`queue.title`, `detail.title`,
            // `editor.title`, ...) sits on the content inside the stack, and
            // those are the placements proven to surface by passing UI tests.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scanner.title")
        }
    }

    private var sampleSection: some View {
        VStack(spacing: 10) {
            // Opens only, never toggles: a UI test taps this and then a row
            // in the same breath, and a toggle would let that first tap
            // collapse an already-open list out from under it.
            Button("Взяти зразок чека") { withAnimation { showSampleList = true } }
                .font(Theme.font(16, .semibold)).foregroundStyle(Theme.green)
                .frame(minHeight: 44)
                .accessibilityIdentifier("scanner.sample")

            if showSampleList {
                VStack(spacing: 8) {
                    ForEach(samples) { sample in
                        Button { pick(sample) } label: { sampleRow(sample) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("scanner.sample.\(sample.documentNumber)")
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 12, y: 4)
    }

    private func sampleRow(_ sample: Receipt) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.sellerName).font(Theme.font(16, .medium)).foregroundStyle(Theme.ink)
                Text("Чек №\(sample.documentNumber)").font(Theme.font(13)).foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            Text(sample.fiscalSum.uahExact).font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// On a recognised QR: parse, and on success hand the check up; on
    /// failure say so and keep scanning — the delegate keeps calling back on
    /// every later frame.
    private func handle(_ payload: String) {
        guard !handled else { return }
        guard let check = FiscalQR.parse(payload) else {
            scanError = "Це не схоже на фіскальний чек"
            return
        }
        scanError = nil
        handled = true
        onScanned(check)
    }

    /// D10: picking a sample must not hand its `Receipt` straight over. This
    /// synthesises that sample's own tax-service lookup URL and runs it
    /// through the real `FiscalQR.parse`, so the parser is exercised end to
    /// end rather than stepped around — the ONLY scanning path a UI test can
    /// reach, the simulator having no camera.
    private func pick(_ sample: Receipt) {
        guard !handled else { return }
        guard let check = FiscalQR.parse(sampleURL(sample)) else {
            scanError = "Не вдалося зчитати зразок"
            assertionFailure("a bundled sample's own URL must parse")
            return
        }
        scanError = nil
        handled = true
        onScanned(check)
    }

    /// The URL the sample's own QR would carry. Kept beside the picker rather
    /// than in the seed: it is a test affordance, not data.
    private func sampleURL(_ r: Receipt) -> String {
        let f = DateFormatter()
        f.timeZone = .kyiv
        f.locale = Locale(identifier: "en_US_POSIX")   // never the device's calendar
        f.dateFormat = "yyyyMMdd'|'HHmmss"
        let parts = f.string(from: r.fiscalTime).split(separator: "|")
        return "https://cabinet.tax.gov.ua/cashregs/check?id=\(r.documentNumber)&fn=\(r.registerNumber)"
             + "&date=\(parts[0])&time=\(parts[1])&sm=\(String(format: "%.2f", Double(r.fiscalSum) / 100))"
    }
}

/// `DataScannerViewController` restricted to QR barcodes. Only ever
/// instantiated when `DataScannerViewController.isSupported` — every
/// simulator reports `false`, and there is no camera hardware there to hand
/// this a session with, so the type must never be constructed in that case.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    var onRecognized: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRecognized: onRecognized) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !uiViewController.isScanning else { return }
        try? uiViewController.startScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRecognized: (String) -> Void
        init(onRecognized: @escaping (String) -> Void) { self.onRecognized = onRecognized }

        func dataScanner(_ dataScanner: DataScannerViewController,
                          didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    onRecognized(payload)
                    return
                }
            }
        }
    }
}

#Preview {
    // A throwing, in-memory store — never `AppStore.live()` — so a preview
    // never touches the on-disk state a real launch persists to.
    let store = try! AppStore(repository: MemoryRepository(), seed: SeedLoader.load())
    return ScannerView { _ in }
        .environment(store)
}
