import SwiftUI
import AVFoundation
import VisionKit

/// Looks beers up by barcode, the way the official app does on a scan.
enum BarcodeLookup {
    /// The forms of `code` to ask Untappd for, in order. Untappd keeps UPC-As as their 12
    /// digits, and a scanner reads them as an EAN-13 with a leading 0, so a 13-digit code
    /// starting with 0 is also asked without it (and a 12-digit one also with it).
    static func candidates(_ code: String) -> [String] {
        let digits = code.filter(\.isWholeNumber)
        guard !digits.isEmpty else { return [] }
        if digits.count == 12 { return ["0" + digits, digits] }
        if digits.count == 13, digits.hasPrefix("0") { return [digits, String(digits.dropFirst())] }
        return [digits]
    }

    /// The beers with barcode `code`, most trusted first; empty if Untappd knows none.
    static func beers(for code: String) async throws -> [BeerLite] {
        for upc in candidates(code) {
            let found = try await UntappdAPI.shared.fetch(.checkBarcode(upc), as: BarcodeMatches.self).beers
            if !found.isEmpty { return found }
        }
        return []
    }
}

/// A sheet that scans (or takes a typed) barcode and lists the beers it belongs to.
struct BarcodeSearchSheet: View {
    /// Called with the beer the user picks; the sheet dismisses itself first.
    var onPick: (BeerLite) -> Void

    private enum Phase: Equatable {
        case scanning
        case looking(String)
        case found(String, [BeerLite])
        case failed(String, String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.scanning
    @State private var typed = ""
    @State private var cameraAllowed: Bool?
    @FocusState private var typing: Bool

    private var canScan: Bool {
        DataScannerViewController.isSupported && cameraAllowed == true
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Find by barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .task { await askForCamera() }
        .sensoryFeedback(.success, trigger: phase) { _, new in
            if case .looking = new { return true } else { return false }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .scanning:
            VStack(spacing: 0) {
                scanner
                manualEntry
            }
        case .looking(let code):
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking up \(code)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .found(let code, let beers):
            results(code: code, beers: beers)
        case .failed(let code, let message):
            ContentUnavailableView {
                Label("Couldn't look up \(code)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { lookUp(code) }.buttonStyle(.borderedProminent)
                Button("Scan another") { phase = .scanning }
            }
        }
    }

    @ViewBuilder private var scanner: some View {
        if canScan {
            BarcodeScanner { code in
                if case .scanning = phase, !typing { lookUp(code) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 260, height: 140)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Text("Point the camera at the barcode on the can or bottle")
                    .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
            .ignoresSafeArea(edges: .horizontal)
        } else if cameraAllowed == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Can't scan here", systemImage: "barcode.viewfinder")
            } description: {
                Text(cameraAllowed == false
                     ? "Camera access is off. Turn it on in Settings to scan barcodes, or type one below."
                     : "This device can't scan barcodes. Type one below instead.")
            }
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("Or type the barcode", text: $typed)
                .keyboardType(.numberPad)
                .focused($typing)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Button("Search") { lookUp(typed) }
                .buttonStyle(.borderedProminent)
                .disabled(BarcodeLookup.candidates(typed).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func results(code: String, beers: [BeerLite]) -> some View {
        List {
            if beers.isEmpty {
                ContentUnavailableView("No beers found",
                                       systemImage: "barcode",
                                       description: Text("Nobody on Untappd has given \(code) to a beer yet."))
            } else {
                Section {
                    ForEach(beers) { b in
                        Button {
                            dismiss()
                            onPick(b)
                        } label: { BeerRow(beer: b) }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(beers.count == 1 ? "Barcode \(code)" : "\(beers.count) beers have barcode \(code)")
                }
            }
            Section {
                Button("Scan another", systemImage: "barcode.viewfinder") { typed = ""; phase = .scanning }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func lookUp(_ raw: String) {
        let code = raw.filter(\.isWholeNumber)
        guard !code.isEmpty else { return }
        typing = false
        phase = .looking(code)
        Task {
            do {
                let beers = try await BarcodeLookup.beers(for: code)
                phase = .found(code, beers)
            } catch {
                phase = .failed(code, error.localizedDescription)
            }
        }
    }

    private func askForCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAllowed = true
        case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        default: cameraAllowed = false
        }
    }
}

/// VisionKit's live barcode scanner. Calls `onCode` with each new barcode it reads.
private struct BarcodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let code = b.payloadStringValue, !code.isEmpty {
                    onCode(code)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let b) = item, let code = b.payloadStringValue { onCode(code) }
        }
    }
}
