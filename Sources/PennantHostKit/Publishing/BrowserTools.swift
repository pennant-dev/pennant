import PennantCore
import Foundation

/// HTML → PNG with a headless browser: social cards, carousel slides, charts drawn in HTML.
public struct RenderHTMLTool: Tool {
    let browser: BrowserRunner
    public init(browser: BrowserRunner) { self.browser = browser }

    public var spec: ToolSpec {
        ToolSpec(
            name: "render_html",
            description: "Render HTML (a string or an .html file) to a PNG image at an exact size with a headless browser. Web fonts and CSS work. Use it for social images, carousel slides and cards; check the PNG with read_file or by looking at it before using it.",
            inputSchema: JSONSchema.object([
                "html": JSONSchema.string("The HTML document, when not using html_file."),
                "html_file": JSONSchema.string("Absolute path of an .html file (relative assets resolve next to it)."),
                "output": JSONSchema.string("Absolute path of the PNG to write."),
                "width": JSONSchema.integer("Width in CSS pixels (default 1080)."),
                "height": JSONSchema.integer("Height in CSS pixels (default 1350)."),
                "scale": JSONSchema.integer("Device pixel ratio (default 1; 2 for a sharper, larger image)."),
            ], required: ["output"]),
            isConsequential: false,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let output = (try arguments.requireString("output") as NSString).expandingTildeInPath
        var input: [String: Any] = ["out": output, "width": arguments.int("width") ?? 1080, "height": arguments.int("height") ?? 1350, "scale": arguments.int("scale") ?? 1]
        if let file = arguments.string("html_file") { input["htmlFile"] = (file as NSString).expandingTildeInPath }
        else if let html = arguments.string("html") { input["html"] = html }
        else { throw ToolError.invalidArguments("Give html or html_file") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
        let reply = try await browser.run(script: "render", source: BrowserScripts.render, input: try JSONSerialization.data(withJSONObject: input), timeout: 120)
        let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        guard result["ok"] as? Bool == true else { throw ToolError.failed("Render failed: \(result["error"] as? String ?? "unknown error")") }
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        return .text(ToolCallID("pending"), name: spec.name, "Wrote \(output) (\(size) bytes).")
    }
}

/// Runs a Playwright script (an ES module, usually from a skill's scripts folder) in Pennant's dedicated browser
/// profile, where the user signs in to sites once. With an approval id, the script receives only the approved
/// content as `input.approved` and runs only if the user approved it; a `url` in its result is recorded on the
/// approval as where the content went live.
public struct BrowserScriptTool: Tool {
    let browser: BrowserRunner
    let screenshots: URL
    let vault: VaultService?
    public init(browser: BrowserRunner, screenshots: URL, vault: VaultService? = nil) {
        self.browser = browser
        self.screenshots = screenshots
        self.vault = vault
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "browser_script",
            description: """
            Run a Playwright script (a .mjs ES module, typically in a skill's scripts folder) in Pennant's own browser profile, which keeps the user's sign-ins for sites between runs. The script gets its input as JSON on stdin with `profile` (the user-data dir to pass to chromium.launchPersistentContext) and `screenshotDir`, and must print one JSON object as its last stdout line. `import { chromium } from 'playwright'` works without installing anything. To publish something the user approved, pass approval_id: the script then receives `input.approved` = {id, title, destination, text, images: [absolute paths], headline?, video? (absolute path)} and runs only when the approval was granted; return {"url": ...} and it is recorded on the approval. To sign in without the user, pass vault: ["linkedin"] (names from vault_list): the script receives `input.vault.linkedin` = {username, password, totp, secret, url}. You never see those values, and they are redacted from the result.
            """,
            inputSchema: JSONSchema.object([
                "script": JSONSchema.string("Absolute path of the .mjs script."),
                "input": .object(["type": "object", "description": "Extra input for the script (merged into stdin JSON)."]),
                "approval_id": JSONSchema.string("An approved request_approval id whose content the script publishes."),
                "vault": .object(["type": "array", "items": .object(["type": "string"]), "description": "Vault entry names whose sign-in details the script receives as input.vault.<name>."]),
                "timeout_seconds": JSONSchema.integer("How long the script may run (default 600, for a sign-in the user may need to complete)."),
            ], required: ["script"]),
            isConsequential: true,
            needsDesktop: false
        )
    }

    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = (try arguments.requireString("script") as NSString).expandingTildeInPath
        var input: [String: Any] = [:]
        if case .object(let extra)? = arguments["input"], let data = try? JSONEncoder().encode(JSONValue.object(extra)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { input = object }
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        input["screenshotDir"] = screenshots.path

        var approvalID: String?
        if let id = arguments.string("approval_id") {
            guard let hooks = context.runtimeHooks, let approval = try await hooks.approval(id) else { throw ToolError.failed("No approval with id \(id).") }
            guard approval.state == .approved else { throw ToolError.failed("Approval \(id) is \(approval.state.rawValue), not approved. Nothing was run.") }
            guard approval.publishedURL == nil else { throw ToolError.failed("Approval \(id) was already published at \(approval.publishedURL ?? ""). Publishing twice needs a new approval.") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pennant-approved-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var images: [String] = []
            for (i, ref) in approval.images.enumerated() {
                guard let data = try await context.store.artifactData(ref.artifactID) else { continue }
                let file = folder.appendingPathComponent(String(format: "%02d.%@", i + 1, ref.mimeType == "image/png" ? "png" : "jpg"))
                try data.write(to: file)
                images.append(file.path)
            }
            var approved: [String: Any] = ["id": approval.id, "title": approval.title, "destination": approval.destination, "text": approval.finalText, "images": images]
            if let headline = approval.headline { approved["headline"] = headline }
            approved["tags"] = approval.tags
            approved["details"] = Dictionary(approval.details.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
            if let video = approval.video {
                guard FileManager.default.fileExists(atPath: video.sourcePath) else { throw ToolError.failed("The approved video \(video.sourcePath) is gone. Nothing was run.") }
                guard try VideoPreview.sha256(of: URL(fileURLWithPath: video.sourcePath)) == video.sha256 else {
                    throw ToolError.failed("The video at \(video.sourcePath) changed after it was approved. Nothing was run; put the new version up for approval.")
                }
                approved["video"] = video.sourcePath
            }
            input["approved"] = approved
            approvalID = id
        }

        var redact: [String] = []
        var missingVault: [String] = []
        if let wanted = arguments.stringArray("vault"), !wanted.isEmpty, let vault {
            let resolved = await vault.resolve(wanted)
            input["vault"] = resolved.entries
            redact = resolved.secrets
            missingVault = resolved.missing
        }
        let reply = try await browser.run(file: URL(fileURLWithPath: path), input: try JSONSerialization.data(withJSONObject: input), timeout: TimeInterval(arguments.int("timeout_seconds") ?? 600), redact: redact)
        let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if let approvalID, let url = result["url"] as? String, !url.isEmpty, let hooks = context.runtimeHooks {
            try await hooks.markPublished(approvalID, url)
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if !missingVault.isEmpty {
            text += "\n\nThe vault has no entry named \(missingVault.joined(separator: ", ")); the script ran without it. The user can add it in Pennant's Vault so the next run signs in by itself."
        }
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}
