import Foundation
import PennantPluginSDK

/// Azure's REST APIs, read through one sign-in: Resource Graph for anything across subscriptions, Cost Management,
/// Log Analytics, and the two actions (scale an AKS node pool, restart an App Service app).
public actor AzureClient {
    static let arm = "https://management.azure.com"

    private let auth: AzureAuth
    private let http: AzureHTTP

    public init(auth: AzureAuth, http: AzureHTTP) {
        self.auth = auth
        self.http = http
    }

    // MARK: Requests

    func call(_ method: String, _ url: String, body: PluginValue? = nil, audience: AzureAudience = .management) async throws -> PluginValue {
        guard let address = URL(string: url) else { throw AzureError.invalid("Bad address: \(url)") }
        var request = URLRequest(url: address, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.token(audience))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        var attempt = 0
        while true {
            let (data, response) = try await http.send(request)
            // Cost Management throttles hard; wait as long as it asks, a few times.
            if response.statusCode == 429, attempt < 3 {
                attempt += 1
                let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(5 * attempt)
                try await Task.sleep(for: .seconds(min(wait, 30)))
                continue
            }
            let json = data.isEmpty ? PluginValue.null : ((try? JSONDecoder().decode(PluginValue.self, from: data)) ?? .string(String(decoding: data, as: UTF8.self)))
            guard (200 ..< 300).contains(response.statusCode) else {
                let error = json["error"]
                throw AzureError.azure(status: response.statusCode, code: error?["code"]?.string ?? "",
                                       message: error?["message"]?.string ?? json.string.map { String($0.prefix(300)) } ?? "HTTP \(response.statusCode)")
            }
            return json
        }
    }

    // MARK: Subscriptions

    public struct Subscription: Sendable, Equatable {
        public var id: String
        public var name: String
        public var state: String
    }

    public func subscriptions() async throws -> [Subscription] {
        let json = try await call("GET", "\(Self.arm)/subscriptions?api-version=2022-12-01")
        return (json["value"]?.array ?? []).compactMap { s in
            guard let id = s["subscriptionId"]?.string else { return nil }
            return Subscription(id: id, name: s["displayName"]?.string ?? id, state: s["state"]?.string ?? "")
        }
    }

    /// The subscriptions to look in: the ones named in settings (by id or name), or every enabled one the sign-in sees.
    public func scope(_ named: [String]) async throws -> [Subscription] {
        let all = try await subscriptions().filter { $0.state.isEmpty || $0.state == "Enabled" }
        guard !named.isEmpty else { return all }
        let wanted = Set(named.map { $0.lowercased() })
        let picked = all.filter { wanted.contains($0.id.lowercased()) || wanted.contains($0.name.lowercased()) }
        guard !picked.isEmpty else {
            throw AzureError.invalid("None of \(named.joined(separator: ", ")) is a subscription this sign-in can see. It sees: \(all.map(\.name).joined(separator: ", ")).")
        }
        return picked
    }

    // MARK: Resource Graph

    /// A Resource Graph query (KQL) across subscriptions: rows as objects, up to `top`.
    public func graph(_ query: String, subscriptions: [String], top: Int = 200) async throws -> (rows: [[String: PluginValue]], total: Int) {
        let body: PluginValue = ["subscriptions": .array(subscriptions.map { .string($0) }), "query": .string(query),
                                 "options": ["$top": .number(Double(min(max(top, 1), 1000))), "resultFormat": "objectArray"]]
        let json = try await call("POST", "\(Self.arm)/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01", body: body)
        let rows = (json["data"]?.array ?? []).compactMap(\.object)
        return (rows, json["totalRecords"]?.int ?? rows.count)
    }

    // MARK: Costs

    public struct CostLine: Sendable, Equatable {
        public var name: String
        public var amount: Double
        public var currency: String
    }

    /// Month-to-date (or last month's) actual cost for a subscription, grouped by a dimension.
    public func costs(subscription: String, groupBy: String?, lastMonth: Bool) async throws -> [CostLine] {
        var dataset: [String: PluginValue] = ["granularity": "None", "aggregation": ["totalCost": ["name": "Cost", "function": "Sum"]]]
        if let groupBy { dataset["grouping"] = [["type": "Dimension", "name": .string(groupBy)]] }
        let body: PluginValue = ["type": "ActualCost", "timeframe": lastMonth ? "TheLastMonth" : "MonthToDate", "dataset": .object(dataset)]
        let json = try await call("POST", "\(Self.arm)/subscriptions/\(subscription)/providers/Microsoft.CostManagement/query?api-version=2023-11-01", body: body)
        return Self.costLines(json, groupBy: groupBy)
    }

    static func costLines(_ json: PluginValue, groupBy: String?) -> [CostLine] {
        let columns = (json["properties"]?["columns"]?.array ?? []).map { $0["name"]?.string ?? "" }
        let cost = columns.firstIndex { $0 == "Cost" || $0 == "PreTaxCost" || $0 == "CostUSD" }
        let currency = columns.firstIndex(of: "Currency")
        let group = groupBy.flatMap { g in columns.firstIndex { $0.caseInsensitiveCompare(g) == .orderedSame } }
        return (json["properties"]?["rows"]?.array ?? []).compactMap { row -> CostLine? in
            guard let cells = row.array, let cost, cost < cells.count, let amount = cells[cost].number else { return nil }
            let name = group.flatMap { $0 < cells.count ? cells[$0].string : nil } ?? "Total"
            return CostLine(name: name.isEmpty ? "(none)" : name, amount: amount, currency: currency.flatMap { $0 < cells.count ? cells[$0].string : nil } ?? "")
        }.sorted { $0.amount > $1.amount }
    }

    // MARK: Logs

    /// A KQL query against a Log Analytics workspace (its workspace id, the GUID), over `timespan` (ISO 8601, "PT1H").
    public func logs(workspaceID: String, query: String, timespan: String) async throws -> (columns: [String], rows: [[PluginValue]]) {
        let json = try await call("POST", "https://api.loganalytics.io/v1/workspaces/\(workspaceID)/query",
                                  body: ["query": .string(query), "timespan": .string(timespan)], audience: .logs)
        guard let table = json["tables"]?.array?.first else { return ([], []) }
        return ((table["columns"]?.array ?? []).map { $0["name"]?.string ?? "" }, (table["rows"]?.array ?? []).compactMap(\.array))
    }

    // MARK: Actions

    static let aksAPI = "2024-09-01"
    static let webAPI = "2023-12-01"

    /// Sets a node pool's node count. Refused for a pool the autoscaler runs.
    public func scaleNodePool(subscription: String, resourceGroup: String, cluster: String, pool: String, count: Int) async throws -> String {
        let url = "\(Self.arm)/subscriptions/\(subscription)/resourceGroups/\(resourceGroup)/providers/Microsoft.ContainerService/managedClusters/\(cluster)/agentPools/\(pool)?api-version=\(Self.aksAPI)"
        let current = try await call("GET", url)
        guard var properties = current["properties"]?.object else { throw AzureError.invalid("Azure returned no properties for node pool \(pool).") }
        if properties["enableAutoScaling"]?.bool == true {
            throw AzureError.invalid("Node pool \(pool) is autoscaled (\(properties["minCount"]?.int ?? 0)–\(properties["maxCount"]?.int ?? 0) nodes); change its limits instead of its count.")
        }
        let before = properties["count"]?.int ?? 0
        properties["count"] = .number(Double(count))
        // Read-only fields Azure rejects on the way back in.
        for key in ["provisioningState", "powerState", "currentOrchestratorVersion", "nodeImageVersion", "eTag"] { properties[key] = nil }
        let updated = try await call("PUT", url, body: ["properties": .object(properties)])
        let state = updated["properties"]?["provisioningState"]?.string ?? "accepted"
        return "Node pool \(pool) in \(cluster): \(before) → \(count) nodes (\(state)). It takes a few minutes; check with clusters."
    }

    public func restartApp(subscription: String, resourceGroup: String, app: String) async throws -> String {
        _ = try await call("POST", "\(Self.arm)/subscriptions/\(subscription)/resourceGroups/\(resourceGroup)/providers/Microsoft.Web/sites/\(app)/restart?api-version=\(Self.webAPI)")
        return "Restarting \(app) in \(resourceGroup). It's usually back within a minute."
    }
}
