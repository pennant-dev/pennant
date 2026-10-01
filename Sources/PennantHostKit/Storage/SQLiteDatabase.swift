import CSQLite
import Foundation

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A bound parameter or column value.
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func int(_ v: Int) -> SQLiteValue { .integer(Int64(v)) }
    public static func date(_ d: Date) -> SQLiteValue { .real(d.timeIntervalSince1970) }
    public static func optional(_ s: String?) -> SQLiteValue { s.map { .text($0) } ?? .null }
}

extension SQLiteValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// One result row. Only valid inside the `query` mapping closure.
public struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ index: Int) -> Bool { sqlite3_column_type(stmt, Int32(index)) == SQLITE_NULL }
    public func int(_ index: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(index)) }
    public func double(_ index: Int) -> Double { sqlite3_column_double(stmt, Int32(index)) }
    public func string(_ index: Int) -> String? {
        guard let c = sqlite3_column_text(stmt, Int32(index)) else { return nil }
        return String(cString: c)
    }
    public func data(_ index: Int) -> Data? {
        guard let p = sqlite3_column_blob(stmt, Int32(index)) else {
            // Zero-length blobs return NULL pointers; distinguish from SQL NULL.
            return isNull(index) ? nil : Data()
        }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, Int32(index))))
    }
    public func bool(_ index: Int) -> Bool { int(index) != 0 }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin synchronous wrapper over the system SQLite. Not thread-safe by itself: the owning actor
/// serialises every call, which is why it is marked `@unchecked Sendable`.
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private var transactionDepth = 0

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
    }

    deinit { close() }


    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    public var lastInsertRowID: Int64 { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    private func currentError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw currentError(rc) }
        return stmt
    }

    private func bind(_ params: [SQLiteValue], to stmt: OpaquePointer) throws {
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), sqliteTransient)
                }
            }
            guard rc == SQLITE_OK else { throw currentError(rc) }
        }
    }

    /// Run a statement that returns no rows. With no parameters, multiple `;`-separated statements are allowed.
    public func execute(_ sql: String, _ params: [SQLiteValue] = []) throws {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database closed") }
        if params.isEmpty {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(err)
                throw SQLiteError(code: rc, message: message)
            }
            return
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw currentError(rc) }
    }

    /// Run a query and map each row.
    public func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(params, to: stmt)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                results.append(try map(SQLiteRow(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw currentError(rc)
            }
        }
        return results
    }

    public func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        try query(sql, params) { $0.int(0) }.first ?? 0
    }

    /// Run `body` inside a transaction. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Consistent online copy of the database to another file, safe while this connection is in use.
    public func backup(toPath destinationPath: String) throws {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database closed") }
        var dest: OpaquePointer?
        let rc = sqlite3_open_v2(destinationPath, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let dest else {
            let message = dest.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open backup destination"
            if let dest { sqlite3_close_v2(dest) }
            throw SQLiteError(code: rc, message: message)
        }
        defer { sqlite3_close_v2(dest) }
        guard let backup = sqlite3_backup_init(dest, "main", db, "main") else {
            throw SQLiteError(code: sqlite3_errcode(dest), message: String(cString: sqlite3_errmsg(dest)))
        }
        var step: Int32
        repeat {
            step = sqlite3_backup_step(backup, 256)
            if step == SQLITE_BUSY || step == SQLITE_LOCKED { sqlite3_sleep(25) }
        } while step == SQLITE_OK || step == SQLITE_BUSY || step == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteError(code: step == SQLITE_DONE ? finish : step, message: String(cString: sqlite3_errmsg(dest)))
        }
    }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }
}
