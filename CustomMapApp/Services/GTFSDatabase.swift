import Foundation
import SQLite3

/// Lightweight SQLite wrapper for GTFS schedule data.
/// Replaces in-memory dictionaries (~875 MB) with on-disk database (~50 MB).
final class GTFSDatabase {
    private var db: OpaquePointer?
    private let path: String

    static var defaultPath: String {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent("gtfs_schedule.sqlite").path
    }

    /// Check if database exists and is fresh (< 7 days old)
    static var isFresh: Bool {
        let path = defaultPath
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modDate) < 7 * 24 * 3600
    }

    /// Age of the database file
    static var ageDescription: String? {
        let path = defaultPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        let seconds = Int(Date().timeIntervalSince(modDate))
        if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86400 { return "Updated \(seconds / 3600)h ago" }
        return "Updated \(seconds / 86400)d ago"
    }

    init(path: String = GTFSDatabase.defaultPath) {
        self.path = path
    }

    deinit {
        close()
    }

    // MARK: - Open / Close

    @discardableResult
    func open() -> Bool {
        guard db == nil else { return true }
        let result = sqlite3_open(path, &db)
        if result != SQLITE_OK {
            print("GTFSDatabase: Failed to open: \(errorMessage)")
            return false
        }
        // Performance pragmas
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")
        execute("PRAGMA cache_size = -2000") // 2 MB cache
        return true
    }

    func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Schema

    func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS trips (
                trip_id TEXT PRIMARY KEY,
                route_id TEXT NOT NULL,
                service_id TEXT NOT NULL,
                direction_id INTEGER DEFAULT 0,
                route_short_name TEXT,
                shape_id TEXT
            )
        """)

        execute("""
            CREATE TABLE IF NOT EXISTS stop_times (
                trip_id TEXT NOT NULL,
                stop_id TEXT NOT NULL,
                arrival_seconds INTEGER,
                departure_seconds INTEGER,
                stop_sequence INTEGER,
                departure_time TEXT
            )
        """)

        execute("""
            CREATE TABLE IF NOT EXISTS calendars (
                service_id TEXT PRIMARY KEY,
                monday INTEGER, tuesday INTEGER, wednesday INTEGER,
                thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER
            )
        """)

        execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
    }

    func createIndexes() {
        execute("CREATE INDEX IF NOT EXISTS idx_st_stop_dep ON stop_times(stop_id, departure_seconds)")
        execute("CREATE INDEX IF NOT EXISTS idx_st_trip_seq ON stop_times(trip_id, stop_sequence)")
        execute("CREATE INDEX IF NOT EXISTS idx_trips_route ON trips(route_id)")
    }

    // MARK: - Transactions

    func beginTransaction() { execute("BEGIN TRANSACTION") }
    func commitTransaction() { execute("COMMIT") }

    // MARK: - Execute

    @discardableResult
    func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            if let errMsg { sqlite3_free(errMsg) }
            return false
        }
        return true
    }

    // MARK: - Prepared Statements for Bulk Insert

    func prepareInsertTrip() -> OpaquePointer? {
        prepare("INSERT OR REPLACE INTO trips VALUES (?, ?, ?, ?, ?, ?)")
    }

    func prepareInsertStopTime() -> OpaquePointer? {
        prepare("INSERT INTO stop_times VALUES (?, ?, ?, ?, ?, ?)")
    }

    func prepareInsertCalendar() -> OpaquePointer? {
        prepare("INSERT OR REPLACE INTO calendars VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    }

    func bindAndStep(_ stmt: OpaquePointer, strings: [String?], ints: [Int?] = []) {
        var idx: Int32 = 1
        for s in strings {
            if let s {
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, idx)
            }
            idx += 1
        }
        for i in ints {
            if let i {
                sqlite3_bind_int(stmt, idx, Int32(i))
            } else {
                sqlite3_bind_null(stmt, idx)
            }
            idx += 1
        }
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
    }

    func finalize(_ stmt: OpaquePointer) {
        sqlite3_finalize(stmt)
    }

    // MARK: - Metadata

    func setMetadata(key: String, value: String) {
        execute("INSERT OR REPLACE INTO metadata VALUES ('\(key)', '\(value)')")
    }

    func getMetadata(key: String) -> String? {
        guard let stmt = prepare("SELECT value FROM metadata WHERE key = ?") else { return nil }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, index: 0)
    }

    // MARK: - Query Helpers

    func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            print("GTFSDatabase: prepare failed for: \(sql) — \(errorMessage)")
            return nil
        }
        return stmt
    }

    func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    func columnInt(_ stmt: OpaquePointer, index: Int32) -> Int {
        Int(sqlite3_column_int(stmt, index))
    }

    var errorMessage: String {
        guard let db else { return "No database" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Count

    func count(table: String) -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM \(table)") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return columnInt(stmt, index: 0)
    }
}
