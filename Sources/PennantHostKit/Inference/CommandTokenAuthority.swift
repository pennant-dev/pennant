import PennantCore
import Foundation

/// Bearer tokens from a shell command, for endpoints that take short-lived tokens instead of a fixed key: Azure AI
/// Foundry with Microsoft Entra ID (`az account get-access-token …`), Google Vertex (`gcloud auth print-access-token`),
/// or a company's own helper. The token is cached for a while (or until its `exp` when it is a JWT) and fetched
/// again when the endpoint answers 401 or 403 with an expired or invalid token.
public actor CommandTokenAuthority: EndpointAuthority {
    let command: String
    let baseURL: String
    private var cached: (token: String, until: Date)?

    public init(command: String, baseURL: String) {
        self.command = command
        self.baseURL = baseURL
    }

    public func credential() async throws -> EndpointCredential {
        if let cached, cached.until > Date() { return EndpointCredential(bearer: cached.token, baseURL: baseURL) }
        return try await fetch()
    }

    public func refreshCredential(rejected: EndpointCredential) async throws -> EndpointCredential {
        cached = nil
        return try await fetch()
    }

    public nonisolated func shouldRetry(status: Int, body: String, attempt: Int) -> Bool {
        attempt == 0 && (status == 401 || (status == 403 && body.lowercased().contains("token")))
    }

    private func fetch() async throws -> EndpointCredential {
        let result: BrowserRunner.ProcessResult
        do {
            result = try await BrowserRunner.run(executable: "/bin/zsh", arguments: ["-lc", command], cwd: FileManager.default.homeDirectoryForCurrentUser, stdin: nil, timeout: 60)
        } catch {
            throw InferenceError.unreachable("The key command did not finish: \(error)")
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
        guard result.status == 0, !token.isEmpty, !token.contains(" ") else {
            throw InferenceError.unreachable("The key command failed (exit \(result.status)): \(result.stderr.suffix(300))")
        }
        cached = (token, Self.expiry(of: token) ?? Date().addingTimeInterval(45 * 60))
        return EndpointCredential(bearer: token, baseURL: baseURL)
    }

    /// Five minutes before a JWT's `exp`, when the token is one.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp - 300)
    }
}
