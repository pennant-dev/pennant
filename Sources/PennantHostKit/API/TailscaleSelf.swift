import Foundation

/// This Mac's own Tailscale name and addresses, read from the Tailscale command-line tool, so phones can be told
/// where to find the host when they're away from its network. Nil when Tailscale isn't installed or isn't running.
enum TailscaleSelf {
    struct Info: Equatable, Sendable {
        /// The MagicDNS name, e.g. studio.tail1234.ts.net (without the trailing dot).
        var dnsName: String?
        /// The tailnet addresses, IPv4 first.
        var addresses: [String]
    }

    static let toolPaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    static func read() async -> Info? {
        guard let tool = toolPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["status", "--json", "--peers=false"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); return nil }
            return parse(out.fileHandleForReading.readDataToEndOfFile())
        }.value
    }

    /// `tailscale status --json`: only while connected (BackendState "Running").
    static func parse(_ data: Data) -> Info? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["BackendState"] as? String == "Running", let me = json["Self"] as? [String: Any] else { return nil }
        let name = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        let ips = (me["TailscaleIPs"] as? [String] ?? []).sorted { !$0.contains(":") && $1.contains(":") }
        guard name?.isEmpty == false || !ips.isEmpty else { return nil }
        return Info(dnsName: name?.isEmpty == true ? nil : name, addresses: ips)
    }
}
