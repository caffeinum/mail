import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m, let sql): return "sqlite prepare: \(m) — \(sql)"
        case .step(let m, let sql): return "sqlite step: \(m) — \(sql)"
        }
    }
}

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct Row {
    fileprivate let stmt: OpaquePointer

    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    public func text(_ i: Int32) -> String { string(i) ?? "" }
}

/// One connection, one queue. Every call is synchronous on the caller's
/// thread; callers own the threading (the app reads on main for the first
/// frame, the sync engine writes from its actor).
public final class Database {
    private var db: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.open("\(path): \(m)")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA temp_store=MEMORY")
    }

    deinit {
        for s in cache.values { sqlite3_finalize(s) }
        sqlite3_close_v2(db)
    }

    private var errmsg: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? errmsg
            sqlite3_free(err)
            throw SQLiteError.step(m, sql: sql)
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil) == SQLITE_OK, let s else {
            throw SQLiteError.prepare(errmsg, sql: sql)
        }
        cache[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ args: [SQLBindable]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a.sqlValue {
            case .null: sqlite3_bind_null(s, idx)
            case .int(let v): sqlite3_bind_int64(s, idx, v)
            case .double(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
    }

    public func run(_ sql: String, _ args: SQLBindable...) throws {
        try run(sql, args)
    }

    public func run(_ sql: String, _ args: [SQLBindable]) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql)
        bind(s, args)
        let rc = sqlite3_step(s)
        sqlite3_reset(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(errmsg, sql: sql) }
    }

    public func query<T>(_ sql: String, _ args: SQLBindable..., map: (Row) throws -> T) throws -> [T] {
        try query(sql, args, map: map)
    }

    public func query<T>(_ sql: String, _ args: [SQLBindable], map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql)
        bind(s, args)
        defer { sqlite3_reset(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(errmsg, sql: sql) }
            out.append(try map(Row(stmt: s)))
        }
        return out
    }

    public func scalar(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try query(sql, args) { $0.int(0) }.first ?? 0
    }

    public func string(_ sql: String, _ args: SQLBindable...) throws -> String? {
        try query(sql, args) { $0.string(0) }.first ?? nil
    }

    public var changes: Int { Int(sqlite3_changes(db)) }
    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
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
}
