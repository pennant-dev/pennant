import PennantCore
import Foundation
import MCP

/// `pennant-host coder-permission --task <id> --root <data folder> --port <api port>`: the MCP server the coding CLI
/// starts over stdio. `approve` is its `--permission-prompt-tool`, called whenever it wants to do something its
/// allow-list doesn't cover: relayed to the running host, which shows an approval card and answers with the decision
/// (Claude Code's permission-tool reply, `{"behavior": "allow" | "deny", …}`). `send_message` and `list_contacts` are
/// Pennant's own, run by the host for the coding task: how a coding agent messages people.
public enum CoderPermissionBridge {
    public static func run(taskID: TaskID, root: URL, port: Int) async throws {
        let server = Server(name: "Pennant permissions", version: PennantVersion.string, capabilities: .init(tools: .init(listChanged: false)))
        let tool = MCP.Tool.make("approve", "Ask the person on Pennant for permission to use a tool. Returns allow or deny.",
                                 properties: ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]],
                                 required: ["tool_name", "input"], readOnly: true)
        let send = MCP.Tool.make("send_message", "Message a person or group chat outside Pennant (iMessage, Teams, Telegram) as Pennant, the owner's assistant: e.g. the founders' group chat. Use this, not any other messaging tool: it reaches Pennant's contacts, sends from Pennant (never as the owner), and a message to someone not cleared for it waits on the owner's approval. Their reply comes back into this conversation. list_contacts shows who can be reached.",
                                 properties: ["to": ["type": "string", "description": "The contact's or group chat's name (or phone number, email)."],
                                              "text": ["type": "string", "description": "The message: plain text, short, and self-contained (they don't see this conversation)."],
                                              "channel": ["type": "string", "enum": .array(ChannelKind.allCases.map { .string($0.rawValue) }), "description": "Only this channel."]],
                                 required: ["to", "text"], readOnly: false)
        let contacts = MCP.Tool.make("list_contacts", "The people and group chats Pennant can message, by channel, and whether a message to them needs the owner's approval.",
                                     properties: [:], required: [], readOnly: true)
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: [tool, send, contacts]) }
        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            if params.name != "approve" {
                let arguments: JSONValue = (try? JSONEncoder().encode(args)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
                do {
                    let r = try await runTool(taskID: taskID, name: params.name, arguments: arguments, root: root, port: port)
                    return CallTool.Result(content: [.text(text: r.text, annotations: nil, _meta: nil)], isError: r.isError)
                } catch {
                    return CallTool.Result(content: [.text(text: "Couldn't reach Pennant: \(error)", annotations: nil, _meta: nil)], isError: true)
                }
            }
            let name = args["tool_name"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "tool"
            let input: JSONValue = (args["input"].flatMap { try? JSONEncoder().encode($0) }).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
            let reply: [String: Any]
            do {
                let decision = try await ask(taskID: taskID, tool: name, input: input, root: root, port: port)
                if decision.allow {
                    let updated = (try? JSONEncoder().encode(decision.input ?? input)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
                    var allow: [String: Any] = ["behavior": "allow", "updatedInput": updated]
                    if let mode = decision.mode {
                        allow["updatedPermissions"] = [["type": "setMode", "mode": mode.rawValue, "destination": "session"]]
                    }
                    reply = allow
                } else {
                    reply = ["behavior": "deny", "message": decision.message ?? "The user declined."]
                }
            } catch {
                reply = ["behavior": "deny", "message": "Couldn't reach Pennant to ask for permission: \(error)"]
            }
            let text = String(data: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// Relays one question to the host over its loopback socket and waits (as long as it takes) for the decision.
    static func ask(taskID: TaskID, tool: String, input: JSONValue, root: URL, port: Int) async throws -> (allow: Bool, input: JSONValue?, message: String?, mode: CodingMode?) {
        switch try await relay(.coderPermission(taskID: taskID, tool: tool, input: input), taskID: taskID, root: root, port: port) {
        case .coderDecision(let allow, let updated, let message, let mode): return (allow, updated, message, mode)
        case .error(_, let message): throw ToolError.failed(message)
        default: throw ToolError.failed("Unexpected reply from the host")
        }
    }

    /// Runs one of Pennant's tools on the host for the coding task.
    static func runTool(taskID: TaskID, name: String, arguments: JSONValue, root: URL, port: Int) async throws -> (text: String, isError: Bool) {
        switch try await relay(.coderTool(taskID: taskID, name: name, arguments: arguments), taskID: taskID, root: root, port: port) {
        case .coderToolResult(let text, let isError): return (text, isError)
        case .error(_, let message): return (message, true)
        default: throw ToolError.failed("Unexpected reply from the host")
        }
    }

    /// Sends one command to the host over its loopback socket (signed in with the local token) and waits for the reply.
    private static func relay(_ body: CommandBody, taskID: TaskID, root: URL, port: Int) async throws -> ReplyBody {
        let token = try String(contentsOf: root.appendingPathComponent(DeviceTokens.localTokenFileName), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 24 * 3600
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
        socket.maximumMessageSize = 64 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        func send(_ body: CommandBody) async throws -> CommandID {
            let command = ClientCommand(body: body)
            try await socket.send(.data(try WireMessage.command(command).encoded()))
            return command.id
        }
        func reply(to id: CommandID) async throws -> ReplyBody {
            while true {
                let frame = try await socket.receive()
                let data: Data
                switch frame {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                if let message = try? WireMessage.decode(data), case .reply(let r) = message, r.commandID == id { return r.result }
            }
        }

        let hello = ClientHello(clientID: ClientID("coder-permission-\(taskID.rawValue)"), displayName: "Coding permissions", platform: "bridge",
                                appVersion: PennantVersion.string, token: token)
        guard case .welcome = try await reply(to: try await send(.hello(hello))) else { throw ToolError.failed("The host didn't accept the bridge") }
        return try await reply(to: try await send(body))
    }
}
