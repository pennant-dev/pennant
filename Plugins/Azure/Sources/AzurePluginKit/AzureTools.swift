import Foundation
import PennantPluginSDK

/// The Azure plugin's tools. Their descriptions and schemas are in `plugin.json`; this is what they do.
public enum AzureTools {
    public static func all(http: AzureHTTP = URLSessionHTTP()) -> [PluginTool] {
        let session = Session(http: http)
        return [
            PluginTool("subscriptions") { _, context in try await session.subscriptions(context) },
            PluginTool("resources") { args, context in try await session.resources(args, context) },
            PluginTool("costs") { args, context in try await session.costs(args, context) },
            PluginTool("clusters") { args, context in try await session.clusters(args, context) },
            PluginTool("logs") { args, context in try await session.logs(args, context) },
            PluginTool("alerts") { args, context in try await session.alerts(args, context) },
            PluginTool("scale_node_pool") { args, context in try await session.scaleNodePool(args, context) },
            PluginTool("restart_app") { args, context in try await session.restartApp(args, context) },
        ]
    }

    /// One sign-in and client for the plugin's life (tokens are kept between calls).
    actor Session {
        private let http: AzureHTTP
        private var client: AzureClient?
        private var names: [String: String]?

        init(http: AzureHTTP) { self.http = http }

        func client(_ context: PluginContext) -> AzureClient {
            if let client { return client }
            let made = AzureClient(auth: AzureAuth(context: context, http: http), http: http)
            client = made
            return made
        }

        /// The subscriptions in scope (settings), and every subscription's name by id for showing rows.
        func scope(_ context: PluginContext, only: String? = nil) async throws -> [AzureClient.Subscription] {
            let client = client(context)
            let named = only.map { [$0] } ?? (context.settings["subscriptions"]?.array?.compactMap(\.string) ?? [])
            let picked = try await client.scope(named)
            if names == nil {
                names = Dictionary(try await client.subscriptions().map { ($0.id.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
            }
            return picked
        }

        func subscriptionName(_ id: String?) -> String {
            guard let id else { return "" }
            return names?[id.lowercased()] ?? id
        }

        // MARK: Reading

        func subscriptions(_ context: PluginContext) async throws -> ToolOutput {
            let client = client(context)
            let all = try await client.subscriptions()
            let inScope = Set(try await scope(context).map(\.id))
            guard !all.isEmpty else { return .text("This sign-in sees no subscriptions.") }
            let rows = all.map { [$0.name, $0.id, $0.state, inScope.contains($0.id) ? "yes" : "no"] }
            return .text(Table.render(["name", "id", "state", "in scope"], rows))
        }

        func resources(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            let subs = try await scope(context, only: args["subscription"]?.string)
            let top = args["top"]?.int ?? 50
            let query: String
            if let raw = args["query"]?.string, !raw.isEmpty {
                query = raw
            } else {
                var q = "resources"
                if let type = args["type"]?.string, !type.isEmpty {
                    q += type.contains("/") ? " | where type =~ \(KQL.quote(type))" : " | where type contains \(KQL.quote(type))"
                }
                if let rg = args["resource_group"]?.string, !rg.isEmpty { q += " | where resourceGroup =~ \(KQL.quote(rg))" }
                if let name = args["name"]?.string, !name.isEmpty { q += " | where name contains \(KQL.quote(name))" }
                if let location = args["location"]?.string, !location.isEmpty { q += " | where location =~ \(KQL.quote(location))" }
                if let tag = args["tag"]?.string, !tag.isEmpty {
                    let parts = tag.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                    q += parts.count == 2 ? " | where tostring(tags[\(KQL.quote(parts[0]))]) =~ \(KQL.quote(parts[1]))" : " | where isnotempty(tags[\(KQL.quote(parts[0]))])"
                }
                q += " | project name, type, resourceGroup, location, subscriptionId | order by type asc, name asc"
                query = q
            }
            let result = try await client(context).graph(query, subscriptions: subs.map(\.id), top: top)
            guard !result.rows.isEmpty else { return .text("No resources match.") }
            var rows = result.rows
            for i in rows.indices {
                if let id = rows[i]["subscriptionId"]?.string { rows[i]["subscriptionId"] = .string(subscriptionName(id)) }
            }
            let shown = Table.render(rows: rows, rename: ["subscriptionId": "subscription"])
            let more = result.total > rows.count ? "\n\n\(rows.count) of \(result.total); narrow it down or raise top." : ""
            return .text(shown + more)
        }

        func costs(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            let subs = try await scope(context, only: args["subscription"]?.string)
            let dimension: String? = switch args["group_by"]?.string ?? "service" {
            case "none": nil
            case "resource_group": "ResourceGroupName"
            case "resource": "ResourceId"
            case "location": "ResourceLocation"
            case "meter": "MeterCategory"
            default: "ServiceName"
            }
            let lastMonth = args["last_month"]?.bool ?? false
            let client = client(context)
            var out: [String] = []
            var failures: [String] = []
            for sub in subs {
                do {
                    let lines = try await client.costs(subscription: sub.id, groupBy: dimension, lastMonth: lastMonth)
                    let total = lines.reduce(0) { $0 + $1.amount }
                    let currency = lines.first?.currency ?? ""
                    var section = "\(sub.name): \(Money.format(total, currency)) \(lastMonth ? "last month" : "this month so far")"
                    if dimension != nil, !lines.isEmpty {
                        let top = lines.prefix(12).map { ["  " + Self.shortName($0.name), Money.format($0.amount, $0.currency)] }
                        section += "\n" + top.map { $0.joined(separator: "  ") }.joined(separator: "\n")
                        if lines.count > 12 { section += "\n  … and \(lines.count - 12) more" }
                    }
                    out.append(section)
                } catch {
                    failures.append("\(sub.name): \(error)")
                }
            }
            if !failures.isEmpty { out.append("Couldn't read costs for " + failures.joined(separator: "; ")) }
            return out.isEmpty ? .error("No costs read.") : .text(out.joined(separator: "\n\n"))
        }

        /// A resource id shortened to its name.
        static func shortName(_ s: String) -> String {
            s.hasPrefix("/subscriptions/") ? String(s.split(separator: "/").last ?? Substring(s)) : s
        }

        func clusters(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            let subs = try await scope(context, only: args["subscription"]?.string)
            var q = "resources | where type =~ 'microsoft.containerservice/managedclusters'"
            if let name = args["name"]?.string, !name.isEmpty { q += " | where name contains \(KQL.quote(name))" }
            q += " | project name, resourceGroup, subscriptionId, location, version = tostring(properties.kubernetesVersion), power = tostring(properties.powerState.code), state = tostring(properties.provisioningState), pools = properties.agentPoolProfiles | order by name asc"
            let result = try await client(context).graph(q, subscriptions: subs.map(\.id))
            guard !result.rows.isEmpty else { return .text("No AKS clusters in scope.") }
            var out: [String] = []
            for c in result.rows {
                let name = c["name"]?.string ?? "?"
                var line = "\(name) (\(c["resourceGroup"]?.string ?? ""), \(subscriptionName(c["subscriptionId"]?.string)), \(c["location"]?.string ?? "")): Kubernetes \(c["version"]?.string ?? "?"), \(c["power"]?.string ?? "?"), \(c["state"]?.string ?? "?")"
                for p in c["pools"]?.array ?? [] {
                    let count = p["count"]?.int ?? 0
                    let scale = p["enableAutoScaling"]?.bool == true ? " (autoscale \(p["minCount"]?.int ?? 0)–\(p["maxCount"]?.int ?? 0))" : ""
                    line += "\n  pool \(p["name"]?.string ?? "?") [\(p["mode"]?.string ?? "")]: \(count) × \(p["vmSize"]?.string ?? "?")\(scale), \(p["powerState"]?["code"]?.string ?? "?"), \(p["provisioningState"]?.string ?? "?"), v\(p["orchestratorVersion"]?.string ?? "?")"
                }
                out.append(line)
            }
            return .text(out.joined(separator: "\n\n"))
        }

        func logs(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            guard let query = args["query"]?.string, !query.isEmpty else { return .error("logs needs a query (KQL).") }
            let workspace = args["workspace"]?.string ?? context.settings["workspace"]?.string ?? ""
            guard !workspace.isEmpty else { return .error("Name a workspace (its name or workspace id), or set the plugin's default workspace.") }
            let id = try await workspaceID(workspace, context)
            let timespan = Duration8601.parse(args["timespan"]?.string ?? "1h")
            let result = try await client(context).logs(workspaceID: id, query: query, timespan: timespan)
            guard !result.rows.isEmpty else { return .text("No rows.") }
            let cap = 100
            let rows = result.rows.prefix(cap).map { $0.map(Table.cell) }
            let more = result.rows.count > cap ? "\n\n\(cap) of \(result.rows.count) rows; summarize or take fewer in the query." : ""
            return .text(Table.render(result.columns, Array(rows)) + more)
        }

        /// A workspace id (GUID) as given, or the one a workspace by that name has.
        func workspaceID(_ workspace: String, _ context: PluginContext) async throws -> String {
            if workspace.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil { return workspace }
            let subs = try await scope(context)
            let q = "resources | where type =~ 'microsoft.operationalinsights/workspaces' and name =~ \(KQL.quote(workspace)) | project id = tostring(properties.customerId)"
            guard let id = try await client(context).graph(q, subscriptions: subs.map(\.id), top: 2).rows.first?["id"]?.string else {
                throw AzureError.invalid("No Log Analytics workspace named \(workspace) in scope.")
            }
            return id
        }

        func alerts(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            let subs = try await scope(context, only: args["subscription"]?.string)
            let hours = max(1, min(args["since_hours"]?.int ?? 24, 720))
            var q = """
            alertsmanagementresources | where type =~ 'microsoft.alertsmanagement/alerts' \
            | extend e = properties.essentials \
            | where tostring(e.monitorCondition) == 'Fired' and todatetime(e.startDateTime) > ago(\(hours)h)
            """
            if let severity = args["severity"]?.string, !severity.isEmpty { q += " | where tostring(e.severity) =~ \(KQL.quote(severity))" }
            q += " | project since = tostring(e.startDateTime), severity = tostring(e.severity), alert = name, target = tostring(e.targetResourceName), state = tostring(e.alertState), subscriptionId | order by since desc"
            let result = try await client(context).graph(q, subscriptions: subs.map(\.id), top: 100)
            guard !result.rows.isEmpty else { return .text("No alerts firing in the last \(hours) hours.") }
            var rows = result.rows
            for i in rows.indices {
                if let id = rows[i]["subscriptionId"]?.string { rows[i]["subscriptionId"] = .string(subscriptionName(id)) }
            }
            return .text("\(rows.count) firing:\n\n" + Table.render(rows: rows, rename: ["subscriptionId": "subscription"]))
        }

        // MARK: Changing things (each call waits on the owner's card)

        func scaleNodePool(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            guard let cluster = args["cluster"]?.string, let pool = args["pool"]?.string, let count = args["count"]?.int else {
                return .error("scale_node_pool needs cluster, pool and count.")
            }
            guard (0 ... 1000).contains(count) else { return .error("count must be between 0 and 1000.") }
            let place = try await locate(type: "microsoft.containerservice/managedclusters", name: cluster, args, context)
            return .text(try await client(context).scaleNodePool(subscription: place.subscription, resourceGroup: place.resourceGroup, cluster: place.name, pool: pool, count: count))
        }

        func restartApp(_ args: PluginValue, _ context: PluginContext) async throws -> ToolOutput {
            guard let app = args["app"]?.string, !app.isEmpty else { return .error("restart_app needs the app's name.") }
            let place = try await locate(type: "microsoft.web/sites", name: app, args, context)
            return .text(try await client(context).restartApp(subscription: place.subscription, resourceGroup: place.resourceGroup, app: place.name))
        }

        /// Where a resource is: from the arguments, or found by name across the subscriptions in scope (exactly one).
        func locate(type: String, name: String, _ args: PluginValue, _ context: PluginContext) async throws -> (subscription: String, resourceGroup: String, name: String) {
            if let rg = args["resource_group"]?.string, let sub = args["subscription"]?.string, !rg.isEmpty, !sub.isEmpty {
                let resolved = try await scope(context, only: sub)
                return (resolved.first?.id ?? sub, rg, name)
            }
            let subs = try await scope(context, only: args["subscription"]?.string)
            var q = "resources | where type =~ \(KQL.quote(type)) and name =~ \(KQL.quote(name))"
            if let rg = args["resource_group"]?.string, !rg.isEmpty { q += " and resourceGroup =~ \(KQL.quote(rg))" }
            q += " | project name, resourceGroup, subscriptionId"
            let rows = try await client(context).graph(q, subscriptions: subs.map(\.id), top: 5).rows
            guard let first = rows.first, let rg = first["resourceGroup"]?.string, let sub = first["subscriptionId"]?.string else {
                throw AzureError.invalid("No \(type.split(separator: "/").last ?? "resource") named \(name) in scope.")
            }
            guard rows.count == 1 else {
                let places = rows.map { "\($0["resourceGroup"]?.string ?? "?") in \(subscriptionName($0["subscriptionId"]?.string))" }
                throw AzureError.invalid("\(name) is in more than one place (\(places.joined(separator: "; "))); name the resource_group and subscription.")
            }
            return (sub, rg, first["name"]?.string ?? name)
        }
    }
}

/// KQL string literals.
enum KQL {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// "1h", "24h", "7d", "30m" or ISO 8601 as given, as ISO 8601 ("PT1H", "P7D").
enum Duration8601 {
    static func parse(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.uppercased().hasPrefix("P") { return t.uppercased() }
        guard let unit = t.last, let n = Int(t.dropLast()), n > 0 else { return "PT1H" }
        switch unit {
        case "m": return "PT\(n)M"
        case "h": return "PT\(n)H"
        case "d": return "P\(n)D"
        default: return "PT1H"
        }
    }
}

enum Money {
    static func format(_ amount: Double, _ currency: String) -> String {
        let n = String(format: "%.2f", amount)
        return currency.isEmpty ? n : "\(n) \(currency)"
    }
}

/// Plain-text tables the model reads easily.
enum Table {
    static func cell(_ v: PluginValue) -> String {
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(format: "%.4g", n)
        case .array, .object: return (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? ""
        }
    }

    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let clip = { (s: String) in
            let one = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
            return one.count > 90 ? String(one.prefix(89)) + "…" : one
        }
        var lines = ["| " + header.map(clip).joined(separator: " | ") + " |", "|" + header.map { _ in "---" }.joined(separator: "|") + "|"]
        lines += rows.map { "| " + $0.map(clip).joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    /// Rows of objects, in the order their first row names its columns.
    static func render(rows: [[String: PluginValue]], rename: [String: String] = [:]) -> String {
        var columns: [String] = []
        for row in rows { for key in row.keys.sorted() where !columns.contains(key) { columns.append(key) } }
        // A sensible order: name first, then the rest as they came.
        columns.sort { a, b in
            let rank = { (k: String) in ["name", "since", "severity", "alert", "type", "target", "resourceGroup", "location"].firstIndex(of: k) ?? 99 }
            return rank(a) == rank(b) ? false : rank(a) < rank(b)
        }
        return render(columns.map { rename[$0] ?? $0 }, rows.map { row in columns.map { row[$0].map(cell) ?? "" } })
    }
}
