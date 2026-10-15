import Foundation
import SQLite3

/// SQLite asks to copy bound strings; Swift strings are temporary buffers.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A failed SQLite call, with SQLite's own (extended) result code.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    /// SQLite reports the file itself as damaged: its rows are unrecoverable.
    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLiteValue {
    case text(String)
    case int(Int64)
}

/// One row of a query; valid only inside the row callback.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
}

/// One SQLite connection with every result code checked.
///
/// Not thread-safe: use it from one serial queue. Each statement is finalized
/// before its call returns, so [close] never meets an open statement, and a
/// failed transaction is rolled back before the error reaches the caller.
final class SQLiteConnection {
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    static func open(path: String) throws -> SQLiteConnection {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil
        )
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_extended_result_codes(handle, 1)
        return SQLiteConnection(handle: handle)
    }

    /// Runs one or more statements that bind nothing (schema, pragmas).
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    /// Runs one statement to completion; returns the rows it changed.
    @discardableResult
    func run(_ sql: String, _ arguments: [SQLiteValue] = []) throws -> Int {
        try withStatement(sql, arguments) { statement in
            try check(sqlite3_step(statement), expecting: SQLITE_DONE)
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs one query, calling [row] for each result row.
    func query(_ sql: String, _ arguments: [SQLiteValue] = [], row: (SQLiteRow) -> Void) throws {
        try withStatement(sql, arguments) { statement in
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { return }
                try check(rc, expecting: SQLITE_ROW)
                row(SQLiteRow(statement: statement))
            }
        }
    }

    /// Runs [body] in one immediate transaction. Commits only if [body]
    /// returns; a throw, or a failed commit, rolls everything back and throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        let result: T
        do {
            result = try body()
            try execute("COMMIT")
        } catch {
            _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return result
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    private func withStatement(
        _ sql: String,
        _ arguments: [SQLiteValue],
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                try check(sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT))
            case .int(let number):
                try check(sqlite3_bind_int64(statement, position, number))
            }
        }
        try body(statement)
    }

    private func check(_ rc: Int32, expecting expected: Int32 = SQLITE_OK) throws {
        guard rc == expected else {
            throw SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}
