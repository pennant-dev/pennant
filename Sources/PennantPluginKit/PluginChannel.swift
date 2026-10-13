import Foundation

/// An error that crosses the channel: a refused grant, a failed call, a method nobody answers.
public struct PluginRPCError: Error, Codable, Sendable, CustomStringConvertible, Equatable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public var description: String { message }

    public static func notGranted(_ capability: String) -> PluginRPCError { .init(code: -32001, message: "Not granted: \(capability). The owner grants it in Pennant.") }
    public static func failed(_ message: String) -> PluginRPCError { .init(code: -32000, message: message) }
    public static func unknownMethod(_ method: String) -> PluginRPCError { .init(code: -32601, message: "No method \(method)") }
    public static let closed = PluginRPCError(code: -32003, message: "The plugin's channel closed")
    public static let timedOut = PluginRPCError(code: -32002, message: "No answer in time")
}

/// The method names on the channel. Pennant calls the plugin with the first group; the plugin calls Pennant with the rest.
public enum PluginMethod {
    // Pennant → plugin
    public static let initialize = "initialize"
    public static let toolCall = "tool/call"
    public static let shutdown = "shutdown"
    // Plugin → Pennant
    public static let secretGet = "secrets/get"
    public static let credentialGet = "credentials/get"
    public static let settingsGet = "settings/get"
    public static let storageGet = "storage/get"
    public static let storageSet = "storage/set"
    public static let chatPost = "chat/post"
    public static let log = "log"
}

/// JSON-RPC 2.0, one message per line, both ways over a pair of pipes: each side sends requests and notifications and
/// answers the other's. Pennant and the plugin SDK use the same type on their ends.
public actor PluginChannel {
    public typealias Handler = @Sendable (_ method: String, _ params: PluginValue) async throws -> PluginValue

    private let input: FileHandle
    private let output: FileHandle
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<PluginValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false

    public init(reading input: FileHandle, writing output: FileHandle) {
        self.input = input
        self.output = output
    }

    private struct Envelope: Codable {
        var jsonrpc = "2.0"
        var id: Int?
        var method: String?
        var params: PluginValue?
        var result: PluginValue?
        var error: PluginRPCError?
    }

    /// Starts reading. `handler` answers the other side's requests and notifications; `onClose` runs once when the other
    /// side goes away.
    public func start(handler: @escaping Handler, onClose: (@Sendable () -> Void)? = nil) {
        guard reader == nil else { return }
        // Not `FileHandle.bytes`: it reads every handle on one shared serial queue, so one idle channel would block the
        // rest (two plugins, or a plugin served in the same process).
        let chunks = AsyncStream<Data> { continuation in
            input.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        reader = Task { [weak self] in
            var pending = Data()
            for await chunk in chunks {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex ..< end]
                    pending = Data(pending[pending.index(after: end)...])
                    guard let self, let message = try? JSONDecoder().decode(Envelope.self, from: line) else { continue }
                    await self.receive(message, handler: handler)
                }
            }
            await self?.finish()
            onClose?()
        }
    }

    private func receive(_ message: Envelope, handler: @escaping Handler) {
        if let method = message.method {
            let id = message.id
            Task { [weak self] in
                let reply: Envelope
                do {
                    let result = try await handler(method, message.params ?? .null)
                    reply = Envelope(id: id, result: result)
                } catch let error as PluginRPCError {
                    reply = Envelope(id: id, error: error)
                } catch {
                    reply = Envelope(id: id, error: .failed(String(describing: error)))
                }
                // A notification gets no answer.
                if id != nil { await self?.send(reply) }
            }
        } else if let id = message.id, let continuation = waiting.removeValue(forKey: id) {
            if let error = message.error { continuation.resume(throwing: error) } else { continuation.resume(returning: message.result ?? .null) }
        }
    }

    /// Calls the other side and waits for its answer.
    public func request(_ method: String, _ params: PluginValue = .null, timeout: TimeInterval = 120) async throws -> PluginValue {
        guard !closed else { throw PluginRPCError.closed }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            send(Envelope(id: id, method: method, params: params))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
    }

    public func close() {
        input.readabilityHandler = nil
        try? output.close()
        finish()
    }

    private func expire(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: PluginRPCError.timedOut)
    }

    private func finish() {
        closed = true
        for (_, continuation) in waiting { continuation.resume(throwing: PluginRPCError.closed) }
        waiting.removeAll()
    }

    private func send(_ message: Envelope) {
        guard !closed, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        do { try output.write(contentsOf: data) } catch { finish() }
    }
}
