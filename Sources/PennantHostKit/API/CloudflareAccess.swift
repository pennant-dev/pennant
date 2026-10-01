import Foundation
import PennantCore

/// Checks Cloudflare Access tokens (the JWT Access puts in `Cf-Access-Jwt-Assertion`, and apps send as
/// `cf-access-token`): RS256 against the team's published keys, for this application's audience, unexpired. Returns
/// the verified email.
actor CloudflareAccessVerifier {
    struct Invalid: Error, CustomStringConvertible { var description: String }
    typealias KeyFetcher = @Sendable (_ url: URL) async throws -> Data

    private let fetch: KeyFetcher
    private var keys: [String: SecKey] = [:]
    private var fetchedFrom = ""
    private var fetchedAt: Date = .distantPast

    init(fetch: @escaping KeyFetcher = { url in try await URLSession.shared.data(from: url).0 }) {
        self.fetch = fetch
    }

    func verify(_ token: String?, edge: HostConfig.API.Edge, now: Date = Date()) async throws -> String {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { throw Invalid(description: "No Cloudflare Access token.") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = TeamsTokenValidator.base64URL(parts[0]), let payloadData = TeamsTokenValidator.base64URL(parts[1]),
              let signature = TeamsTokenValidator.base64URL(parts[2]),
              let head = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else { throw Invalid(description: "Malformed Access token.") }
        guard head["alg"] as? String == "RS256", let kid = head["kid"] as? String else { throw Invalid(description: "Unexpected token algorithm.") }
        guard let key = try await key(kid, teamDomain: edge.teamDomain) else { throw Invalid(description: "Unknown signing key.") }
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error) else {
            throw Invalid(description: "Bad token signature.")
        }
        let issuer = "https://\(edge.teamDomain)"
        guard (claims["iss"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuer else { throw Invalid(description: "Token from another Access team.") }
        let audiences = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audiences.contains(edge.audience) else { throw Invalid(description: "Token for another Access application.") }
        let skew: TimeInterval = 60
        if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp + skew) < now { throw Invalid(description: "Access session expired; sign in again.") }
        if let nbf = claims["nbf"] as? Double, Date(timeIntervalSince1970: nbf - skew) > now { throw Invalid(description: "Token not valid yet.") }
        guard let email = (claims["email"] as? String)?.lowercased(), email.contains("@") else { throw Invalid(description: "The token carries no email.") }
        if !edge.allowedEmailDomains.isEmpty {
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            guard edge.allowedEmailDomains.map({ $0.lowercased() }).contains(domain) else { throw Invalid(description: "\(email) isn't allowed here.") }
        }
        return email
    }

    /// The team's signing keys, cached for an hour and refreshed when an unknown key id shows up.
    private func key(_ kid: String, teamDomain: String) async throws -> SecKey? {
        let url = "https://\(teamDomain)/cdn-cgi/access/certs"
        if fetchedFrom == url, let k = keys[kid], Date().timeIntervalSince(fetchedAt) < 3600 { return k }
        guard let data = try? await fetch(URL(string: url)!), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return keys[kid] }
        var fresh: [String: SecKey] = [:]
        for jwk in (json["keys"] as? [[String: Any]]) ?? [] {
            guard jwk["kty"] as? String == "RSA", let id = jwk["kid"] as? String, let n = (jwk["n"] as? String).flatMap(TeamsTokenValidator.base64URL),
                  let e = (jwk["e"] as? String).flatMap(TeamsTokenValidator.base64URL), let k = TeamsTokenValidator.rsaKey(modulus: n, exponent: e) else { continue }
            fresh[id] = k
        }
        if !fresh.isEmpty { keys = fresh; fetchedAt = Date(); fetchedFrom = url }
        return keys[kid]
    }
}
