import PennantCore
import Foundation

/// Finds the user's uploaded brand files (logos, fonts, templates, photos) and the written guidance for each
/// collection, so generated content uses the real assets instead of an imitation.
public struct FindAssetsTool: Tool {
    let library: LibraryService
    public init(library: LibraryService) { self.library = library }

    public var spec: ToolSpec {
        ToolSpec(
            name: "find_assets",
            description: "List the brand assets the user uploaded to Pennant's Library (logos, fonts, colour sheets, templates, photos), with each collection's usage guidance and each file's absolute path. Use these files as they are (reference them from HTML by file:// path or copy them) whenever you make images, slides or documents for the user's company. With no arguments it lists everything.",
            inputSchema: JSONSchema.object([
                "query": JSONSchema.string("Words to match in names, notes or file names, like \"logo dark\"."),
                "collection": JSONSchema.string("Only this collection, like \"Acme brand\"."),
            ], required: []),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let index = await library.index()
        let text = Self.describe(index, query: arguments.string("query"), collection: arguments.string("collection"))
        return .text(ToolCallID("pending"), name: spec.name, text)
    }

    static func describe(_ index: LibraryIndex, query: String?, collection: String?) -> String {
        guard !index.assets.isEmpty || !index.collections.isEmpty else {
            return "The Library is empty. Ask the user to upload their logo and brand files in Pennant's Library, and meanwhile keep the design plain rather than inventing a logo."
        }
        let words = (query ?? "").lowercased().split(separator: " ").map(String.init)
        var lines: [String] = []
        for c in index.collections where collection.map({ $0.caseInsensitiveCompare(c.name) == .orderedSame }) ?? true {
            let assets = index.assets.filter { a in
                a.collection == c.name && words.allSatisfy { w in "\(a.name) \(a.notes) \(a.fileName)".lowercased().contains(w) }
            }
            if !words.isEmpty && assets.isEmpty { continue }
            lines.append("## \(c.name)")
            if !c.notes.isEmpty { lines.append("Guidance: \(c.notes)") }
            for a in assets {
                var line = "- \(a.name): \(a.path) (\(a.mimeType)"
                if let w = a.width, let h = a.height { line += ", \(w)×\(h)" }
                line += ")"
                if !a.notes.isEmpty { line += ". \(a.notes)" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.isEmpty ? "No assets match. Call find_assets with no arguments to see everything." : lines.joined(separator: "\n")
    }
}

/// The vault's entry names (never the secrets), so an agent knows which sign-ins a script can use.
public struct VaultListTool: Tool {
    let vault: VaultService
    public init(vault: VaultService) { self.vault = vault }

    public var spec: ToolSpec {
        ToolSpec(
            name: "vault_list",
            description: "List the sign-ins and secrets the user saved in Pennant's Vault: names, sites and usernames only, never the passwords. Pass a name to browser_script's vault parameter and the script receives the details itself.",
            inputSchema: JSONSchema.object([:], required: []),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let items = await vault.items()
        guard !items.isEmpty else {
            return .text(ToolCallID("pending"), name: spec.name, "The Vault is empty. The user can add sign-ins in Pennant's Vault section.")
        }
        let lines = items.map { item in
            var parts = ["\(item.name) (\(item.kind.rawValue))"]
            if let url = item.url, !url.isEmpty { parts.append(url) }
            if let user = item.username, !user.isEmpty { parts.append("user \(user)") }
            var has: [String] = []
            if item.hasPassword { has.append("password") }
            if item.hasTOTP { has.append("authenticator code") }
            if item.hasSecret { has.append("secret") }
            if !has.isEmpty { parts.append("has " + has.joined(separator: ", ")) }
            if !item.notes.isEmpty { parts.append(item.notes) }
            return "- " + parts.joined(separator: " · ")
        }
        return .text(ToolCallID("pending"), name: spec.name, lines.joined(separator: "\n"))
    }
}
