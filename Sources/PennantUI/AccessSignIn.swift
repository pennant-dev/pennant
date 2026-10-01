import AuthenticationServices
import PennantCore
import SwiftUI

/// Signing in to a host behind Cloudflare Access: the host's handoff page sits behind Access, so opening it asks
/// for the identity provider (Entra ID, Google…); once through, the host sends the Access token back to the app.
public enum AccessSignIn {
    /// Empty: everyone types their own host.
    public static let suggestedHost = ""

    public struct Result: Sendable { public var token: String }

    public enum Failure: Error, CustomStringConvertible {
        case noToken, badHost
        public var description: String {
            switch self {
            case .noToken: return "The sign-in didn't come back with access. Try again."
            case .badHost: return "That doesn't look like a host name. Type it like pennant.example.com."
            }
        }
    }

    @MainActor
    public static func run(host: String, auth: WebAuthenticationSession) async throws -> Result {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents()
        components.scheme = "https"
        components.host = cleaned
        components.path = "/access/handoff"
        components.queryItems = [URLQueryItem(name: "return", value: "pennant://access")]
        guard !cleaned.isEmpty, let url = components.url else { throw Failure.badHost }
        let callback = try await auth.authenticate(using: url, callbackURLScheme: "pennant", preferredBrowserSession: .shared)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else { throw Failure.noToken }
        return Result(token: token)
    }
}
