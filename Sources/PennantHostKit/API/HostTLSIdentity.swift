import PennantCore
import CryptoKit
import Foundation
import Security

/// The host's own TLS certificate, for encrypted connections on the network. Self-signed and made once (with the
/// system's `openssl`) into `<data folder>/tls/host.p12`; loaded into memory only, so it never touches the Keychain
/// and never prompts. Clients pin its SHA-256 fingerprint the first time they connect.
public struct HostTLSIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    /// SHA-256 of the certificate (DER), lowercase hex: what clients pin.
    public let fingerprint: String

    public enum Failure: Error, CustomStringConvertible {
        case generate(String), load(OSStatus)
        public var description: String {
            switch self {
            case .generate(let why): return "Couldn't make the host's TLS certificate: \(why)"
            case .load(let status): return "Couldn't load the host's TLS certificate (\(status))"
            }
        }
    }

    /// The identity in `root/tls`, made on first use.
    public static func loadOrCreate(root: URL, hostName: String) throws -> HostTLSIdentity {
        let dir = root.appendingPathComponent("tls", isDirectory: true)
        let p12 = dir.appendingPathComponent("host.p12")
        let passFile = dir.appendingPathComponent("host.pass")
        if !FileManager.default.fileExists(atPath: p12.path) || !FileManager.default.fileExists(atPath: passFile.path) {
            try generate(into: dir, p12: p12, passFile: passFile, hostName: hostName)
        }
        let pass = try String(contentsOf: passFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try load(p12: try Data(contentsOf: p12), passphrase: pass)
    }

    static func load(p12 data: Data, passphrase: String) throws -> HostTLSIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase, kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { throw Failure.load(status) }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Failure.load(errSecItemNotFound) }
        return HostTLSIdentity(identity: identity, fingerprint: Self.fingerprint(of: SecCertificateCopyData(certificate) as Data))
    }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// A P-256 key and a ten-year self-signed certificate, bundled as PKCS#12 with a random passphrase beside it.
    private static func generate(into dir: URL, p12: URL, passFile: URL, hostName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = dir.appendingPathComponent("host.key.pem"), cert = dir.appendingPathComponent("host.cert.pem")
        defer { try? fm.removeItem(at: key); try? fm.removeItem(at: cert) }
        let pass = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        // Only letters, digits and spaces reach the subject; the name is informational (clients pin the fingerprint).
        let cn = String(hostName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.prefix(48))
        // The named-curve encoding: LibreSSL otherwise writes explicit curve parameters, which Security can't import.
        try run(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-days", "3650",
                 "-subj", "/CN=Pennant \(cn.isEmpty ? "Host" : cn)", "-keyout", key.path, "-out", cert.path])
        // The passphrase goes through the environment, not the command line other processes can list.
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "env:PENNANT_P12_PASS"], env: ["PENNANT_P12_PASS": pass])
        try pass.write(to: passFile, atomically: true, encoding: .utf8)
        for f in [p12, passFile] { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    }

    private static func run(_ args: [String], env: [String: String] = [:]) throws {
        let p = Process()
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.generate("openssl isn't available (\(error))") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.generate(why.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
