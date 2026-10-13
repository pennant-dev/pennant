import Foundation
import PennantPluginSDK

/// Who Azure is asked for: Azure Resource Manager, or Log Analytics.
public enum AzureAudience: String, Sendable, CaseIterable {
    case management = "https://management.azure.com"
    case logs = "https://api.loganalytics.io"

    /// The credential helper the owner approves for it.
    public var helper: String { self == .management ? "azure-management" : "azure-logs" }
}

/// Bearer tokens for Azure, the way the owner chose: a credential helper Pennant runs (their `az` sign-in), or a
/// service principal from the Vault. Tokens are kept until a few minutes before they expire.
public actor AzureAuth {
    public static let servicePrincipalSlot = "azure-service-principal"

    public enum Mode: String, Sendable { case helper, servicePrincipal }

    private let context: PluginContext
    private let http: AzureHTTP
    private var cache: [AzureAudience: (token: String, until: Date)] = [:]

    public init(context: PluginContext, http: AzureHTTP) {
        self.context = context
        self.http = http
    }

    /// The setting if there is one; otherwise the helper when it's granted, then the service principal.
    public func mode() -> Mode? {
        if let chosen = context.settings["auth"]?.string.flatMap(Mode.init(rawValue:)) { return chosen }
        if context.isGranted("credential:\(AzureAudience.management.helper)") { return .helper }
        if context.isGranted("secret:\(Self.servicePrincipalSlot)") { return .servicePrincipal }
        return nil
    }

    public func token(_ audience: AzureAudience) async throws -> String {
        if let cached = cache[audience], cached.until > Date() { return cached.token }
        let fresh: (String, Date)
        switch mode() {
        case .helper?: fresh = try await fromHelper(audience)
        case .servicePrincipal?: fresh = try await fromServicePrincipal(audience)
        case nil:
            throw AzureError.notSignedIn("Grant the Azure plugin a sign-in: the \(audience.helper) credential helper (your az sign-in), or the \(Self.servicePrincipalSlot) secret.")
        }
        cache[audience] = (fresh.0, fresh.1.addingTimeInterval(-300))
        return fresh.0
    }

    /// What `az account get-access-token -o json` prints, or a bare token.
    private func fromHelper(_ audience: AzureAudience) async throws -> (String, Date) {
        let output = try await context.credential(audience.helper).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw AzureError.notSignedIn("The \(audience.helper) helper printed nothing. Is `az login` done?") }
        if let data = output.data(using: .utf8), let json = try? JSONDecoder().decode(PluginValue.self, from: data), let token = json["accessToken"]?.string {
            let until = json["expires_on"]?.number.map { Date(timeIntervalSince1970: $0) }
                ?? json["expiresOn"]?.string.flatMap(Self.parseLocalDate) ?? Date().addingTimeInterval(1800)
            return (token, until)
        }
        return (output, Date().addingTimeInterval(1800))
    }

    /// `expiresOn` is local time without a zone: "2026-10-06 14:31:07.000000".
    static func parseLocalDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// Client credentials: the slot's username is the client id, its password (or secret) the client secret; the
    /// tenant is a setting.
    private func fromServicePrincipal(_ audience: AzureAudience) async throws -> (String, Date) {
        let entry = try await context.secret(Self.servicePrincipalSlot)
        guard let clientID = entry["username"], let secret = entry["password"] ?? entry["secret"] else {
            throw AzureError.notSignedIn("The \(Self.servicePrincipalSlot) vault item needs the client id as its username and the client secret as its password.")
        }
        guard let tenant = context.settings["tenant"]?.string, !tenant.isEmpty else {
            throw AzureError.notSignedIn("Set the Azure plugin's tenant (its directory id) to sign in as a service principal.")
        }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": clientID, "client_secret": secret, "grant_type": "client_credentials", "scope": "\(audience.rawValue)/.default"]
        request.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.sorted().joined(separator: "&").utf8)
        let (data, response) = try await http.send(request)
        let json = (try? JSONDecoder().decode(PluginValue.self, from: data)) ?? .null
        guard (200 ..< 300).contains(response.statusCode), let token = json["access_token"]?.string else {
            throw AzureError.notSignedIn("Azure refused the service principal: \(json["error_description"]?.string ?? "HTTP \(response.statusCode)")")
        }
        return (token, Date().addingTimeInterval(json["expires_in"]?.number ?? 3600))
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public enum AzureError: Error, CustomStringConvertible {
    case notSignedIn(String)
    case azure(status: Int, code: String, message: String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notSignedIn(let why): return why
        case .azure(let status, let code, let message): return "Azure said \(code.isEmpty ? "HTTP \(status)" : code): \(message)"
        case .invalid(let why): return why
        }
    }
}

/// Sends requests; tests replace it.
public protocol AzureHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTP: AzureHTTP {
    /// No caches or cookies on disk: a plugin keeps nothing it wasn't asked to.
    private let session = URLSession(configuration: .ephemeral)
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AzureError.invalid("No HTTP response") }
        return (data, http)
    }
}
