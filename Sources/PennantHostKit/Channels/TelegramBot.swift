import PennantCore
import Foundation

/// The Telegram Bot API, as much as Pennant uses: who the bot is, long-polling for messages (so no public address
/// is needed), and sending text.
struct TelegramBot: Sendable {
    let token: String
    let session: URLSession

    struct Incoming: Sendable {
        var updateID: Int
        var chatID: String
        var text: String
        var senderName: String
        /// Private chats only: groups aren't how people talk to Pennant.
        var isPrivate: Bool
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// The bot's @username.
    func username() async throws -> String {
        let result = try await call("getMe", [:], timeout: 15)
        guard let name = (result as? [String: Any])?["username"] as? String else { throw Failure(description: "Telegram didn't say who the bot is") }
        return name
    }

    /// Waits up to `wait` seconds for messages after `offset`.
    func updates(after offset: Int, wait: Int = 30) async throws -> [Incoming] {
        let result = try await call("getUpdates", ["offset": offset, "timeout": wait, "allowed_updates": ["message"]], timeout: TimeInterval(wait + 15))
        return ((result as? [[String: Any]]) ?? []).compactMap { u in
            guard let id = u["update_id"] as? Int else { return nil }
            let message = u["message"] as? [String: Any] ?? [:]
            let chat = message["chat"] as? [String: Any] ?? [:]
            guard let chatID = (chat["id"] as? Int).map(String.init) ?? (chat["id"] as? String) else {
                return Incoming(updateID: id, chatID: "", text: "", senderName: "", isPrivate: false)
            }
            let from = message["from"] as? [String: Any] ?? [:]
            let name = [from["first_name"] as? String, from["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
            return Incoming(updateID: id, chatID: chatID, text: (message["text"] as? String) ?? "",
                            senderName: name.isEmpty ? ((from["username"] as? String) ?? "Telegram user") : name,
                            isPrivate: (chat["type"] as? String) == "private")
        }
    }

    /// Sends text, in pieces under Telegram's 4096-character limit.
    func send(_ text: String, to chatID: String) async throws {
        for piece in Self.split(text, limit: 4000) {
            _ = try await call("sendMessage", ["chat_id": chatID, "text": piece, "disable_web_page_preview": true], timeout: 30)
        }
    }

    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count + 1 > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            if paragraph.count > limit {
                var rest = Substring(paragraph)
                while !rest.isEmpty { pieces.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
            } else {
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private func call(_ method: String, _ body: [String: Any], timeout: TimeInterval) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(description: "Telegram sent something unreadable") }
        guard (json["ok"] as? Bool) == true else {
            // Never echo the URL: it holds the token.
            throw Failure(description: (json["description"] as? String) ?? "Telegram refused the request")
        }
        return json["result"] ?? [:]
    }
}
