import PennantCore
import Foundation
import MCP

/// A connector that runs inside the host and calls a provider's own API with the signed-in user's token.
/// It is served over an in-memory MCP transport, so the manager, the broker, the status chips and the
/// Connections screen treat it exactly like a remote MCP server.
protocol NativeConnector: Sendable {
    /// Shown as the server name in tool descriptions, e.g. "Microsoft 365".
    var displayName: String { get }
    var tools: [MCP.Tool] { get }
    /// Runs one tool and returns text for the model. Throwing marks the result as an error.
    func call(_ tool: String, arguments: [String: Value], api: ConnectorAPI) async throws -> String
}

enum NativeConnectors {
    static func make(_ id: String) -> (any NativeConnector)? {
        switch id {
        case MicrosoftGraphConnector.id: return MicrosoftGraphConnector()
        case LinkedInConnector.id: return LinkedInConnector()
        case RedditConnector.id: return RedditConnector()
        default: return nil
        }
    }
}

/// Everything a connector needs to call its API: the bearer token (refreshed by the manager when it nears
/// expiry, and once more after a 401), and the server's settings.
struct ConnectorAPI: Sendable {
    let token: @Sendable () async -> String?
    let refresh: @Sendable (_ rejected: String) async -> String?
    let settings: [String: String]
    var userAgent = "Pennant/\(PennantVersion.string) (macOS personal agent)"
    var session: URLSession = .shared

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let message: String
        var description: String { status == 0 ? message : "HTTP \(status): \(message)" }
    }

    /// Sends a request with the bearer token; on 401 refreshes once and retries. Returns the body and response.
    func send(_ method: String, _ url: URL, json: Any? = nil, form: [String: String]? = nil, body: Data? = nil, contentType: String? = nil, headers: [String: String] = [:], authorized: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var token = authorized ? await self.token() : nil
        if authorized, token == nil { throw Failure(status: 0, message: "Not signed in. Sign in from Connections.") }
        for attempt in 0 ..< 2 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if let form {
                request.httpBody = Data(form.map { "\(MCPOAuthClient.formEncode($0.key))=\(MCPOAuthClient.formEncode($0.value))" }.joined(separator: "&").utf8)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else if let body {
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, message: "no HTTP response") }
            if http.statusCode == 401, authorized, attempt == 0, let rejected = token, let fresh = await refresh(rejected) {
                token = fresh
                continue
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw Failure(status: http.statusCode, message: Self.errorMessage(data))
            }
            return (data, http)
        }
        throw Failure(status: 401, message: "The provider rejected the sign-in. Sign in again from Connections.")
    }

    /// Sends and decodes a JSON object reply (an empty body reads as an empty object).
    func json(_ method: String, _ url: URL, json body: Any? = nil, form: [String: String]? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        let (data, _) = try await send(method, url, json: body, form: form, headers: headers)
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func errorMessage(_ data: Data) -> String {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = o["error"] as? [String: Any] { return (e["message"] as? String) ?? (e["code"] as? String) ?? "error" }
            if let m = o["message"] as? String { return m }
            if let e = o["error"] as? String { return (o["error_description"] as? String).map { "\(e): \($0)" } ?? e }
            if let errors = (o["json"] as? [String: Any])?["errors"] as? [[Any]], let first = errors.first { return first.map { "\($0)" }.joined(separator: " ") }
        }
        return String(decoding: data.prefix(400), as: UTF8.self)
    }
}

// MARK: - Serving

enum NativeConnectorServer {
    /// Starts an in-process MCP server for the connector on `transport`.
    static func start(_ connector: any NativeConnector, api: ConnectorAPI, transport: any Transport) async throws -> Server {
        let server = Server(name: "Pennant \(connector.displayName)", version: PennantVersion.string, capabilities: .init(tools: .init(listChanged: false)))
        let tools = connector.tools
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let text = try await connector.call(params.name, arguments: params.arguments ?? [:], api: api)
                return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
            }
        }
        try await server.start(transport: transport)
        return server
    }
}

// MARK: - Helpers for connector code

extension MCP.Tool {
    /// A tool with a JSON Schema built from simple property descriptions.
    static func make(_ name: String, _ description: String, properties: [String: [String: Value]] = [:], required: [String] = [], readOnly: Bool, destructive: Bool = false) -> MCP.Tool {
        var props: [String: Value] = [:]
        for (k, v) in properties { props[k] = .object(v) }
        var schema: [String: Value] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return MCP.Tool(name: name, description: description, inputSchema: .object(schema), annotations: .init(readOnlyHint: readOnly, destructiveHint: destructive, openWorldHint: true))
    }
}

/// Short property constructors: `.str("Subject")`, `.int("How many", default: 10)`.
enum Prop {
    static func str(_ description: String) -> [String: Value] { ["type": "string", "description": .string(description)] }
    static func int(_ description: String) -> [String: Value] { ["type": "integer", "description": .string(description)] }
    static func bool(_ description: String) -> [String: Value] { ["type": "boolean", "description": .string(description)] }
    static func strings(_ description: String) -> [String: Value] { ["type": "array", "items": ["type": "string"], "description": .string(description)] }
    static func oneOf(_ description: String, _ values: [String]) -> [String: Value] { ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)] }
}

extension Dictionary where Key == String, Value == MCP.Value {
    func string(_ key: String) -> String? {
        if case .string(let s)? = self[key] { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        return nil
    }

    func require(_ key: String) throws -> String {
        guard let s = string(key) else { throw ConnectorAPI.Failure(status: 0, message: "Missing \(key).") }
        return s
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let i)?: return i
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let b)?: return b
        case .string(let s)?: return ["true", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    func strings(_ key: String) -> [String] {
        switch self[key] {
        case .array(let a)?: return a.compactMap { if case .string(let s) = $0 { return s.trimmingCharacters(in: .whitespaces) } else { return nil } }.filter { !$0.isEmpty }
        case .string(let s)?: return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: return []
        }
    }
}

/// Compact text from JSON for the model: pretty enough to read, trimmed to a size the context can afford.
enum ConnectorText {
    static func clip(_ s: String, _ limit: Int = 12_000) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "\n… (truncated)"
    }

    /// Strips tags and collapses whitespace in an HTML body (Outlook and Teams send HTML).
    static func plain(fromHTML html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func encodeQuery(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#'\" ")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
