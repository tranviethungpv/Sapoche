import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A value going into or coming out of the database.
enum SQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int) { self = .int(Int64(value)) }
    init(_ value: Int64) { self = .int(value) }

    var int: Int64 { if case let .int(value) = self { return value } else { return 0 } }
    var text: String? { if case let .text(value) = self { return value } else { return nil } }
}

struct SQLiteError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// The part of SQLite this app uses: statements with bound values, rows read back, and transactions. One connection,
/// used by one caller at a time.
final class SQLite {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// [path] of a file, or `:memory:`.
    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close(db)
            throw SQLiteError(message: message)
        }
        try run("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(db)
    }

    var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(db) }

    /// How many rows the last statement changed.
    var changes: Int { Int(sqlite3_changes(db)) }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try rows(sql, values)
    }

    /// The rows the statement gives, each as its columns.
    @discardableResult
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (position, value) in values.enumerated() {
            let index = Int32(position + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
            }
        }
        var result: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
        return result
    }

    /// Runs [body] so that all of it is kept or none of it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    var version: Int {
        get { Int((try? rows("PRAGMA user_version").first?.first?.int) ?? 0) }
        set { _ = try? rows("PRAGMA user_version = \(newValue)") }
    }

    private func failure() -> SQLiteError {
        SQLiteError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "database error")
    }
}
