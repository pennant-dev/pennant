import PennantClientKit
import PennantUI
import SwiftUI
import VisionKit

/// Scans the connect code a Mac shows (Settings › iPhone): a QR code with a pennant://connect link.
struct CodeScannerSheet: View {
    var onCode: (HostEndpoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notOurs = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { text in
                        if let url = URL(string: text), let code = HostEndpoint(connectURL: url) { onCode(code) } else { notOurs = true }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text(notOurs ? "That code isn't a Pennant connect code." : "Point at the code in Pennant on your Mac: Settings › iPhone.")
                            .font(.callout)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 28)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera").font(.largeTitle).foregroundStyle(PennantTheme.inkTertiary)
                        Text("Scanning isn't available here. Open the Camera app and point it at the code instead; it opens Pennant.")
                            .font(.callout).multilineTextAlignment(.center).foregroundStyle(PennantTheme.inkSecondary)
                    }
                    .padding(32)
                }
            }
            .navigationTitle("Scan the Mac's code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var onText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: (String) -> Void
        private var handled = Set<String>()
        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue, handled.insert(text).inserted else { continue }
                onText(text)
            }
        }
    }
}
