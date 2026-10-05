import PennantCore
import Foundation
import ImageIO

/// Runs a shell command with a timeout and output cap. Used by the shell tool and skills' scripts.
public enum ShellRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    /// Pennant Voice, the speech engine inside Pennant.app (`speak` and `transcribe`; see Apps/PennantVoice), next to
    /// the host's own helper app: skills that make narration find it in $PENNANT_VOICE.
    static let voiceHelper: String? = VoiceService.bundledExecutable?.path

    public static func run(_ command: String, workingDirectory: String, environment: [String: String] = [:], timeout: TimeInterval = 120, maxOutputBytes: Int = 200_000) async throws -> Result {
        let process = Process()
        // The command runs in a process group of its own (perl's setpgrp, then exec zsh), so a timeout or a
        // cancelled task stops everything it started (node, browsers, renderers), not only the shell.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die $!", "/bin/zsh", "-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        env["TERM"] = "dumb"
        if let voice = voiceHelper { env["PENNANT_VOICE"] = voice }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(limit: maxOutputBytes)
        out.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: 0) }
        err.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stream: 1) }

        try process.run()
        let timedOut = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let done = Locked(false)
                process.terminationHandler = { _ in
                    if !done.swap(true) { c.resume(returning: false) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        stopGroup(process.processIdentifier)
                        if !done.swap(true) { c.resume(returning: true) }
                    }
                }
            }
        } onCancel: {
            stopGroup(process.processIdentifier)
        }
        if timedOut || Task.isCancelled {
            // Give the group its SIGTERM grace period plus the SIGKILL, then report what was collected. The final
            // read is skipped: a browser that outlived its parent could hold the pipe open indefinitely.
            for _ in 0 ..< 50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return Result(exitCode: process.isRunning ? -9 : process.terminationStatus, stdout: collector.text(0), stderr: collector.text(1), timedOut: timedOut)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collector.append(out.fileHandleForReading.readDataToEndOfFile(), stream: 0)
        collector.append(err.fileHandleForReading.readDataToEndOfFile(), stream: 1)
        return Result(exitCode: process.terminationStatus, stdout: collector.text(0), stderr: collector.text(1), timedOut: timedOut)
    }

    /// SIGTERM to the whole group first (Playwright and Remotion close their browsers on it), SIGKILL to
    /// whatever is left three seconds later.
    static func stopGroup(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private var buffers = [Data(), Data()]
        private var truncated = [false, false]
        private let limit: Int
        private let lock = NSLock()
        init(limit: Int) { self.limit = limit }
        func append(_ data: Data, stream: Int) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if buffers[stream].count < limit { buffers[stream].append(data.prefix(limit - buffers[stream].count)) } else { truncated[stream] = true }
        }
        func text(_ stream: Int) -> String {
            lock.lock(); defer { lock.unlock() }
            var s = String(decoding: buffers[stream], as: UTF8.self)
            if truncated[stream] { s += "\n…[output truncated]" }
            return s
        }
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult func swap(_ v: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}

// MARK: - Shell

public struct ShellTool: Tool {
    let vault: VaultService?
    public init(vault: VaultService? = nil) { self.vault = vault }
    public var spec: ToolSpec {
        ToolSpec(
            name: "shell",
            description: "Run a zsh command on the Mac and return its output. Use for file operations, scripts, CLI tools, and inspecting results. Commands run as the logged-in user. Prefer this over GUI automation when a command can do the job.",
            inputSchema: JSONSchema.object([
                "command": JSONSchema.string("The command line to run with `zsh -lc`."),
                "working_directory": JSONSchema.string("Directory to run in. Defaults to the working directory (a coding run's project folder)."),
                "timeout_seconds": JSONSchema.integer("Maximum seconds to wait (default 120, max 600)."),
                "vault": .object(["type": "array", "items": .object(["type": "string"]), "description": "Vault entry names (from vault_list) the command needs, e.g. [\"cloudflare\"]. Each becomes environment variables PENNANT_VAULT_<NAME>_SECRET, _PASSWORD, _USERNAME, _TOTP, _URL (name upper-cased, other characters as _). You never see the values; they are blanked out of the output."]),
            ], required: ["command"]),
            isConsequential: true
        )
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let command = try arguments.requireString("command")
        let cwd = arguments.string("working_directory").map { PathResolver.resolve($0, base: context.workingDirectory) } ?? context.workingDirectory
        let timeout = min(Double(arguments.int("timeout_seconds") ?? 120), 600)
        // A coding run's commands act as its GitHub identity; the token never shows in the output.
        var environment = context.project?.environment ?? [:]
        var secrets = [environment["GH_TOKEN"]].compactMap { $0 }
        var missing: [String] = []
        if let wanted = arguments.stringArray("vault"), !wanted.isEmpty, let vault {
            let resolved = await vault.resolve(wanted)
            environment.merge(Self.environment(for: resolved.entries)) { _, entry in entry }
            secrets += resolved.secrets
            missing = resolved.missing
        }
        let result = try await ShellRunner.run(command, workingDirectory: cwd, environment: environment, timeout: timeout)
        var text = ""
        if !result.stdout.isEmpty { text += result.stdout }
        if !result.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr }
        if result.timedOut { text += "\n[timed out after \(Int(timeout)) s]" }
        text += "\n[exit code \(result.exitCode)]"
        text = Self.redact(text, secrets)
        if !missing.isEmpty { text += "\n[the vault has no entry named \(missing.joined(separator: ", ")); the user can add it in Pennant's Vault]" }
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text(text)], isError: result.exitCode != 0 || result.timedOut)
    }

    /// {"cloudflare": {"secret": …}} → PENNANT_VAULT_CLOUDFLARE_SECRET=….
    static func environment(for entries: [String: [String: String]]) -> [String: String] {
        var env: [String: String] = [:]
        for (name, fields) in entries {
            let key = String(name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
            for (field, value) in fields {
                env["PENNANT_VAULT_\(key)_\(field.uppercased())"] = value
            }
        }
        return env
    }

    /// Secret values (8 characters or more, so short common strings survive) replaced in the output.
    static func redact(_ text: String, _ secrets: [String]) -> String {
        secrets.filter { $0.count >= 8 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}

// MARK: - Files

public struct ReadFileTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "read_file", description: "Read a UTF-8 text file (optionally a line range), or look at an image file (PNG, JPEG, GIF, WebP, HEIC): images come back as images you can see, for checking rendered slides, charts or screenshots. Large text files are truncated; use offset/limit to page.", inputSchema: JSONSchema.object([
            "path": JSONSchema.string("Absolute path, or relative to the working directory. `~` is expanded."),
            "offset": JSONSchema.integer("First line to return (1-based). Default 1."),
            "limit": JSONSchema.integer("Maximum lines to return. Default 400."),
        ], required: ["path"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = PathResolver.resolve(try arguments.requireString("path"), base: context.workingDirectory)
        guard let data = FileManager.default.contents(atPath: path) else { throw ToolError.failed("Cannot read \(path)") }
        if Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return try await Self.imageResult(data, path: path, context: context, name: spec.name)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let offset = max(1, arguments.int("offset") ?? 1)
        let limit = max(1, min(arguments.int("limit") ?? 400, 2000))
        let slice = lines.dropFirst(offset - 1).prefix(limit)
        var out = slice.enumerated().map { "\(offset + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        if offset - 1 + limit < lines.count { out += "\n…[\(lines.count - (offset - 1 + limit)) more lines]" }
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text(out)])
    }
}

extension ReadFileTool {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    /// An image file as something the model can see: scaled to at most 1280 px on the long side, stored as an
    /// artifact, and returned as an image part with its original size.
    static func imageResult(_ data: Data, path: String, context: ToolContext, name: String) async throws -> ToolResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ToolError.failed("\(path) is not an image this Mac can decode")
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
        ] as CFDictionary) else { throw ToolError.failed("Could not decode \(path)") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { throw ToolError.failed("Could not encode \(path)") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError.failed("Could not encode \(path)") }
        let jpeg = out as Data
        let fileName = (path as NSString).lastPathComponent
        let record = ArtifactRecord(kind: "image-view", mimeType: "image/jpeg", byteCount: jpeg.count, fileName: fileName, taskID: context.taskID, agentID: context.agentID, caption: path)
        try await context.store.putArtifact(record, data: jpeg)
        let ref = ImageRef(artifactID: record.id, mimeType: "image/jpeg", width: image.width, height: image.height, caption: "\(fileName) (\(width)×\(height))")
        return ToolResult(callID: ToolCallID("pending"), name: name, content: [.text("\(path): \(width)×\(height) image, shown below."), .image(ref)])
    }
}

public struct WriteFileTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "write_file", description: "Create or overwrite a UTF-8 text file. Parent directories are created. To change part of an existing file, use edit_file.", inputSchema: JSONSchema.object([
            "path": JSONSchema.string("Absolute path, or relative to the working directory."),
            "content": JSONSchema.string("Full file content."),
        ], required: ["path", "content"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = try context.writablePath(try arguments.requireString("path"))
        let content = arguments.string("content") ?? ""
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return .text(ToolCallID("pending"), name: spec.name, "Wrote \(content.utf8.count) bytes to \(path)")
    }
}

/// Changes one exact piece of a file: safer than rewriting the file, and the change is easy to read back.
public struct EditFileTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "edit_file", description: "Replace one exact piece of text in a UTF-8 file. old_text must appear exactly once, whitespace included (copy it from read_file without the line numbers, with enough surrounding lines to be unique); nothing changes when it's missing or appears more than once. Use write_file to create a file.", inputSchema: JSONSchema.object([
            "path": JSONSchema.string("Absolute path, or relative to the working directory."),
            "old_text": JSONSchema.string("The exact text to replace."),
            "new_text": JSONSchema.string("What replaces it (empty removes it)."),
        ], required: ["path", "old_text", "new_text"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = try context.writablePath(try arguments.requireString("path"))
        let old = try arguments.requireString("old_text")
        let new = arguments.string("new_text") ?? ""
        guard let data = FileManager.default.contents(atPath: path) else { throw ToolError.failed("There's no file at \(path); create it with write_file.") }
        let text = String(decoding: data, as: UTF8.self)
        let found = Self.ranges(of: old, in: text)
        guard let range = found.first else {
            throw ToolError.failed("old_text isn't in \(path). Read the file again and copy the text exactly, whitespace included.")
        }
        guard found.count == 1 else {
            throw ToolError.failed("old_text appears \(found.count) times in \(path). Include more of the surrounding lines so it matches once.")
        }
        try Data(text.replacingCharacters(in: range, with: new).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        let line = text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return .text(ToolCallID("pending"), name: spec.name, "Edited \(path) at line \(line): \(Self.lines(old)) line(s) replaced with \(Self.lines(new)).")
    }

    /// Every place `needle` appears, compared character by character (no Unicode folding), without overlaps.
    static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    private static func lines(_ s: String) -> Int { s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count }
}

public struct ListDirectoryTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "list_directory", description: "List a directory's entries with sizes and modification dates.", inputSchema: JSONSchema.object([
            "path": JSONSchema.string("Directory path. Defaults to the working directory."),
        ]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let path = PathResolver.resolve(arguments.string("path") ?? ".", base: context.workingDirectory)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: path).sorted()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        for name in entries.prefix(500) {
            let full = (path as NSString).appendingPathComponent(name)
            let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
            let isDir = (attrs[.type] as? String) == FileAttributeType.typeDirectory.rawValue
            let size = (attrs[.size] as? Int) ?? 0
            let date = (attrs[.modificationDate] as? Date).map { df.string(from: $0) } ?? ""
            lines.append("\(isDir ? "d" : "-")\t\(size)\t\(date)\t\(name)\(isDir ? "/" : "")")
        }
        if entries.count > 500 { lines.append("…[\(entries.count - 500) more entries]") }
        return .text(ToolCallID("pending"), name: spec.name, lines.joined(separator: "\n"))
    }
}

public enum PathResolver {
    public static func resolve(_ path: String, base: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (base as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    /// Whether `path` is `folder` or lies inside it, following symbolic links (so a link inside the folder that
    /// points out of it counts as outside).
    public static func isInside(_ path: String, folder: String) -> Bool {
        let root = real(folder), target = real(path)
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The path with every link in the part that exists resolved; the part that doesn't exist yet is kept as written.
    private static func real(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/", !existing.isEmpty {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        return missing.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }
}

// MARK: - Browser (via AppleScript to Safari or Chrome; structured and cheaper than clicking)

public struct OpenURLTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "open_url", description: "Open a URL in the default browser (or a named one) and bring it to the front.", inputSchema: JSONSchema.object([
            "url": JSONSchema.string("The URL to open."),
            "browser": JSONSchema.string("Optional browser app name, e.g. Safari or Google Chrome."),
        ], required: ["url"]), needsDesktop: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await context.requireDesktop()
        let url = try arguments.requireString("url")
        let escaped = url.replacingOccurrences(of: "\"", with: "%22")
        let script: String
        if let browser = arguments.string("browser"), !browser.isEmpty {
            script = "tell application \"\(browser)\"\nactivate\nopen location \"\(escaped)\"\nend tell"
        } else {
            script = "open location \"\(escaped)\""
        }
        _ = try await context.desktop.runAppleScript(script)
        return .text(ToolCallID("pending"), name: spec.name, "Opened \(url). Take a screenshot to see the page.")
    }
}

/// JavaScript in the front tab through Apple Events. Safari needs Develop › Allow JavaScript from Apple Events;
/// Chrome and Edge need View › Developer › Allow JavaScript from Apple Events. Browser refusals are reported verbatim.
enum BrowserScripting {
    static func run(_ js: String, in browser: String, desktop: any DesktopControlling) async throws -> String {
        let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = browser == "Safari"
            ? "tell application \"Safari\" to do JavaScript \"\(escapedJS)\" in front document"
            : "tell application \"\(browser)\" to execute front window's active tab javascript \"\(escapedJS)\""
        do {
            return try await desktop.runAppleScript(script)
        } catch DesktopError.scriptFailed(let message) where message.lowercased().contains("javascript") {
            let menu = browser == "Safari" ? "Safari › Develop › Allow JavaScript from Apple Events" : "\(browser) › View › Developer › Allow JavaScript from Apple Events"
            throw ToolError.failed("\(browser) refused JavaScript from Apple Events: \(message). Enable it once in \(menu), or fall back to ui_tree and clicks.")
        }
    }

    /// Serialises form controls with labels, values, and a CSS selector usable by browser_fill.
    static let formFieldsJS = """
    (function(){function sel(e){if(e.id)return '#'+CSS.escape(e.id);if(e.name)return e.tagName.toLowerCase()+'[name="'+e.name.replace(/"/g,'\\\\"')+'"]';var p=[];while(e&&e.nodeType===1&&p.length<6){var s=e.tagName.toLowerCase();var sib=e.parentNode?Array.from(e.parentNode.children).filter(c=>c.tagName===e.tagName):[];if(sib.length>1)s+=':nth-of-type('+(sib.indexOf(e)+1)+')';p.unshift(s);e=e.parentNode;}return p.join('>');}
    function label(e){var l=e.labels&&e.labels[0]?e.labels[0].innerText:'';if(!l&&e.getAttribute('aria-label'))l=e.getAttribute('aria-label');if(!l&&e.placeholder)l=e.placeholder;if(!l&&e.closest('label'))l=e.closest('label').innerText;return (l||'').trim().slice(0,80);}
    var out=[];Array.from(document.querySelectorAll('input,select,textarea,button,[contenteditable="true"]')).forEach(function(e){var r=e.getBoundingClientRect();if(r.width===0&&r.height===0)return;var t=e.tagName.toLowerCase();var type=e.type||t;if(type==='hidden')return;var v='';if(t==='select'){v=e.options[e.selectedIndex]?e.options[e.selectedIndex].text:'';}else if(type==='checkbox'||type==='radio'){v=e.checked?'checked':'unchecked';}else if(t==='button'||type==='submit'){v=(e.innerText||e.value||'').trim().slice(0,60);}else{v=(e.value||e.innerText||'').slice(0,80);}
    out.push({selector:sel(e),type:type,label:label(e),name:e.name||'',value:v,required:!!e.required,options:t==='select'?Array.from(e.options).slice(0,30).map(o=>o.text):undefined});});
    return JSON.stringify(out.slice(0,120));})()
    """
}

public struct BrowserReadTool: Tool {
    /// Reads pages headlessly when a URL is given, or when the user's browser refuses scripting.
    let headless: BrowserRunner?
    public init(headless: BrowserRunner? = nil) { self.headless = headless }
    public var spec: ToolSpec {
        ToolSpec(name: "browser_read_page", description: "Return a web page's visible text without a screenshot, optionally with links and a list of form fields (label, type, current value, and a selector for browser_fill). With `url`, reads that page in Pennant's own headless browser (no tab opens; best for reading articles and sources). Search engines and some sites block it or ask for a captcha: read those with web_open and web_read in Pennant's own Chrome tab instead. Without it, reads the front tab in Safari, Google Chrome, or Microsoft Edge (falling back to reading the tab's address headlessly if the browser refuses scripting). Cheaper and more reliable than reading a screenshot.", inputSchema: JSONSchema.object([
            "url": JSONSchema.string("A page to read in Pennant's headless browser instead of the front tab."),
            "browser": JSONSchema.string("Safari, Google Chrome, or Microsoft Edge. Defaults to Safari.", enumValues: ["Safari", "Google Chrome", "Microsoft Edge"]),
            "include_links": JSONSchema.boolean("Include hyperlinks as 'text -> href' lines."),
            "include_forms": JSONSchema.boolean("Include form controls with labels, values, and selectors."),
            "max_chars": JSONSchema.integer("Maximum characters of page text to return (default 12000)."),
        ]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let browser = arguments.string("browser") ?? "Safari"
        let includeLinks = arguments.bool("include_links") ?? false
        let includeForms = arguments.bool("include_forms") ?? false
        let maxChars = max(500, min(arguments.int("max_chars") ?? 12000, 60000))
        if let url = arguments.string("url"), let headless {
            return .text(ToolCallID("pending"), name: spec.name, try await Self.readHeadless(url, links: includeLinks, maxChars: maxChars, runner: headless))
        }
        let js = includeLinks
            ? "(function(){var t=document.body.innerText;var l=Array.from(document.links).slice(0,300).map(a=>a.innerText.trim().slice(0,80)+' -> '+a.href).join('\\n');return document.title+'\\n'+location.href+'\\n\\n'+t+'\\n\\nLINKS:\\n'+l;})()"
            : "(function(){return document.title+'\\n'+location.href+'\\n\\n'+document.body.innerText;})()"
        var text: String
        do {
            text = String(try await BrowserScripting.run(js, in: browser, desktop: context.desktop).prefix(maxChars))
        } catch {
            // Scripting refused (Chrome's "Allow JavaScript from Apple Events" is off, say): read the tab's address
            // headlessly instead. Its address needs no JavaScript permission.
            guard let headless, !includeForms,
                  let url = try? await context.desktop.runAppleScript(browser == "Safari" ? "tell application \"Safari\" to get URL of current tab of front window" : "tell application \"\(browser)\" to get URL of active tab of front window"),
                  url.hasPrefix("http") else { throw error }
            let read = try await Self.readHeadless(url.trimmingCharacters(in: .whitespacesAndNewlines), links: includeLinks, maxChars: maxChars, runner: headless)
            return .text(ToolCallID("pending"), name: spec.name, read + "\n\n(Read in Pennant's headless browser because \(browser) refused scripting; signed-in content may differ.)")
        }
        if includeForms {
            let json = try await BrowserScripting.run(BrowserScripting.formFieldsJS, in: browser, desktop: context.desktop)
            if let fields = try? JSONValue.parse(json).arrayValue, !fields.isEmpty {
                text += "\n\nFORM FIELDS (use browser_fill with the selector):\n"
                for f in fields {
                    let label = f.string("label").flatMap { $0.isEmpty ? nil : "'\($0)'" } ?? (f.string("name") ?? "")
                    var line = "- \(f.string("type") ?? "?") \(label) selector=\(f.string("selector") ?? "") value=\"\(f.string("value") ?? "")\""
                    if f.bool("required") == true { line += " required" }
                    if let opts = f.stringArray("options"), !opts.isEmpty { line += " options=[\(opts.prefix(12).joined(separator: " | "))]" }
                    text += line + "\n"
                }
            } else {
                text += "\n\nFORM FIELDS: none found."
            }
        }
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}

extension BrowserReadTool {
    static func readHeadless(_ url: String, links: Bool, maxChars: Int, runner: BrowserRunner) async throws -> String {
        let input = try JSONSerialization.data(withJSONObject: ["url": url, "links": links])
        let reply = try await runner.run(script: "read", source: BrowserScripts.read, input: input, timeout: 90)
        let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if let error = result["error"] as? String { throw ToolError.failed("Could not read \(url): \(error)") }
        return String((result["text"] as? String ?? "").prefix(maxChars))
    }
}

public struct BrowserFillTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "browser_fill", description: "Set a form control's value in the front tab (text inputs, textareas, selects, checkboxes, radios) by CSS selector from browser_read_page's form list, firing the input/change events pages expect. Optionally click a submit control afterwards. Verify with browser_read_page or a screenshot.", inputSchema: JSONSchema.object([
            "browser": JSONSchema.string("Safari, Google Chrome, or Microsoft Edge. Defaults to Safari.", enumValues: ["Safari", "Google Chrome", "Microsoft Edge"]),
            "selector": JSONSchema.string("CSS selector of the control."),
            "value": JSONSchema.string("Text to set, option text for selects, or 'checked'/'unchecked' for checkboxes and radios."),
            "submit_selector": JSONSchema.string("Optional CSS selector of a button to click after filling."),
        ], required: ["selector", "value"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let browser = arguments.string("browser") ?? "Safari"
        let selector = try arguments.requireString("selector")
        let value = arguments.string("value") ?? ""
        let submit = arguments.string("submit_selector") ?? ""
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n") + "'" }
        let js = """
        (function(){var e=document.querySelector(\(q(selector)));if(!e)return 'ERROR: no element matches the selector';var v=\(q(value));var t=e.tagName.toLowerCase();var type=e.type||t;
        if(t==='select'){var o=Array.from(e.options).find(x=>x.text.trim()===v||x.value===v);if(!o)return 'ERROR: no option named '+v;e.value=o.value;}
        else if(type==='checkbox'||type==='radio'){e.checked=(v==='checked'||v==='true'||v==='1');}
        else if(e.isContentEditable){e.focus();e.textContent=v;}
        else{var setter=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');e.focus();if(setter&&setter.set){setter.set.call(e,v);}else{e.value=v;}}
        e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));e.blur();
        var sub=\(q(submit));if(sub){var b=document.querySelector(sub);if(!b)return 'Filled, but no submit element matches '+sub;b.click();return 'Filled and clicked '+sub;}
        return 'Filled '+(e.labels&&e.labels[0]?e.labels[0].innerText.trim():e.name||t)+' with "'+String(e.value||e.textContent||'').slice(0,60)+'"';})()
        """
        let result = try await BrowserScripting.run(js, in: browser, desktop: context.desktop)
        return ToolResult(callID: ToolCallID("pending"), name: spec.name, content: [.text(result)], isError: result.hasPrefix("ERROR"))
    }
}
