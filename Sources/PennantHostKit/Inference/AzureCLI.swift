import PennantCore
import Foundation

/// Azure AI Foundry through the Azure CLI on the host: who is signed in, the subscriptions, AI resources and model
/// deployments to pick from, `az login`, and the command that mints Entra ID tokens for inference. Nothing here
/// stores Azure credentials; the CLI keeps its own sign-in, so moving to another Mac means installing the CLI
/// (`brew install azure-cli`) and signing in there.
public enum AzureCLI {
    /// Where `az` lives: PATH first, then the Homebrew locations (a GUI-launched host has a short PATH).
    public static func executable() -> String? {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/az" }
            + ["/opt/homebrew/bin/az", "/usr/local/bin/az", NSHomeDirectory() + "/.local/bin/az"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The shell command CommandTokenAuthority runs for an Entra ID token scoped to Azure AI services.
    public static func tokenCommand(subscription: String?) -> String {
        let az = executable().map { "'\($0)'" } ?? "az"
        let sub = subscription.map { " --subscription '\($0)'" } ?? ""
        return "\(az) account get-access-token --resource https://cognitiveservices.azure.com\(sub) --query accessToken -o tsv"
    }

    static func run(_ args: [String], timeout: TimeInterval = 60) async throws -> Any {
        guard let az = executable() else { throw HostCommandError.invalid("The Azure CLI isn't installed on the host. Install it with `brew install azure-cli`, then sign in.") }
        let r = try await BrowserRunner.run(executable: az, arguments: args + ["-o", "json", "--only-show-errors"], cwd: FileManager.default.homeDirectoryForCurrentUser, stdin: nil, timeout: timeout)
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("az login") || err.contains("Please run 'az login'") { throw HostCommandError.invalid("The Azure CLI isn't signed in on the host. Use Sign in.") }
            throw HostCommandError.invalid("Azure CLI: \(err.suffix(400))")
        }
        return (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) ?? [:]
    }

    public static func status() async -> AzureStatus {
        guard let az = executable() else { return AzureStatus(installed: false) }
        guard let json = try? await run(["account", "show"], timeout: 30) as? [String: Any] else { return AzureStatus(installed: true, cliPath: az) }
        let user = (json["user"] as? [String: Any])?["name"] as? String
        return AzureStatus(installed: true, cliPath: az, signedIn: true, user: user, subscriptionID: json["id"] as? String, subscriptionName: json["name"] as? String, tenantID: json["tenantId"] as? String)
    }

    public static func subscriptions() async throws -> [AzureSubscription] {
        let list = try await run(["account", "list"]) as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            return AzureSubscription(id: id, name: s["name"] as? String ?? id, isDefault: s["isDefault"] as? Bool ?? false)
        }
    }

    /// AI resources (Foundry / Azure OpenAI) in a subscription.
    public static func resources(subscription: String) async throws -> [AzureResource] {
        let list = try await run(["cognitiveservices", "account", "list", "--subscription", subscription], timeout: 90) as? [[String: Any]] ?? []
        return list.compactMap { r in
            guard let name = r["name"] as? String, let group = r["resourceGroup"] as? String else { return nil }
            let kind = r["kind"] as? String ?? ""
            guard ["AIServices", "OpenAI"].contains(kind) else { return nil }
            let props = r["properties"] as? [String: Any] ?? [:]
            return AzureResource(name: name, resourceGroup: group, subscriptionID: subscription, kind: kind, location: r["location"] as? String ?? "",
                                 endpoint: props["endpoint"] as? String ?? "https://\(name).cognitiveservices.azure.com/",
                                 publicNetworkAccess: (props["publicNetworkAccess"] as? String ?? "Enabled") != "Disabled",
                                 keysDisabled: props["disableLocalAuth"] as? Bool ?? false)
        }
    }

    public static func deployments(subscription: String, resourceGroup: String, resource: String) async throws -> [AzureDeployment] {
        let list = try await run(["cognitiveservices", "account", "deployment", "list", "--subscription", subscription, "-g", resourceGroup, "-n", resource], timeout: 90) as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            let model = (d["properties"] as? [String: Any])?["model"] as? [String: Any] ?? [:]
            return AzureDeployment(name: name, model: model["name"] as? String ?? name, version: model["version"] as? String ?? "", format: model["format"] as? String ?? "")
        }
    }

    /// `az login` on the host: it opens the browser there and returns once the sign-in completes (up to 5 min).
    public static func login() async throws -> AzureStatus {
        guard let az = executable() else { throw HostCommandError.invalid("The Azure CLI isn't installed on the host. Install it with `brew install azure-cli`.") }
        let r = try await BrowserRunner.run(executable: az, arguments: ["login", "--only-show-errors", "-o", "none"], cwd: FileManager.default.homeDirectoryForCurrentUser, stdin: nil, timeout: 300)
        guard r.status == 0 else { throw HostCommandError.invalid("az login didn't finish: \(r.stderr.suffix(300))") }
        return await status()
    }

}

/// Fixed extra headers instead of a bearer token (Azure keys go in `api-key`).
public struct StaticHeaderAuthority: EndpointAuthority {
    let baseURL: String
    let headers: [String: String]
    public init(baseURL: String, headers: [String: String]) {
        self.baseURL = baseURL
        self.headers = headers
    }
    public func credential() async throws -> EndpointCredential { EndpointCredential(bearer: "", baseURL: baseURL, headers: headers) }
    public func refreshCredential(rejected: EndpointCredential) async throws -> EndpointCredential { rejected }
    public func shouldRetry(status: Int, body: String, attempt: Int) -> Bool { false }
}
