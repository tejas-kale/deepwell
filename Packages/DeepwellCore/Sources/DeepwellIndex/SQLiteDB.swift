import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, LocalizedError {
    public var errorDescription: String? { description }
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

/// Minimal synchronous wrapper over the system SQLite. `LibraryIndex` serialises access with a lock.
final class SQLiteDB {
    enum Value { case int(Int64), double(Double), text(String), null }

    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(db, 5000)   // wait for a concurrent writer instead of failing at once
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String, _ params: [Value] = []) throws {
        _ = try query(sql, params) { _ in () }
    }

    @discardableResult
    func query<T>(_ sql: String, _ params: [Value] = [], row: (Row) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(try row(Row(stmt: stmt)))
            case SQLITE_DONE: return out
            default: throw lastError()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        // Reserve the writer before reading. A deferred read-to-write upgrade can
        // fail immediately with SQLITE_BUSY despite the busy timeout.
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    struct Row {
        let stmt: OpaquePointer?
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String? {
            guard !isNull(i), let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
    }
}
