import Foundation
@_exported import PennantPluginKit

/// Write a plugin: name its tools (their descriptions and schemas are in `plugin.json`) and run.
///
/// ```swift
/// @main enum Main {
///     static func main() async {
///         await Plugin.run(tools: [
///             PluginTool("hello") { args, context in .text("Hello, \(args["name"]?.string ?? "you").") },
///         ])
///     }
/// }
/// ```
///
/// Stdout is the channel to Pennant: never `print`. Log with `context.log`, or write to stderr.
public enum Plugin {
    /// Serves Pennant over stdin and stdout until Pennant says stop or goes away.
    public static func run(tools: [PluginTool]) async {
        let channel = PluginChannel(reading: .standardInput, writing: .standardOutput)
        await serve(tools: tools, channel: channel)
        // The channel closed or Pennant asked to stop.
        await Runner.shared.waitForEnd()
    }

    /// The same, over any channel: tests run a plugin in-process this way.
    public static func serve(tools: [PluginTool], channel: PluginChannel) async {
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let state = Runner.State()
        await channel.start(handler: { method, params in
            switch method {
            case PluginMethod.initialize:
                let context = PluginContext(channel: channel, granted: Set(params["granted"]?.array?.compactMap(\.string) ?? []),
                                            settings: params["settings"] ?? .object([:]), host: params["host"]?.string ?? "")
                await state.set(context)
                return ["ready": true, "tools": .array(tools.map { .string($0.name) })]
            case PluginMethod.toolCall:
                guard let name = params["name"]?.string, let tool = byName[name] else {
                    throw PluginRPCError.failed("This plugin has no tool \(params["name"]?.string ?? "?")")
                }
                // A call that arrives with `initialize` still running waits for it.
                let context = await state.ready()
                do {
                    let output = try await tool.handler(params["arguments"] ?? .object([:]), context)
                    return ["text": .string(output.text), "isError": .bool(output.isError)]
                } catch let error as PluginRPCError {
                    return ["text": .string(error.message), "isError": true]
                } catch {
                    return ["text": .string(String(describing: error)), "isError": true]
                }
            case PluginMethod.shutdown:
                Task { try? await Task.sleep(for: .milliseconds(100)); await Runner.shared.end() }
                return .null
            default:
                throw PluginRPCError.unknownMethod(method)
            }
        }, onClose: { Task { await Runner.shared.end() } })
    }
}

/// One tool: its name in `plugin.json`, and what it does.
public struct PluginTool: Sendable {
    public let name: String
    public let handler: @Sendable (_ arguments: PluginValue, _ context: PluginContext) async throws -> ToolOutput
    public init(_ name: String, _ handler: @escaping @Sendable (_ arguments: PluginValue, _ context: PluginContext) async throws -> ToolOutput) {
        self.name = name
        self.handler = handler
    }
}

/// What a tool hands back to the model.
public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public static func text(_ text: String) -> ToolOutput { ToolOutput(text: text, isError: false) }
    public static func error(_ text: String) -> ToolOutput { ToolOutput(text: text, isError: true) }
}

/// Pennant, from inside a plugin: everything the owner granted it, as plain `async` calls.
public final class PluginContext: Sendable {
    let channel: PluginChannel
    /// The capabilities the owner granted, by key ("secret:azure-sp", "credential:azure-management", "network").
    public let granted: Set<String>
    /// The plugin's settings, as the owner set them when it started.
    public let settings: PluginValue
    /// The host's name and version.
    public let host: String

    init(channel: PluginChannel, granted: Set<String>, settings: PluginValue, host: String) {
        self.channel = channel; self.granted = granted; self.settings = settings; self.host = host
    }

    public func isGranted(_ key: String) -> Bool { granted.contains(key) }

    /// The vault item the owner put in this slot: its `username`, `password`, `secret`, `url`, as stored.
    public func secret(_ slot: String) async throws -> [String: String] {
        let value = try await channel.request(PluginMethod.secretGet, ["slot": .string(slot)])
        return (value.object ?? [:]).compactMapValues(\.string)
    }

    /// What the credential helper prints: usually a token, sometimes JSON with one in it.
    public func credential(_ name: String) async throws -> String {
        try await channel.request(PluginMethod.credentialGet, ["name": .string(name)])["output"]?.string ?? ""
    }

    /// Settings as they are now (the owner may have changed them since the plugin started).
    public func currentSettings() async throws -> PluginValue {
        try await channel.request(PluginMethod.settingsGet)
    }

    public func stored(_ key: String) async throws -> PluginValue? {
        let value = try await channel.request(PluginMethod.storageGet, ["key": .string(key)])
        return value.isNull ? nil : value
    }

    public func store(_ key: String, _ value: PluginValue?) async throws {
        _ = try await channel.request(PluginMethod.storageSet, ["key": .string(key), "value": value ?? .null])
    }

    /// Posts in the Pennant chat, under the plugin's name.
    public func post(_ text: String) async throws {
        _ = try await channel.request(PluginMethod.chatPost, ["text": .string(text)])
    }

    /// A line in Pennant's log, under the plugin's id.
    public func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Keeps the process alive until the channel closes or Pennant asks it to stop.
actor Runner {
    static let shared = Runner()
    private var ended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func end() {
        ended = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func waitForEnd() async {
        if ended { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    actor State {
        private var context: PluginContext?
        private var waiting: [CheckedContinuation<PluginContext, Never>] = []

        func set(_ context: PluginContext) {
            self.context = context
            for w in waiting { w.resume(returning: context) }
            waiting.removeAll()
        }

        func ready() async -> PluginContext {
            if let context { return context }
            return await withCheckedContinuation { waiting.append($0) }
        }
    }
}
