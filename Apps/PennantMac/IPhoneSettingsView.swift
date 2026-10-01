import AppKit
import CoreImage.CIFilterBuiltins
import PennantClientKit
import PennantCore
import PennantUI
import SwiftUI

/// Settings › iPhone: the connect code a phone scans to find this host anywhere (its Tailscale name, its local
/// address and its certificate), and the addresses themselves.
struct IPhoneSettingsView: View {
    @Environment(\.hostSession) private var session
    @State private var copied = false

    private var info: HostInfo? { session.state.host }
    private var addresses: [String] { info?.addresses ?? [] }

    /// The code's host is the best address (the Tailscale name when there is one); the rest go along as alternates.
    private var code: HostEndpoint? {
        guard let info, let first = addresses.first else { return nil }
        var e = HostEndpoint(host: first, port: session.endpoint.port, name: info.hostName, tlsPort: info.tlsPort, fingerprint: info.tlsFingerprint)
        e.alternates = Array(addresses.dropFirst())
        return e
    }

    var body: some View {
        SettingsPage {
            SettingsCard("Connect your iPhone") {
                if let code, let url = code.connectURL {
                    HStack(alignment: .top, spacing: 20) {
                        if let image = Self.qrImage(url.absoluteString) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .padding(10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityLabel("Connect code for \(code.name)")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scan this with the iPhone's Camera app, or in Pennant on the phone: Scan the Mac's code.")
                                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                            Text("It has this Mac's addresses and its certificate, so the phone connects securely at home and, with Tailscale on, anywhere.")
                                .font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary)
                            Button(copied ? "Copied" : "Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                copied = true
                            }
                            .buttonStyle(.pennantCompact)
                        }
                    }
                } else if info != nil {
                    SettingsNote("The host only listens on this Mac. Turn on \"Accept connections from the network\" in Host settings › API.")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if !addresses.isEmpty {
                SettingsCard("Addresses") {
                    ForEach(addresses, id: \.self) { address in
                        HStack(spacing: 8) {
                            Text(Self.kind(address)).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).frame(width: 110, alignment: .leading)
                            Text(address).font(.zoomed(.callout).monospaced()).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                    if !addresses.contains(where: { Self.kind($0) == "Tailscale" }) {
                        SettingsNote("Tailscale isn't running on this Mac, so a phone can only find it on this network.", tone: SettingsTone.warning)
                    }
                    SettingsNote("A phone that connected once learns all of these and tries them in turn.")
                }
            }
        }
    }

    static func kind(_ address: String) -> String {
        if address.hasSuffix(".ts.net") || address.hasPrefix("100.") || address.lowercased().hasPrefix("fd7a:115c:a1e0") { return "Tailscale" }
        return "Local network"
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
