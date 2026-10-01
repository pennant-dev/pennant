import PennantCore
import Foundation
import Security

/// A Teams bot through the Bot Framework: incoming activities arrive as webhooks (checked against Microsoft's
/// signing keys before anything is trusted), and replies go out through the Bot Connector REST API with a token
/// from the bot's own Entra app registration.
struct TeamsBot: Sendable {
    struct Config: Codable, Hashable, Sendable {
        /// The bot's Entra application (client) id: the audience of every token Teams sends.
        var appID: String
        /// The tenant the bot is registered in (single-tenant bots).
        var tenantID: String
        /// Where Teams reaches the webhook, e.g. https://mac.tailnet.ts.net/api/teams/messages.
        var publicURL: String
    }

    struct Activity: Sendable {
        var type: String
        var text: String
        var serviceURL: String
        var conversationID: String
        var conversationType: String
        var tenantID: String
        var fromID: String
        var fromAADObjectID: String
        var fromName: String
        var botID: String
        /// What a card button submitted (its data and the card's inputs), as text.
        var value: [String: String]
        /// A team channel's id (without the thread), when the message came from one.
        var channelID: String
        /// The channel's, chat's or team's name, when Teams says.
        var placeName: String?
        /// Who joined (a conversationUpdate), by Bot Framework id; the bot's own id when it was added.
        var membersAdded: [String]

        /// A team channel or a group chat, not a one-to-one chat.
        var isGroup: Bool { conversationType == "channel" || conversationType == "groupChat" }

        /// The channel or group chat itself. A channel message's conversation id names its thread
        /// ("19:…@thread.tacv2;messageid=…"), so replies go there; the channel is the part before it.
        var groupKey: String {
            if !channelID.isEmpty { return channelID }
            return conversationID.components(separatedBy: ";messageid=").first ?? conversationID
        }

        /// Reads a Bot Framework activity; nil when it isn't one.
        init?(_ json: [String: Any]) {
            guard let type = json["type"] as? String, let service = json["serviceUrl"] as? String,
                  let conversation = json["conversation"] as? [String: Any], let conversationID = conversation["id"] as? String else { return nil }
            let from = json["from"] as? [String: Any] ?? [:]
            let recipient = json["recipient"] as? [String: Any] ?? [:]
            let channelData = json["channelData"] as? [String: Any] ?? [:]
            self.type = type
            self.text = TeamsBot.plainText((json["text"] as? String) ?? "")
            self.serviceURL = service
            self.conversationID = conversationID
            self.conversationType = (conversation["conversationType"] as? String) ?? "personal"
            self.tenantID = (conversation["tenantId"] as? String) ?? ((channelData["tenant"] as? [String: Any])?["id"] as? String) ?? ""
            self.fromID = (from["id"] as? String) ?? ""
            self.fromAADObjectID = (from["aadObjectId"] as? String) ?? ""
            self.fromName = (from["name"] as? String) ?? "Teams user"
            self.botID = (recipient["id"] as? String) ?? ""
            self.value = ((json["value"] as? [String: Any]) ?? [:]).compactMapValues { v -> String? in
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            }
            let channel = channelData["channel"] as? [String: Any] ?? [:]
            let team = channelData["team"] as? [String: Any] ?? [:]
            self.channelID = (channel["id"] as? String) ?? ""
            self.placeName = [conversation["name"], channel["name"], team["name"]].lazy.compactMap { ($0 as? String)?.nilIfEmpty }.first
            self.membersAdded = ((json["membersAdded"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    let config: Config
    let secret: String
    let session: URLSession

    /// Replies (or writes first) in a conversation the bot is part of.
    func send(_ text: String, serviceURL: String, conversationID: String, tokens: TeamsTokenCache) async throws {
        _ = try await post(Self.activity(text: text), serviceURL: serviceURL, conversationID: conversationID, tokens: tokens)
    }

    /// Sends an Adaptive Card; returns the message's id, to update the card later.
    func send(card: JSONValue, summary: String, serviceURL: String, conversationID: String, tokens: TeamsTokenCache) async throws -> String? {
        try await post(Self.activity(card: card, summary: summary), serviceURL: serviceURL, conversationID: conversationID, tokens: tokens)
    }

    /// Replaces a card already sent (a decided approval loses its buttons).
    func update(activityID: String, card: JSONValue, summary: String, serviceURL: String, conversationID: String, tokens: TeamsTokenCache) async throws {
        var body = Self.activity(card: card, summary: summary)
        body["id"] = activityID
        _ = try await request("PUT", path: "v3/conversations/\(Self.escape(conversationID))/activities/\(Self.escape(activityID))", body: body, serviceURL: serviceURL, tokens: tokens)
    }

    /// Opens a one-to-one chat between the bot and someone in its organisation (the app must be installed for them).
    /// Returns the conversation's id.
    func startChat(withObjectID objectID: String, serviceURL: String, tokens: TeamsTokenCache) async throws -> String {
        let body: [String: Any] = ["isGroup": false, "bot": ["id": "28:\(config.appID)"], "members": [["id": "8:orgid:\(objectID)"]],
                                   "tenantId": config.tenantID, "channelData": ["tenant": ["id": config.tenantID]]]
        let data = try await request("POST", path: "v3/conversations", body: body, serviceURL: serviceURL, tokens: tokens)
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String else { throw Failure(description: "Teams didn't open a chat") }
        return id
    }

    static func activity(text: String) -> [String: Any] { ["type": "message", "text": text, "textFormat": "markdown"] }

    static func activity(card: JSONValue, summary: String) -> [String: Any] {
        let content = (try? JSONEncoder().encode(card)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        return ["type": "message", "summary": String(summary.prefix(200)),
                "attachments": [["contentType": "application/vnd.microsoft.card.adaptive", "content": content]]]
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    private func post(_ body: [String: Any], serviceURL: String, conversationID: String, tokens: TeamsTokenCache) async throws -> String? {
        let data = try await request("POST", path: "v3/conversations/\(Self.escape(conversationID))/activities", body: body, serviceURL: serviceURL, tokens: tokens)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String
    }

    private func request(_ method: String, path: String, body: [String: Any], serviceURL: String, tokens: TeamsTokenCache) async throws -> Data {
        let base = serviceURL.hasSuffix("/") ? serviceURL : serviceURL + "/"
        guard let url = URL(string: base + path) else { throw Failure(description: "Bad Teams service address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.token(config: config, secret: secret, session: session))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure(description: "Teams refused the message (\(code)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return data
    }

    /// Teams sends HTML for formatted messages and <at> tags for mentions; people meant the words.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<at>[^<]*</at>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The bot's own token for the Bot Connector (client credentials), kept until shortly before it expires.
actor TeamsTokenCache {
    private var cached: (token: String, expires: Date)?

    func token(config: TeamsBot.Config, secret: String, session: URLSession) async throws -> String {
        if let cached, cached.expires > Date().addingTimeInterval(120) { return cached.token }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(config.tenantID)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "client_credentials"), .init(name: "client_id", value: config.appID),
                           .init(name: "client_secret", value: secret), .init(name: "scope", value: "https://api.botframework.com/.default")]
        request.httpBody = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let token = json["access_token"] as? String else {
            throw TeamsBot.Failure(description: (json["error_description"] as? String).map { String($0.prefix(200)) } ?? "Entra didn't issue the bot a token")
        }
        cached = (token, Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600))
        return token
    }
}

/// Checks that a webhook really comes from Teams: an RS256 token signed by one of Microsoft's published keys
/// (Bot Framework's, or the bot's tenant's), issued by Bot Framework or that tenant, for this bot, and current.
actor TeamsTokenValidator {
    struct Invalid: Error, CustomStringConvertible { var description: String }

    typealias KeyFetcher = @Sendable (_ url: URL) async throws -> Data
    private let fetch: KeyFetcher
    private var keys: [String: SecKey] = [:]
    private var fetchedAt: Date = .distantPast

    static let botFrameworkIssuer = "https://api.botframework.com"
    static let botFrameworkKeys = URL(string: "https://login.botframework.com/v1/.well-known/keys")!

    init(fetch: @escaping KeyFetcher = { url in try await URLSession.shared.data(from: url).0 }) {
        self.fetch = fetch
    }

    static func issuers(tenantID: String) -> Set<String> {
        [botFrameworkIssuer, "https://sts.windows.net/\(tenantID)/", "https://login.microsoftonline.com/\(tenantID)/v2.0"]
    }

    static func keyURLs(tenantID: String) -> [URL] {
        [botFrameworkKeys, URL(string: "https://login.microsoftonline.com/\(tenantID)/discovery/v2.0/keys")!]
    }

    /// Returns the token's issuer when it holds up; throws otherwise.
    @discardableResult
    func validate(authorization: String?, config: TeamsBot.Config, now: Date = Date()) async throws -> String {
        guard let header = authorization, header.lowercased().hasPrefix("bearer ") else { throw Invalid(description: "no bearer token") }
        let token = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Self.base64URL(parts[0]), let payloadData = Self.base64URL(parts[1]), let signature = Self.base64URL(parts[2]),
              let head = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else { throw Invalid(description: "malformed token") }
        guard head["alg"] as? String == "RS256", let kid = head["kid"] as? String else { throw Invalid(description: "unexpected algorithm") }
        guard let key = try await key(kid, tenantID: config.tenantID) else { throw Invalid(description: "unknown signing key") }
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error) else {
            throw Invalid(description: "bad signature")
        }
        guard let iss = claims["iss"] as? String, Self.issuers(tenantID: config.tenantID).contains(iss) else { throw Invalid(description: "unexpected issuer") }
        guard claims["aud"] as? String == config.appID else { throw Invalid(description: "token is for another app") }
        let skew: TimeInterval = 300
        if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp + skew) < now { throw Invalid(description: "expired") }
        if let nbf = claims["nbf"] as? Double, Date(timeIntervalSince1970: nbf - skew) > now { throw Invalid(description: "not yet valid") }
        return iss
    }

    /// A signing key by id, from the cached key sets (refreshed daily, or when an unknown id shows up).
    private func key(_ kid: String, tenantID: String) async throws -> SecKey? {
        if let k = keys[kid], Date().timeIntervalSince(fetchedAt) < 86400 { return k }
        var fresh: [String: SecKey] = [:]
        for url in Self.keyURLs(tenantID: tenantID) {
            guard let data = try? await fetch(url), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for jwk in (json["keys"] as? [[String: Any]]) ?? [] {
                guard jwk["kty"] as? String == "RSA", let id = jwk["kid"] as? String, let n = (jwk["n"] as? String).flatMap(Self.base64URL),
                      let e = (jwk["e"] as? String).flatMap(Self.base64URL), let k = Self.rsaKey(modulus: n, exponent: e) else { continue }
                fresh[id] = k
            }
        }
        if !fresh.isEmpty { keys = fresh; fetchedAt = Date() }
        return keys[kid]
    }

    static func base64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// An RSA public key from a JWK's modulus and exponent, as the PKCS#1 structure Security reads.
    static func rsaKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ d: Data) -> Data {
            // Leading zeros go; a zero comes back in front when the top bit is set (ASN.1 integers are signed).
            var bytes = [UInt8](d)
            while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + Data(bytes)
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}
