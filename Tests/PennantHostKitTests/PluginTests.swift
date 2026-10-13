import PennantCore
@testable import PennantHostKit
import PennantPluginSDK
@testable import AzurePluginKit
import Foundation
import XCTest

/// Plugins: the channel both ways, manifests, the manager's grants (what a plugin gets, what it's refused), the
/// always-ask gate, and the Azure plugin against a fake Azure.
final class PluginTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Channel

    /// Two channels joined by pipes, as a host and a plugin.
    static func pair() -> (host: PluginChannel, plugin: PluginChannel) {
        let toPlugin = Pipe(), toHost = Pipe()
        return (PluginChannel(reading: toHost.fileHandleForReading, writing: toPlugin.fileHandleForWriting),
                PluginChannel(reading: toPlugin.fileHandleForReading, writing: toHost.fileHandleForWriting))
    }

    func testChannelCallsBothWaysAndCarriesErrors() async throws {
        let (host, plugin) = Self.pair()
        await host.start(handler: { method, params in
            if method == "double" { return .number((params["n"]?.number ?? 0) * 2) }
            throw PluginRPCError.notGranted("secret:x")
        })
        await plugin.start(handler: { method, _ in
            // Answering the host, the plugin asks the host something first.
            if method == "ask" { return try await plugin.request("double", ["n": 21]) }
            throw PluginRPCError.unknownMethod(method)
        })
        let answer = try await host.request("ask")
        XCTAssertEqual(answer.number, 42)
        do {
            _ = try await plugin.request("secrets/get")
            XCTFail("expected a refusal")
        } catch let error as PluginRPCError {
            XCTAssertEqual(error.code, -32001)
            XCTAssertTrue(error.message.contains("secret:x"))
        }
        await host.close()
        do { _ = try await host.request("ask"); XCTFail("closed") } catch let error as PluginRPCError { XCTAssertEqual(error, .closed) }
    }

    // MARK: Manifests

    static let azureManifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Plugins/Azure/Resources/plugin.json")

    func testTheAzureManifestIsValid() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: Self.azureManifest))
        XCTAssertEqual(manifest.problems(), [])
        XCTAssertEqual(manifest.toolPrefix, "azure")
        XCTAssertEqual(Set(manifest.capabilities.map(\.key)), ["network", "credential:azure-management", "credential:azure-logs", "secret:azure-service-principal"])
        let changing = manifest.contributes.tools.filter { $0.asksFirst == true }.map(\.name)
        XCTAssertEqual(Set(changing), ["scale_node_pool", "restart_app"])
        // Every tool the manifest declares, the plugin serves.
        XCTAssertEqual(Set(manifest.contributes.tools.map(\.name)), Set(AzureTools.all().map(\.name)))
    }

    func testABadManifestSaysWhatsWrong() {
        let bad = PluginManifest(id: "azure", name: "", version: "1", publisher: "x", description: "y", api: "9", capabilities: [.ability("everything")],
                                 contributes: .init(tools: [PluginToolDeclaration(name: "Do-It", description: ""), PluginToolDeclaration(name: "x", description: "d", readOnly: true, asksFirst: true)]))
        let problems = bad.problems().joined(separator: "\n")
        for expected in ["reverse-DNS", "name is empty", "semver", "plugin API 9", "Do-It", "no description", "both readOnly and asksFirst", "no capability everything"] {
            XCTAssertTrue(problems.contains(expected), "missing: \(expected)\n\(problems)")
        }
    }

    // MARK: The manager

    /// A plugin bundle on disk whose tools run in this process.
    func makeBundle(capabilities: [PluginCapability], tools: [PluginToolDeclaration]) throws -> URL {
        let bundle = root.appendingPathComponent("src/Test.plugin", isDirectory: true)
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let exe = bundle.appendingPathComponent("Contents/MacOS/Test")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let manifest = PluginManifest(id: "dev.example.test", name: "Test", version: "1.0.0", publisher: "Tests", description: "A test plugin",
                                      capabilities: capabilities, contributes: .init(tools: tools))
        try JSONEncoder().encode(manifest).write(to: bundle.appendingPathComponent("Contents/Resources/plugin.json"))
        return bundle
    }

    /// Serves `tools` in this process for whatever the manager launches.
    static func inProcess(_ tools: [PluginTool]) -> PluginManager.Launcher {
        { _, _, _, _, _ in
            let (host, plugin) = pair()
            Task { await Plugin.serve(tools: tools, channel: plugin) }
            return InProcessConnection(channel: host)
        }
    }

    struct InProcessConnection: PluginConnection {
        let channel: PluginChannel
        func stop(grace: TimeInterval) async { await channel.close() }
    }

    static let testTools: [PluginTool] = [
        PluginTool("echo") { args, context in .text("echo \(args["text"]?.string ?? "") region=\(context.settings["region"]?.string ?? "none")") },
        PluginTool("token") { _, context in .text(try await context.credential("cloud")) },
        PluginTool("key") { _, context in .text(try await context.secret("api")["password"] ?? "none") },
        PluginTool("say") { args, context in try await context.post(args["text"]?.string ?? ""); return .text("posted") },
        PluginTool("remember") { args, context in
            if let v = args["value"]?.string { try await context.store("k", .string(v)) }
            return .text(try await context.stored("k")?.string ?? "nothing")
        },
    ]

    func testGrantsDecideWhatAPluginGets() async throws {
        let broker = ToolBroker()
        let paths = HostPaths(root: root.appendingPathComponent("host"))
        try paths.ensureDirectories()
        let store = try SQLiteStore(paths: paths)
        let vault = VaultService(store: store, keychain: KeychainStore(service: "test", fallbackFileURL: root.appendingPathComponent("keys.json"), preferFile: true))
        _ = try await vault.save(VaultItem(name: "Test API", kind: .login, username: "me"), secret: VaultSecret(password: "pa55"))
        let manager = PluginManager(root: root, broker: broker, vault: vault, hostName: "Pennant test", sandboxed: false, launcher: Self.inProcess(Self.testTools))
        let posted = Posted()
        await manager.setChatPoster { name, text in await posted.add("\(name): \(text)") }
        let bundle = try makeBundle(
            capabilities: [.credential(name: "cloud", why: "a token", suggest: "echo suggested-token"), .secret(slot: "api", why: "a key"), .ability("chat.post")],
            tools: ["echo", "token", "key", "say", "remember"].map { PluginToolDeclaration(name: $0, description: "d", readOnly: $0 != "say") } + [PluginToolDeclaration(name: "nope", description: "not served")])

        let installed = try await manager.install(path: bundle.path)
        XCTAssertEqual(installed.first?.state, .running)
        let echoTool = await broker.tool(named: "test__echo")
        let echo = try XCTUnwrap(echoTool)
        XCTAssertEqual(echo.spec.source, "plugin:dev.example.test")
        XCTAssertFalse(echo.spec.isConsequential)
        let sayTool = await broker.tool(named: "test__say")
        let say = try XCTUnwrap(sayTool)
        XCTAssertTrue(say.spec.isConsequential)
        let unserved = await broker.tool(named: "test__nope")
        XCTAssertNil(unserved, "a tool the plugin doesn't serve isn't offered")

        let id = "dev.example.test"
        var result = try await manager.callTool(id, tool: "echo", arguments: ["text": "hi"])
        XCTAssertEqual(result.text, "echo hi region=none")

        // Nothing granted yet: each ask is refused, and noted.
        for tool in ["token", "key", "say"] {
            result = try await manager.callTool(id, tool: tool, arguments: ["text": "x"])
            XCTAssertTrue(result.isError, tool)
            XCTAssertTrue(result.text.contains("Not granted"), result.text)
        }
        let refused = await manager.statuses().first?.activity.filter { !$0.allowed }.map(\.what) ?? []
        XCTAssertEqual(Set(refused), ["credentials/get credential:cloud", "secrets/get secret:api", "chat/post chat.post"])
        let nothingPosted = await posted.all
        XCTAssertEqual(nothingPosted, [])

        // Granted: the helper's command runs (the plugin's suggestion, or the owner's own), the vault item comes
        // through, and notes reach the chat.
        _ = try await manager.grant(id, capability: "credential:cloud", value: nil)
        result = try await manager.callTool(id, tool: "token", arguments: [:])
        XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "suggested-token")
        _ = try await manager.grant(id, capability: "credential:cloud", value: "echo owners-token")
        result = try await manager.callTool(id, tool: "token", arguments: [:])
        XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "owners-token")
        do {
            _ = try await manager.grant(id, capability: "secret:api", value: "no such item")
            XCTFail("a missing vault item is refused")
        } catch {}
        _ = try await manager.grant(id, capability: "secret:api", value: "Test API")
        result = try await manager.callTool(id, tool: "key", arguments: [:])
        XCTAssertEqual(result.text, "pa55")
        _ = try await manager.grant(id, capability: "chat.post", value: nil)
        result = try await manager.callTool(id, tool: "say", arguments: ["text": "hello"])
        XCTAssertFalse(result.isError)
        let said = await posted.all
        XCTAssertEqual(said, ["Test: hello"])
        do {
            _ = try await manager.grant(id, capability: "network.everything", value: nil)
            XCTFail("only declared capabilities can be granted")
        } catch {}

        // Its own storage, and settings that reach it (it restarts with them).
        result = try await manager.callTool(id, tool: "remember", arguments: ["value": "kept"])
        XCTAssertEqual(result.text, "kept")
        _ = try await manager.setSettings(id, ["region": "westeurope"])
        result = try await manager.callTool(id, tool: "echo", arguments: ["text": "again"])
        XCTAssertEqual(result.text, "echo again region=westeurope")
        result = try await manager.callTool(id, tool: "remember", arguments: [:])
        XCTAssertEqual(result.text, "kept")

        // Revoked: refused again. Grants survive a restart of Pennant.
        _ = try await manager.revoke(id, capability: "secret:api")
        result = try await manager.callTool(id, tool: "key", arguments: [:])
        XCTAssertTrue(result.isError)
        await manager.stop()
        let again = PluginManager(root: root, broker: broker, vault: vault, hostName: "Pennant test", sandboxed: false, launcher: Self.inProcess(Self.testTools))
        await again.start()
        let statuses = await again.statuses()
        let reloaded = try XCTUnwrap(statuses.first)
        XCTAssertEqual(reloaded.state, .running)
        XCTAssertEqual(Set(reloaded.capabilities.filter(\.granted).map(\.key)), ["credential:cloud", "chat.post"])
        XCTAssertEqual(reloaded.capabilities.first { $0.key == "credential:cloud" }?.value, "echo owners-token")

        // Off, then removed: its tools go.
        _ = try await again.setEnabled(id, false)
        let off = await broker.tool(named: "test__echo")
        XCTAssertNil(off)
        do { _ = try await again.callTool(id, tool: "echo", arguments: [:]); XCTFail("not running") } catch {}
        _ = try await again.setEnabled(id, true)
        let on = await broker.tool(named: "test__echo")
        XCTAssertNotNil(on)
        let left = try await again.remove(id)
        XCTAssertEqual(left, [])
        let gone = await broker.tool(named: "test__echo")
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.installedURL(id).path))
    }

    func testAPluginToolCantTakeAnotherToolsName() async throws {
        let broker = ToolBroker()
        let existing = PluginToolProxy(manager: PluginManager(root: root, broker: broker, vault: nil, hostName: "x"), pluginID: "dev.other.thing",
                                       manifest: PluginManifest(id: "dev.other.thing", name: "Test", version: "1.0.0", publisher: "p", description: "d"),
                                       declaration: PluginToolDeclaration(name: "echo", description: "d"))
        await broker.register(existing)
        let manager = PluginManager(root: root, broker: broker, vault: nil, hostName: "x", sandboxed: false, launcher: Self.inProcess(Self.testTools))
        _ = try await manager.install(path: try makeBundle(capabilities: [], tools: [PluginToolDeclaration(name: "echo", description: "d")]).path)
        let keptTool = await broker.tool(named: "test__echo")
        let kept = try XCTUnwrap(keptTool)
        XCTAssertEqual(kept.spec.source, "plugin:dev.other.thing")
    }

    func testTheSandboxProfileOnlyOpensTheNetworkWhenGranted() throws {
        // Under /tmp, which is a symlink to /private/tmp: the profile names the real paths, /private and all.
        let bundle = URL(fileURLWithPath: "/tmp").appendingPathComponent("A-\(UUID().uuidString).plugin")
        let exe = bundle.appendingPathComponent("Contents/MacOS/A")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: exe)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let closed = PluginSandbox.profile(executable: exe, bundle: bundle, data: root, network: false)
        let open = PluginSandbox.profile(executable: exe, bundle: bundle, data: root, network: true)
        XCTAssertFalse(closed.contains("network-outbound"))
        XCTAssertTrue(open.contains("(allow network-outbound)"))
        XCTAssertTrue(closed.contains("(deny default)"))
        XCTAssertTrue(closed.contains("(allow process-exec (literal \"/private/tmp/\(bundle.lastPathComponent)/Contents/MacOS/A\"))"), closed)
        XCTAssertFalse(closed.contains("process-fork"))
    }

    func testAHelpersTokenIsKeptUntilItExpires() {
        let later = Date().addingTimeInterval(3600).timeIntervalSince1970
        let expiry = PluginManager.expiry(of: #"{"accessToken": "t", "expires_on": \#(Int(later))}"#)
        XCTAssertEqual(expiry?.timeIntervalSince1970 ?? 0, later, accuracy: 1)
        XCTAssertNil(PluginManager.expiry(of: "plain-token"))
    }

    // MARK: Always ask

    func testAnAsksFirstToolAlwaysWaitsOnACard() {
        let spec = ToolSpec(name: "azure__restart_app", description: "d", inputSchema: .object([:]), isConsequential: true, source: "plugin:dev.pennant.azure", asksFirst: true)
        XCTAssertNil(SignOff.reason(tool: spec.name, arguments: ["app": "web"]), "the classifier alone wouldn't stop it")
        XCTAssertEqual(SignOff.asksFirst(spec, arguments: ["app": "web"]), .changes)
        XCTAssertEqual(SignOff.asksFirst(spec, arguments: ["app": "web", "approval_id": "made-up"]), .changes, "an approval id doesn't excuse it")
        let plain = ToolSpec(name: "azure__costs", description: "d", inputSchema: .object([:]), source: "plugin:dev.pennant.azure")
        XCTAssertNil(SignOff.asksFirst(plain, arguments: [:]))
    }

    func testToolSpecsWithoutTheFlagStillDecode() throws {
        let old = #"{"name":"x","description":"d","inputSchema":{},"isConsequential":false,"needsDesktop":false,"source":"builtin"}"#
        let spec = try JSONDecoder().decode(ToolSpec.self, from: Data(old.utf8))
        XCTAssertFalse(spec.asksFirst)
    }

    func testPluginToolsLoadLikeConnections() {
        XCTAssertEqual(TaskRuntime.serviceKey("plugin:dev.pennant.azure"), "plugin:dev.pennant.azure")
        XCTAssertEqual(TaskRuntime.serviceKey("mcp:abc"), "abc")
        XCTAssertNil(TaskRuntime.serviceKey("builtin"))
        XCTAssertEqual(TaskRuntime.serviceSource("plugin:dev.pennant.azure"), "plugin:dev.pennant.azure")
        XCTAssertEqual(TaskRuntime.serviceSource("abc"), "mcp:abc")
    }

    // MARK: Azure

    /// The Azure plugin's tools, served in this process against `azure`, with a credential helper that prints an az token.
    func azure(_ azure: FakeAzure, granted: [String] = ["network", "credential:azure-management", "credential:azure-logs"], settings: PluginValue = [:]) async throws -> PluginChannel {
        let (host, plugin) = Self.pair()
        Task { await Plugin.serve(tools: AzureTools.all(http: azure), channel: plugin) }
        await host.start(handler: { method, _ in
            guard method == PluginMethod.credentialGet else { throw PluginRPCError.unknownMethod(method) }
            return ["output": .string(#"{"accessToken": "tok-123", "expires_on": \#(Int(Date().timeIntervalSince1970) + 3600), "tokenType": "Bearer"}"#)]
        })
        _ = try await host.request(PluginMethod.initialize, ["granted": .array(granted.map { .string($0) }), "settings": settings, "host": "test"])
        return host
    }

    func call(_ host: PluginChannel, _ tool: String, _ arguments: PluginValue = [:]) async throws -> (text: String, isError: Bool) {
        let reply = try await host.request(PluginMethod.toolCall, ["name": .string(tool), "arguments": arguments])
        return (reply["text"]?.string ?? "", reply["isError"]?.bool ?? false)
    }

    static let subscriptions: PluginValue = ["value": [
        ["subscriptionId": "11111111-1111-1111-1111-111111111111", "displayName": "Production", "state": "Enabled"],
        ["subscriptionId": "22222222-2222-2222-2222-222222222222", "displayName": "Sandbox", "state": "Enabled"],
        ["subscriptionId": "33333333-3333-3333-3333-333333333333", "displayName": "Old", "state": "Disabled"],
    ]]

    func testResourcesQueryTheGraphWithFiltersQuoted() async throws {
        let fake = FakeAzure()
        await fake.on("/subscriptions?", Self.subscriptions)
        await fake.on("Microsoft.ResourceGraph", ["totalRecords": 3, "data": [
            ["name": "web-1", "type": "microsoft.web/sites", "resourceGroup": "apps", "location": "eastus", "subscriptionId": "11111111-1111-1111-1111-111111111111"],
        ]])
        let host = try await azure(fake, settings: ["subscriptions": ["production"]])
        let result = try await call(host, "resources", ["type": "sites", "name": "o'brien", "tag": "env=prod"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("| web-1 | microsoft.web/sites | apps | eastus | Production |"), result.text)
        XCTAssertTrue(result.text.contains("1 of 3"))
        let sent = await fake.requests
        let graph = try XCTUnwrap(sent.last { $0.url.contains("ResourceGraph") })
        XCTAssertEqual(graph.authorization, "Bearer tok-123")
        let body = try XCTUnwrap(graph.body)
        XCTAssertEqual(body["subscriptions"], ["11111111-1111-1111-1111-111111111111"], "only the subscription in settings")
        let query = body["query"]?.string ?? ""
        XCTAssertTrue(query.contains("type contains 'sites'"), query)
        XCTAssertTrue(query.contains(#"name contains 'o\'brien'"#), query)
        XCTAssertTrue(query.contains("tostring(tags['env']) =~ 'prod'"), query)
        // One token for both requests: the helper isn't run again.
        let tokens = Set(await fake.requests.map(\.authorization))
        XCTAssertEqual(tokens, ["Bearer tok-123"])
    }

    func testCostsAddUpPerSubscription() async throws {
        let fake = FakeAzure()
        await fake.on("/subscriptions?", Self.subscriptions)
        await fake.on("CostManagement/query", ["properties": [
            "columns": [["name": "Cost", "type": "Number"], ["name": "ServiceName", "type": "String"], ["name": "Currency", "type": "String"]],
            "rows": [[12.5, "Storage", "USD"], [100.25, "Azure Kubernetes Service", "USD"]],
        ]])
        let host = try await azure(fake)
        let result = try await call(host, "costs", ["group_by": "service"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Production: 112.75 USD this month so far"), result.text)
        XCTAssertTrue(result.text.contains("Sandbox: 112.75 USD"), result.text)
        XCTAssertFalse(result.text.contains("Old"), "a disabled subscription is out of scope")
        let lines = result.text.components(separatedBy: "\n")
        let aks = try XCTUnwrap(lines.firstIndex { $0.contains("Azure Kubernetes Service") })
        let storage = try XCTUnwrap(lines.firstIndex { $0.contains("Storage") })
        XCTAssertLessThan(aks, storage, "biggest first")
    }

    func testScalingRefusesAnAutoscaledPoolAndSendsTheCountOtherwise() async throws {
        let fake = FakeAzure()
        await fake.on("/subscriptions?", Self.subscriptions)
        await fake.on("Microsoft.ResourceGraph", ["data": [["name": "aks-prod", "resourceGroup": "k8s", "subscriptionId": "11111111-1111-1111-1111-111111111111"]]])
        await fake.on("agentPools/auto", ["properties": ["count": 3, "enableAutoScaling": true, "minCount": 2, "maxCount": 6]])
        await fake.on("agentPools/user", ["properties": ["count": 3, "vmSize": "Standard_D4s_v5", "provisioningState": "Succeeded", "enableAutoScaling": false]])
        let host = try await azure(fake)
        var result = try await call(host, "scale_node_pool", ["cluster": "aks-prod", "pool": "auto", "count": 5])
        XCTAssertTrue(result.text.contains("autoscaled"), result.text)
        let puts = await fake.requests.filter { $0.method == "PUT" }
        XCTAssertTrue(puts.isEmpty)
        result = try await call(host, "scale_node_pool", ["cluster": "aks-prod", "pool": "user", "count": 5])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("3 → 5 nodes"), result.text)
        let all = await fake.requests
        let put = try XCTUnwrap(all.last { $0.method == "PUT" })
        XCTAssertTrue(put.url.contains("/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/k8s/providers/Microsoft.ContainerService/managedClusters/aks-prod/agentPools/user"), put.url)
        XCTAssertEqual(put.body?["properties"]?["count"], 5)
        XCTAssertNil(put.body?["properties"]?["provisioningState"], "read-only fields stay out")
        XCTAssertEqual(put.body?["properties"]?["vmSize"], "Standard_D4s_v5")
    }

    func testWithoutASignInTheToolsSaySoPlainly() async throws {
        let host = try await azure(FakeAzure(), granted: ["network"])
        let result = try await call(host, "subscriptions")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Grant the Azure plugin a sign-in"), result.text)
    }

    func testAzureErrorsComeBackReadable() async throws {
        let fake = FakeAzure()
        await fake.on("/subscriptions?", ["error": ["code": "AuthorizationFailed", "message": "The client does not have authorization"]], status: 403)
        let host = try await azure(fake)
        let result = try await call(host, "subscriptions")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("AuthorizationFailed: The client does not have authorization"), result.text)
    }

    func testSmallHelpers() {
        XCTAssertEqual(Duration8601.parse("24h"), "PT24H")
        XCTAssertEqual(Duration8601.parse("7d"), "P7D")
        XCTAssertEqual(Duration8601.parse("30m"), "PT30M")
        XCTAssertEqual(Duration8601.parse("PT2H"), "PT2H")
        XCTAssertEqual(Duration8601.parse("soon"), "PT1H")
        XCTAssertEqual(KQL.quote(#"a'b\c"#), #"'a\'b\\c'"#)
        XCTAssertEqual(AzureAuth.parseLocalDate("2026-10-06 14:31:07.000000").map { Calendar.current.component(.minute, from: $0) }, 31)
    }
}

actor Posted {
    private(set) var all: [String] = []
    func add(_ s: String) { all.append(s) }
}

/// Azure, faked: answers by the first registered fragment the URL contains, and keeps every request.
actor FakeAzure: AzureHTTP {
    struct Request: Sendable {
        var method: String
        var url: String
        var authorization: String
        var body: PluginValue?
    }
    private var routes: [(fragment: String, body: PluginValue, status: Int)] = []
    private(set) var requests: [Request] = []

    func on(_ fragment: String, _ body: PluginValue, status: Int = 200) { routes.append((fragment, body, status)) }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(PluginValue.self, from: $0) }
        requests.append(Request(method: request.httpMethod ?? "GET", url: url, authorization: request.value(forHTTPHeaderField: "Authorization") ?? "", body: body))
        let route = routes.first { url.contains($0.fragment) }
        let missing: PluginValue = ["error": ["code": "NotFound", "message": .string("no route for \(url)")]]
        let data = try JSONEncoder().encode(route?.body ?? missing)
        return (data, HTTPURLResponse(url: request.url!, statusCode: route?.status ?? 404, httpVersion: nil, headerFields: nil)!)
    }
}
