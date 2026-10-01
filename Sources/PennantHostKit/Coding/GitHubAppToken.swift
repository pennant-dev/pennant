import PennantCore
import Foundation
import Security

/// Acting on GitHub as an App: signs the App's JWT with its private key, trades it for an installation token, and
/// turns that into the environment a coding session runs with, so `git` and `gh` are the App's bot and never the
/// owner. Tokens last an hour; each session run gets a fresh one.
public struct GitHubAppToken: Sendable {
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, Int)
    let http: HTTP

    public init(http: @escaping HTTP = GitHubAppToken.urlSession) { self.http = http }

    public static let urlSession: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public struct Failure: Error, CustomStringConvertible { public var description: String }

    /// The environment for a session acting as `identity`, from the App's private key (PEM).
    public func environment(for identity: GitHubAppIdentity, privateKeyPEM: String, now: Date = Date()) async throws -> [String: String] {
        let key = try Self.privateKey(pem: privateKeyPEM)
        let jwt = try Self.jwt(appID: identity.appID, key: key, now: now)
        var mint = URLRequest(url: URL(string: "https://api.github.com/app/installations/\(identity.installationID)/access_tokens")!)
        mint.httpMethod = "POST"
        mint.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        mint.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, status) = try await http(mint)
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status), let token = body["token"] as? String, !token.isEmpty else {
            throw Failure(description: "GitHub didn't give \(identity.botLogin) a token (\(status)): \(body["message"] as? String ?? "no reason given")")
        }
        // The bot's noreply address needs its user id; without it commits still carry the bot's name.
        // The slug is typed by the owner, so it may not make a URL; the lookup is optional anyway.
        let slug = identity.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var user: (Data, Int)?
        if let url = URL(string: "https://api.github.com/users/\(slug)%5Bbot%5D") {
            var lookup = URLRequest(url: url)
            lookup.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            lookup.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            user = try? await http(lookup)
        }
        let id = (user.flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] })?["id"] as? Int
        let email = id.map { "\($0)+\(identity.botLogin)@users.noreply.github.com" } ?? "\(identity.botLogin)@users.noreply.github.com"
        return Self.environment(token: token, name: identity.botLogin, email: email)
    }

    /// `gh` reads GH_TOKEN; `git` gets the token through gh's credential helper (any other helper, such as the
    /// owner's keychain, is cleared first) and GitHub's SSH remotes are rewritten to HTTPS so the owner's SSH key
    /// never pushes. Commits are authored and committed by the bot.
    static func environment(token: String, name: String, email: String) -> [String: String] {
        let config: [(String, String)] = [
            ("credential.helper", ""),
            ("credential.helper", "!gh auth git-credential"),
            ("url.https://github.com/.insteadOf", "git@github.com:"),
            ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
            ("user.name", name),
            ("user.email", email),
        ]
        var env = ["GH_TOKEN": token, "GITHUB_TOKEN": token,
                   "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
                   "GIT_TERMINAL_PROMPT": "0", "PENNANT_GITHUB_IDENTITY": name,
                   "GIT_CONFIG_COUNT": String(config.count)]
        for (i, (k, v)) in config.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = k
            env["GIT_CONFIG_VALUE_\(i)"] = v
        }
        return env
    }

    // MARK: Signing

    /// An RSA private key from PEM: PKCS#1 ("RSA PRIVATE KEY", what GitHub hands out) or PKCS#8 ("PRIVATE KEY"),
    /// including one pasted with its line breaks flattened.
    static func privateKey(pem: String) throws -> SecKey {
        let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let begin = text.range(of: "-----BEGIN "), let headEnd = text.range(of: "-----", range: begin.upperBound..<text.endIndex),
              let end = text.range(of: "-----END ", range: headEnd.upperBound..<text.endIndex) else {
            throw Failure(description: "The Vault entry isn't a PEM private key.")
        }
        let label = text[begin.upperBound..<headEnd.lowerBound]
        let body = text[headEnd.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard var der = Data(base64Encoded: String(body)) else { throw Failure(description: "The private key isn't valid base64.") }
        if label == "PRIVATE KEY" { der = try pkcs1(fromPKCS8: der) }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw Failure(description: "The private key couldn't be read: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return key
    }

    /// PKCS#8 wraps the PKCS#1 key: SEQUENCE { INTEGER, SEQUENCE { algorithm }, OCTET STRING { key } }.
    static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        var i = der.startIndex
        func header() throws -> (tag: UInt8, length: Int) {
            guard i < der.endIndex else { throw Failure(description: "The private key is cut short.") }
            let tag = der[i]; i += 1
            guard i < der.endIndex else { throw Failure(description: "The private key is cut short.") }
            var length = Int(der[i]); i += 1
            if length & 0x80 != 0 {
                let n = length & 0x7F
                length = 0
                for _ in 0..<n { guard i < der.endIndex else { throw Failure(description: "The private key is cut short.") }; length = length << 8 | Int(der[i]); i += 1 }
            }
            return (tag, length)
        }
        guard try header().tag == 0x30 else { throw Failure(description: "Not a PKCS#8 key.") }
        let version = try header(); i += version.length
        let algorithm = try header(); i += algorithm.length
        let octets = try header()
        guard octets.tag == 0x04, i + octets.length <= der.endIndex else { throw Failure(description: "Not a PKCS#8 RSA key.") }
        return der.subdata(in: i..<(i + octets.length))
    }

    /// The App's JWT: RS256, issued a minute back (clock skew), good for nine minutes.
    static func jwt(appID: Int, key: SecKey, now: Date) throws -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let iat = Int(now.timeIntervalSince1970) - 60
        let header = b64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = b64url(Data(#"{"iat":\#(iat),"exp":\#(iat + 600),"iss":"\#(appID)"}"#.utf8))
        let signingInput = Data("\(header).\(payload)".utf8)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, &error) as Data? else {
            throw Failure(description: "Couldn't sign with the App's key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return "\(header).\(payload).\(b64url(signature))"
    }
}
