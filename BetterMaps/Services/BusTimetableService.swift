import Foundation
import CoreLocation
import CryptoKit
import os
import zlib

// MARK: - Departure row

/// One scheduled departure from the downloaded timetable.
struct BusDeparture: Identifiable, Sendable, Hashable {
    let routeId: String
    let routeShortName: String
    let headsign: String
    let direction: Int
    /// GTFS service day, `yyyyMMdd`.
    let serviceDate: String
    /// Seconds after midnight of `serviceDate`; may exceed 86400.
    let departureSeconds: Int
    /// Absolute departure time.
    let departure: Date

    var id: String { "\(serviceDate)-\(departureSeconds)-\(routeId)-\(direction)-\(headsign)" }

    /// Whole minutes from `now` until departure (never negative).
    func minutesUntil(_ now: Date) -> Int {
        max(0, Int(departure.timeIntervalSince(now) / 60))
    }

    /// "HH:mm" wall-clock time.
    var scheduledTime: String {
        let secs = departureSeconds % 86400
        return String(format: "%02d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}

enum BusTimetableError: Error, Sendable {
    case notAvailable
    case invalidDownload
}

// MARK: - Service

/// The downloadable bus timetable (`transit_timetable.sqlite`, schema 1 in
/// scripts/README.md). Owns a private read-only `GTFSDatabase` in Caches.
///
/// Nothing is fetched until `ensureAvailable()` is called; a second caller
/// attaches to the in-flight download. Failures surface only as the human
/// message in `.failed`.
actor BusTimetableService {
    static let shared = BusTimetableService()

    enum DownloadState: Sendable, Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case ready(builtDate: String?)
        case failed(message: String)
    }

    struct Manifest: Codable, Sendable, Equatable {
        var built: String?
        var feedVersion: String?
        var sha256: String?
        var bytes: Int64?
        var schemaVersion: Int?
    }

    static let unavailableMessage = "Timetable isn't available right now"
    static let supportedSchemaVersion = 1
    static let releaseBase = URL(string: "https://github.com/gabrielconlon/betterMaps/releases/download/transit-data/")!
    static var remoteDatabaseURL: URL { releaseBase.appendingPathComponent("transit_timetable.sqlite.gz") }
    static var remoteManifestURL: URL { releaseBase.appendingPathComponent("manifest.json") }

    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transit_timetable.sqlite")
    }

    private static let log = Logger(subsystem: "com.gabrielconlon.CustomMapApp", category: "timetable")

    private let databaseURL: URL
    private let session: URLSession
    private var db: GTFSDatabase?
    private(set) var state: DownloadState = .notDownloaded
    private var resolved = false
    private var downloadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<DownloadState>.Continuation] = [:]

    /// - Parameter databaseURL: where the SQLite lives. Tests point this at
    ///   a copy of the fixture.
    init(databaseURL: URL = BusTimetableService.defaultDatabaseURL, session: URLSession = .shared) {
        self.databaseURL = databaseURL
        self.session = session
    }

    /// Sidecar copy of the manifest the installed file came from.
    private var localManifestURL: URL {
        databaseURL.deletingPathExtension().appendingPathExtension("manifest.json")
    }

    // MARK: - State

    func currentState() async -> DownloadState {
        resolveIfNeeded()
        return state
    }

    private func resolveIfNeeded() {
        guard !resolved else { return }
        resolved = true
        state = openInstalled() ? .ready(builtDate: db?.metaValue("built")) : .notDownloaded
    }

    /// Opens the installed file if it is a schema-1 timetable.
    private func openInstalled() -> Bool {
        db?.close()
        db = nil
        let candidate = GTFSDatabase(path: databaseURL.path)
        guard candidate.open(),
              candidate.metaValue("schemaVersion") == String(Self.supportedSchemaVersion) else { return false }
        db = candidate
        return true
    }

    private func setState(_ new: DownloadState) {
        state = new
        for listener in listeners.values { listener.yield(new) }
        switch new {
        case .downloading: break
        default:
            for listener in listeners.values { listener.finish() }
            listeners.removeAll()
        }
    }

    private func reportProgress(_ fraction: Double) {
        guard case .downloading(let current) = state, fraction >= current + 0.01 || fraction >= 1 else { return }
        setState(.downloading(fraction: min(fraction, 1)))
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: - Download

    /// Streams the state until the timetable is ready or the download fails.
    /// Starts the download if needed (and retries after a failure); callers
    /// arriving mid-download attach to it. Ending the stream does not cancel
    /// the download, `cancelDownload()` does.
    func ensureAvailable() -> AsyncStream<DownloadState> {
        resolveIfNeeded()
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadState.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        if case .ready = state {
            continuation.yield(state)
            continuation.finish()
            return stream
        }
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        if downloadTask == nil {
            setState(.downloading(fraction: 0))
            downloadTask = Task { await self.runDownload() }
        } else {
            continuation.yield(state)
        }
        return stream
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func runDownload() async {
        do {
            let manifest = try await fetchManifest()
            try await install(manifest: manifest, reportsProgress: true)
            setState(.ready(builtDate: db?.metaValue("built")))
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                setState(openInstalled() ? .ready(builtDate: db?.metaValue("built")) : .notDownloaded)
            } else {
                Self.log.error("timetable download failed: \(String(describing: error))")
                setState(.failed(message: Self.unavailableMessage))
            }
        }
        downloadTask = nil
    }

    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: Self.remoteManifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BusTimetableError.notAvailable }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        if let version = manifest.schemaVersion, version != Self.supportedSchemaVersion {
            throw BusTimetableError.invalidDownload
        }
        return manifest
    }

    /// Downloads, verifies, gunzips and validates into a temp file next to
    /// the destination, then swaps it in atomically.
    private func install(manifest: Manifest, reportsProgress: Bool) async throws {
        let fm = FileManager.default
        let dir = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let gzURL = dir.appendingPathComponent("transit_timetable.\(token).gz")
        let tmpURL = dir.appendingPathComponent("transit_timetable.\(token).sqlite")
        defer {
            try? fm.removeItem(at: gzURL)
            try? fm.removeItem(at: tmpURL)
        }

        let progress: @Sendable (Double) -> Void
        if reportsProgress {
            progress = { [weak self] fraction in
                guard let self else { return }
                Task { await self.reportProgress(fraction * 0.95) }
            }
        } else {
            progress = { _ in }
        }
        try await Self.download(Self.remoteDatabaseURL, to: gzURL, progress: progress)
        try Task.checkCancellation()

        let expectedSHA = manifest.sha256?.lowercased()
        try await Task.detached(priority: .utility) {
            if let expectedSHA, try Self.sha256Hex(of: gzURL) != expectedSHA {
                throw BusTimetableError.invalidDownload
            }
            try Self.gunzip(gzURL, to: tmpURL)
            let check = GTFSDatabase(path: tmpURL.path)
            defer { check.close() }
            guard check.open(),
                  check.metaValue("schemaVersion") == String(Self.supportedSchemaVersion) else {
                throw BusTimetableError.invalidDownload
            }
        }.value
        try Task.checkCancellation()

        // Swap in place: no suspension points from here on.
        db?.close()
        db = nil
        if fm.fileExists(atPath: databaseURL.path) {
            _ = try fm.replaceItemAt(databaseURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: databaseURL)
        }
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: localManifestURL, options: .atomic)
        }
        guard openInstalled() else { throw BusTimetableError.invalidDownload }
    }

    /// Re-downloads in the background when the installed timetable was built
    /// more than `days` ago and the release has a newer build. The current
    /// file keeps serving queries until the new one is swapped in.
    func refreshIfStale(days: Int = 14) {
        resolveIfNeeded()
        guard case .ready(let built) = state, downloadTask == nil, refreshTask == nil else { return }
        if let built, let builtDate = Self.isoDay(built),
           Date().timeIntervalSince(builtDate) < Double(days) * 86400 { return }
        refreshTask = Task { await self.backgroundRefresh() }
    }

    private func backgroundRefresh() async {
        defer { refreshTask = nil }
        do {
            let manifest = try await fetchManifest()
            let local = localManifest()
            if let sha = manifest.sha256, sha.lowercased() == local?.sha256?.lowercased() { return }
            if let remoteBuilt = manifest.built, let localBuilt = db?.metaValue("built"),
               remoteBuilt <= localBuilt { return }
            try await install(manifest: manifest, reportsProgress: false)
            setState(.ready(builtDate: db?.metaValue("built")))
        } catch {
            Self.log.info("timetable refresh skipped: \(String(describing: error))")
        }
    }

    private func localManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: localManifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Local file management

    func deleteDownload() {
        downloadTask?.cancel()
        refreshTask?.cancel()
        db?.close()
        db = nil
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: localManifestURL)
        resolved = true
        setState(.notDownloaded)
    }

    /// Size on disk and build date of the installed timetable, if any.
    func localInfo() -> (bytes: Int64, built: String?)? {
        resolveIfNeeded()
        guard let db,
              let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return (size.int64Value, db.metaValue("built"))
    }

    // MARK: - Queries

    private func requireDatabase() throws -> GTFSDatabase {
        resolveIfNeeded()
        guard let db else { throw BusTimetableError.notAvailable }
        return db
    }

    /// Departures at the stop (`stopId` ∪ `altIds`) from `date` to
    /// `date + window`, soonest first. Includes after-midnight trips of the
    /// previous service day (`dep >= T + 86400` on `D - 1`).
    func departures(stopId: String, altIds: [String] = [], from date: Date,
                    window: TimeInterval = 2 * 3600, limit: Int = 30) async throws -> [BusDeparture] {
        let db = try requireDatabase()
        let ids = [stopId] + altIds
        let (day, seconds) = Self.serviceDay(containing: date)
        let windowSecs = Int(window)
        var rows = Self.departureRows(db, stopIds: ids, serviceDay: day,
                                      from: seconds, to: seconds + windowSecs, limit: limit)
        rows += Self.departureRows(db, stopIds: ids, serviceDay: Self.addingDays(-1, to: day),
                                   from: seconds + 86400, to: seconds + 86400 + windowSecs, limit: limit)
        rows.sort { $0.departure < $1.departure }
        return Array(rows.prefix(limit))
    }

    /// Routes serving the stop (`stopId` ∪ `altIds`), by short name.
    func routes(forStop stopId: String, altIds: [String] = []) async throws -> [TransitRoute] {
        let db = try requireDatabase()
        let ids = [stopId] + altIds
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let routes = db.query("""
            SELECT DISTINCT r.gtfs_id, r.short, r.long, r.type
            FROM stop_routes sr
            JOIN stops s  ON s.id = sr.stop
            JOIN routes r ON r.id = sr.route
            WHERE s.gtfs_id IN (\(placeholders))
            """,
            bind: { stmt in for (i, id) in ids.enumerated() { db.bind(stmt, Int32(i + 1), id) } },
            row: { stmt in
                TransitRoute(id: db.columnText(stmt, 0) ?? "", short: db.columnText(stmt, 1) ?? "",
                             long: db.columnText(stmt, 2) ?? "", type: db.columnInt(stmt, 3))
            })
        return routes.sorted { $0.short.localizedStandardCompare($1.short) == .orderedAscending }
    }

    /// The route's polyline for one direction, or nil when it has none.
    func routeShape(routeId: String, dir: Int) async throws -> [CLLocationCoordinate2D]? {
        let db = try requireDatabase()
        let blobs = db.query("""
            SELECT rs.polyline FROM route_shapes rs
            JOIN routes r ON r.id = rs.route
            WHERE r.gtfs_id = ? AND rs.dir = ?
            """,
            bind: { stmt in db.bind(stmt, 1, routeId); db.bind(stmt, 2, dir) },
            row: { db.columnData($0, 0) })
        guard let data = blobs.first ?? nil,
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { return nil }
        return pairs.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }

    private static func departureRows(_ db: GTFSDatabase, stopIds: [String], serviceDay: String,
                                      from: Int, to: Int, limit: Int) -> [BusDeparture] {
        let placeholders = Array(repeating: "?", count: stopIds.count).joined(separator: ",")
        let base = serviceDayStart(serviceDay)
        return db.query("""
            SELECT st.dep, r.gtfs_id, r.short, t.headsign, t.dir
            FROM stop_times st
            JOIN stops s        ON s.id = st.stop
            JOIN trips t        ON t.id = st.trip
            JOIN routes r       ON r.id = t.route
            JOIN service_days d ON d.service = t.service AND d.date = ?
            WHERE s.gtfs_id IN (\(placeholders)) AND st.dep >= ? AND st.dep < ?
            ORDER BY st.dep LIMIT ?
            """,
            bind: { stmt in
                db.bind(stmt, 1, serviceDay)
                for (i, id) in stopIds.enumerated() { db.bind(stmt, Int32(i + 2), id) }
                let n = Int32(stopIds.count)
                db.bind(stmt, n + 2, from)
                db.bind(stmt, n + 3, to)
                db.bind(stmt, n + 4, limit)
            },
            row: { stmt in
                let dep = db.columnInt(stmt, 0)
                return BusDeparture(routeId: db.columnText(stmt, 1) ?? "",
                                    routeShortName: db.columnText(stmt, 2) ?? "",
                                    headsign: db.columnText(stmt, 3) ?? "",
                                    direction: db.columnInt(stmt, 4),
                                    serviceDate: serviceDay,
                                    departureSeconds: dep,
                                    departure: base.addingTimeInterval(TimeInterval(dep)))
            })
    }

    // MARK: - Calendar helpers (Europe/Dublin)

    static let dublin: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Dublin") ?? .current
        return cal
    }()

    /// `yyyyMMdd` of `date` in Dublin and the seconds since local midnight.
    static func serviceDay(containing date: Date) -> (day: String, seconds: Int) {
        let c = dublin.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return (day, (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
    }

    /// GTFS times count from "noon minus 12 h" of the service day, which
    /// keeps them right across DST changes.
    static func serviceDayStart(_ day: String) -> Date {
        noon(of: day).addingTimeInterval(-12 * 3600)
    }

    static func addingDays(_ n: Int, to day: String) -> String {
        let shifted = dublin.date(byAdding: .day, value: n, to: noon(of: day)) ?? noon(of: day)
        return serviceDay(containing: shifted).day
    }

    private static func noon(of day: String) -> Date {
        let digits = Array(day)
        guard digits.count == 8,
              let y = Int(String(digits[0..<4])), let m = Int(String(digits[4..<6])),
              let d = Int(String(digits[6..<8])) else { return Date() }
        return dublin.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date()
    }

    /// `"2026-10-18"` → that day at midnight UTC.
    static func isoDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - File helpers (run off the actor)

    private static func download(_ url: URL, to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a gzip file through zlib into `destination`.
    static func gunzip(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var stream = z_stream()
        // 16 + MAX_WBITS: expect a gzip header/trailer.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw BusTimetableError.invalidDownload
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var finished = false
        while !finished, let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(raw.count)
                repeat {
                    let produced: Int = try outBuffer.withUnsafeMutableBufferPointer { out in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(out.count)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        switch status {
                        case Z_STREAM_END: finished = true
                        case Z_OK, Z_BUF_ERROR: break
                        default: throw BusTimetableError.invalidDownload
                        }
                        return out.count - Int(stream.avail_out)
                    }
                    if produced > 0 { try output.write(contentsOf: Data(outBuffer[0..<produced])) }
                } while !finished && (stream.avail_in > 0 || stream.avail_out == 0)
            }
        }
        guard finished else { throw BusTimetableError.invalidDownload }
    }
}

// MARK: - URLSession delegate

/// Bridges a delegate-based download (for byte progress) to async/await.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: @Sendable (Double) -> Void

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            resume(.failure(BusTimetableError.notAvailable))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            resume(.success(()))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resume(error.map { .failure($0) } ?? .success(()))
    }
}
