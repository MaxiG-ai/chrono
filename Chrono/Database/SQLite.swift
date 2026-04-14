import Foundation
import SQLite3

// SQLite binds these special sentinel values to functions that take a destructor
// for the payload. SQLITE_STATIC says "don't copy, don't free" — valid only when
// the bound memory outlives the statement step. SQLITE_TRANSIENT says "make a copy".
let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// SQLite error wrapped with the code and the full human-readable message.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// Thin wrapper around a single SQLite connection. Not thread-safe on its own —
/// callers route access through `Database`, which owns a serial dispatch queue.
final class SQLiteConnection {
    fileprivate var handle: OpaquePointer?

    init(path: String) throws {
        // SQLITE_OPEN_FULLMUTEX gives us safe concurrent use, but we still
        // serialize through a queue at a higher level to keep semantics simple
        // and avoid surprising writer contention.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        if result != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: result, message: msg)
        }
        // Recommended pragmas. WAL gives us concurrent readers + writer,
        // synchronous=NORMAL is safe with WAL and much faster than FULL.
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=3000;")
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func execute(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if result != SQLITE_OK {
            let message = errmsg.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw SQLiteError(code: result, message: message)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int32 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt.raw) }
        try stmt.bind(params)
        let step = sqlite3_step(stmt.raw)
        if step != SQLITE_DONE && step != SQLITE_ROW {
            throw lastError(step)
        }
        return sqlite3_changes(handle)
    }

    func query<T>(_ sql: String, _ params: [SQLiteValue] = [], row: (SQLiteRow) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt.raw) }
        try stmt.bind(params)
        var results: [T] = []
        while true {
            let step = sqlite3_step(stmt.raw)
            if step == SQLITE_ROW {
                results.append(try row(SQLiteRow(statement: stmt.raw)))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw lastError(step)
            }
        }
        return results
    }

    /// Execute `block` inside a transaction. Rolls back on error.
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try block()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private func prepare(_ sql: String) throws -> PreparedStatement {
        var raw: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &raw, nil)
        if result != SQLITE_OK {
            throw lastError(result)
        }
        guard let raw else {
            throw SQLiteError(code: result, message: "prepare returned nil statement")
        }
        return PreparedStatement(raw: raw)
    }

    private func lastError(_ code: Int32) -> SQLiteError {
        let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return SQLiteError(code: code, message: msg)
    }
}

/// A typed value we can bind to a SQLite parameter.
enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
    static func optionalText(_ value: String?) -> SQLiteValue {
        if let value { return .text(value) }
        return .null
    }
}

final class PreparedStatement {
    let raw: OpaquePointer
    init(raw: OpaquePointer) { self.raw = raw }

    func bind(_ values: [SQLiteValue]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let result: Int32
            switch v {
            case .null:
                result = sqlite3_bind_null(raw, idx)
            case .integer(let n):
                result = sqlite3_bind_int64(raw, idx, n)
            case .real(let d):
                result = sqlite3_bind_double(raw, idx, d)
            case .text(let s):
                // SQLITE_TRANSIENT tells SQLite to copy the bytes so the Swift
                // String can be freed when this scope exits.
                result = sqlite3_bind_text(raw, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(raw, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            }
            if result != SQLITE_OK {
                throw SQLiteError(code: result, message: "bind failed at index \(idx)")
            }
        }
    }
}

/// Read-only accessor for a single row. Indices are zero-based by column position.
struct SQLiteRow {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func intValue(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func text(_ column: Int32) -> String {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cStr = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: cStr)
    }

    func optionalText(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cStr = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cStr)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}
