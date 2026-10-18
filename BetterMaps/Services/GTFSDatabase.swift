import Foundation
import SQLite3

/// Minimal read-only SQLite wrapper. Owned privately by
/// `BusTimetableService`; never shared across actors.
final class GTFSDatabase {
    private var db: OpaquePointer?
    let path: String

    /// Makes SQLite copy bound strings, so Swift temporaries can go away.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    // MARK: - Open / Close

    /// Opens the file read-only. Returns false if it is missing or not SQLite.
    @discardableResult
    func open() -> Bool {
        guard db == nil else { return true }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            close()
            return false
        }
        return true
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    var isOpen: Bool { db != nil }

    // MARK: - Statements

    func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        return stmt
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, sqlite3_int64(value))
    }

    /// True while the statement yields a row.
    func step(_ stmt: OpaquePointer) -> Bool {
        sqlite3_step(stmt) == SQLITE_ROW
    }

    func finalize(_ stmt: OpaquePointer) {
        sqlite3_finalize(stmt)
    }

    func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    func columnData(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    /// Runs `sql`, binding with `bind`, and maps every row with `row`.
    func query<T>(_ sql: String,
                  bind: (OpaquePointer) -> Void = { _ in },
                  row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(sql) else { return [] }
        defer { finalize(stmt) }
        bind(stmt)
        var out: [T] = []
        while step(stmt) { out.append(row(stmt)) }
        return out
    }

    func metaValue(_ key: String) -> String? {
        query("SELECT value FROM meta WHERE key = ?",
              bind: { self.bind($0, 1, key) },
              row: { self.columnText($0, 0) }).first ?? nil
    }
}
