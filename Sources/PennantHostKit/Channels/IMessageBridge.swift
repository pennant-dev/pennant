import PennantCore
import Foundation
import SQLite3

/// iMessage through this Mac's Messages app: sending with AppleScript (Messages asks once to allow Pennant Host to
/// control it), and reading incoming messages from Messages' own database, which needs Full Disk Access.
struct IMessageBridge: Sendable {
    struct Incoming: Sendable {
        var rowID: Int64
        var handle: String
        var text: String
        /// Sent from this Mac's own Apple ID (only read in group chats).
        var fromMe = false
        /// The group chat it was said in (its `chat_identifier`), nil for a one-to-one message.
        var group: String?
    }

    /// A named group chat in Messages.
    struct GroupChat: Sendable, Hashable {
        /// Messages' `chat_identifier` ("chat123456789"): stable, and the end of the chat's AppleScript id.
        var identifier: String
        var name: String
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Messages' database. Tests point it at a copy of their own.
    nonisolated(unsafe) static var databaseURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")

    /// Sends through Messages' iMessage account. The handle and text travel as arguments, never inside the script.
    func send(_ text: String, to handle: String) async throws {
        try await run("""
        on run argv
            tell application "Messages"
                set svc to 1st account whose service type = iMessage
                send (item 2 of argv) to participant (item 1 of argv) of svc
            end tell
        end run
        """, [handle, text])
    }

    /// Sends into a group chat, found by the end of its id (Messages' ids are "<service>;+;<chat_identifier>").
    func send(_ text: String, toGroup identifier: String) async throws {
        try await run("""
        on run argv
            tell application "Messages"
                set target to missing value
                repeat with c in chats
                    if (id of c) ends with (";" & (item 1 of argv)) then set target to c
                end repeat
                if target is missing value then error "Messages has no group chat " & (item 1 of argv)
                send (item 2 of argv) to target
            end tell
        end run
        """, [identifier, text])
    }

    private func run(_ script: String, _ arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if why.contains("-1743") || why.lowercased().contains("not allowed") {
                throw Failure(description: "Pennant Host isn't allowed to control Messages: allow it in System Settings › Privacy & Security › Automation.")
            }
            throw Failure(description: why.isEmpty ? "Messages didn't send it" : why)
        }
    }

    /// Whether Messages' database can be read (Full Disk Access granted).
    static var canRead: Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        return sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK && sqlite3_exec(db, "SELECT 1 FROM message LIMIT 1", nil, nil, nil) == SQLITE_OK
    }

    /// The newest message's row, to start reading after (history before Pennant isn't imported).
    static func latestRowID() throws -> Int64 {
        try query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { stmt in sqlite3_column_int64(stmt, 0) }.first ?? 0
    }

    /// Messages received after `rowID` from any of `handles` (phone numbers or emails, as Messages stores them), one
    /// to one: what they say in a group chat belongs to the group, not to their own thread.
    static func received(after rowID: Int64, from handles: Set<String>) throws -> [Incoming] {
        guard !handles.isEmpty else { return [] }
        let rows: [Incoming?] = try query("""
            SELECT m.ROWID, h.id, m.text, m.attributedBody FROM message m JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0 AND m.ROWID > \(rowID) AND m.item_type = 0 AND m.associated_message_type = 0
              AND NOT EXISTS (SELECT 1 FROM chat_message_join j JOIN chat c ON c.ROWID = j.chat_id WHERE j.message_id = m.ROWID AND c.style = 43)
            ORDER BY m.ROWID LIMIT 200
            """) { stmt in
            Incoming(rowID: sqlite3_column_int64(stmt, 0), handle: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                     text: text(stmt, column: 2))
        }
        let normalized = Set(handles.map(Self.normalize))
        return rows.compactMap { $0 }.filter { normalized.contains(Self.normalize($0.handle)) && !$0.text.isEmpty }
    }

    /// Messages said after `rowID` in the given group chats, by anyone in them, this Mac's Apple ID included.
    static func received(after rowID: Int64, inGroups groups: Set<String>) throws -> [Incoming] {
        guard !groups.isEmpty else { return [] }
        let rows: [Incoming] = try query("""
            SELECT m.ROWID, COALESCE(h.id, ''), m.text, m.attributedBody, m.is_from_me, c.chat_identifier
            FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE c.style = 43 AND m.ROWID > \(rowID) AND m.item_type = 0 AND m.associated_message_type = 0
            ORDER BY m.ROWID LIMIT 200
            """) { stmt in
            Incoming(rowID: sqlite3_column_int64(stmt, 0), handle: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                     text: text(stmt, column: 2), fromMe: sqlite3_column_int(stmt, 4) != 0,
                     group: sqlite3_column_text(stmt, 5).map { String(cString: $0) })
        }
        return rows.filter { $0.group.map(groups.contains) == true && !$0.text.isEmpty }
    }

    /// The named group chats, most recently active first.
    static func groupChats() throws -> [GroupChat] {
        try query("""
            SELECT c.chat_identifier, c.display_name FROM chat c
            WHERE c.style = 43 AND COALESCE(c.display_name, '') <> ''
            ORDER BY (SELECT MAX(j.message_id) FROM chat_message_join j WHERE j.chat_id = c.ROWID) DESC LIMIT 40
            """) { stmt in
            GroupChat(identifier: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                      name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "")
        }.filter { !$0.identifier.isEmpty }
    }

    /// A message's text: the plain column, or (newer macOS) the archived attributed string.
    private static func text(_ stmt: OpaquePointer, column: Int32) -> String {
        if let t = sqlite3_column_text(stmt, column).map({ String(cString: $0) }), !t.isEmpty { return t }
        guard let blob = sqlite3_column_blob(stmt, column + 1) else { return "" }
        return textFromAttributedBody(Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, column + 1)))) ?? ""
    }

    /// How Pennant's replies start when Messages is a person's own Apple ID, so nobody takes them for the person.
    static let replyLabel = "[Pennant] "

    static func isPennantsReply(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(replyLabel.trimmingCharacters(in: .whitespaces))
    }

    /// A text meant for Pennant ("Pennant, …", "Hey Pennant …", "@pennant …"): what's asked, without the name. Nil
    /// for anything else, which stays the person's own.
    static func addressedToPennant(_ text: String) -> String? {
        let pattern = #"^\s*(?:hey\s+|hi\s+|@)?pennant\b[\s,:;!.\-–—]*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let asked = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return asked.isEmpty ? "Hi" : asked
    }

    /// Messages shows text as it is: markdown's marks would show as asterisks and brackets. Links become
    /// "text (address)" (or just the address), bold and code lose their marks, headings their hashes, bullets are dots.
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            // A link whose text was its own address: once is enough.
            line = line.replacingOccurrences(of: #"(https?://\S+) \(\1\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Phone numbers compared by their digits (the last ten), emails case-insensitively.
    static func normalize(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    /// Newer macOS keeps a message's text only in `attributedBody`, an archived NSAttributedString: the text
    /// follows the "NSString" class marker, after a one-byte (or 0x81 + two-byte) length.
    static func textFromAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = "NSString".data(using: .utf8).map([UInt8].init),
              let start = (0 ..< max(0, bytes.count - marker.count)).first(where: { Array(bytes[$0 ..< $0 + marker.count]) == marker }) else { return nil }
        var i = start + marker.count
        // Skip to the '+' that precedes the string's length.
        while i < bytes.count, bytes[i] != 0x2B { i += 1 }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81, i + 1 < bytes.count {
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i ..< i + length], encoding: .utf8)
    }

    private static func query<T>(_ sql: String, _ read: (OpaquePointer) -> T) throws -> [T] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Failure(description: "Can't read Messages: give Pennant Host Full Disk Access in System Settings › Privacy & Security.")
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(description: "Can't read Messages: give Pennant Host Full Disk Access in System Settings › Privacy & Security.")
        }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(read(stmt)) }
        return out
    }
}
