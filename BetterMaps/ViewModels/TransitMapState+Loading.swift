import Foundation
import MapKit

extension TransitMapState {
    /// Two-phase transit load (moved verbatim from MapTabView.loadTransitData).
    ///
    /// The history of this function is a series of regressions where the user
    /// saw an empty map (no stops or no lines) for some window — sometimes a
    /// few seconds, sometimes seven days until the SQLite freshness window
    /// expired. The recurring root cause was always the same shape: a slow
    /// async step (downloading or re-parsing the 65MB GTFS ZIP, which can
    /// take 30–60s) sat *between* the data we already had on disk and the
    /// single point where we wrote it onto transitState.
    ///
    ///   PHASE 1 — Hydrate from disk caches *before* any await that could
    ///             block. After Phase 1 the map is fully usable from whatever
    ///             was cached on the previous successful launch.
    ///
    ///   PHASE 2 — Refresh from SQLite once the GTFS DB is loaded. Empty
    ///             query results never overwrite a Phase 1 hit (so a partial
    ///             SQLite parse can't wipe the map).
    func loadTransitData() async {
        // ─── PHASE 1: Instant hydration from disk caches ──────────────────────
        let loader = GTFSStopLoader()
        let stopsFromCache = await loader.loadStops()    // returns from JSON cache in ~100ms
        transitStops = stopsFromCache                    // ← assign EARLY, before any slow await

        if let cached = TransitShapeCache.load() {
            luasRedShapeLines = cached.red
            luasGreenShapeLines = cached.green
            dartShapeLines = cached.dart
            railShapeLines = cached.rail
            luasRedStopIds = cached.luasRedStops
            luasGreenStopIds = cached.luasGreenStops
        }

        // ─── PHASE 2: Refresh from SQLite GTFS database ────────────────────────
        await GTFSScheduleService.shared.loadIfNeeded()
        let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()

        var reclassified = stopsFromCache
        if !classification.isEmpty {
            reclassified = stopsFromCache.map { stop in
                guard let typeStr = classification[stop.id],
                      let newType = TransitStop.TransitStopType(rawValue: typeStr),
                      stop.type != newType else { return stop }
                return TransitStop(id: stop.id, name: stop.name,
                                   latitude: stop.latitude, longitude: stop.longitude,
                                   type: newType, stopCode: stop.stopCode)
            }
        }
        let dedupedStops = Self.deduplicateLuasStops(reclassified, classifiedIds: Set(classification.keys))

        let luasShapes = await GTFSScheduleService.shared.luasShapesByLine()
        let luasStops = await GTFSScheduleService.shared.luasStopsByLine()
        let dart = await GTFSScheduleService.shared.shapeCoordinatesForDART()
        let rail = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()

        // Single-frame batch refresh. Conditional overwrites are deliberate:
        // an empty SQL result (broken DB, mid-parse, partial download) MUST
        // NOT clobber the Phase 1 cache hit.
        transitStops = dedupedStops
        if !luasShapes.red.isEmpty { luasRedShapeLines = luasShapes.red }
        if !luasShapes.green.isEmpty { luasGreenShapeLines = luasShapes.green }
        if !dart.isEmpty { dartShapeLines = dart }
        if !rail.isEmpty { railShapeLines = rail }
        if !luasStops.red.isEmpty || !luasStops.green.isEmpty {
            luasRedStopIds = luasStops.red
            luasGreenStopIds = luasStops.green
        }

        // Persist Phase 2's truth back to disk so the next launch's Phase 1 is
        // accurate. TransitShapeCache.save refuses empty snapshots so a fully
        // empty Phase 2 never wipes a good cache.
        TransitShapeCache.save(
            luasRed: luasRedShapeLines,
            luasGreen: luasGreenShapeLines,
            dart: dartShapeLines,
            rail: railShapeLines,
            luasRedStops: luasRedStopIds,
            luasGreenStops: luasGreenStopIds
        )
    }

    /// Collapses Luas platform duplicates (same stop within 250 m or sharing a
    /// normalized name), preferring the stop the schedule classified.
    static func deduplicateLuasStops(_ allStops: [TransitStop], classifiedIds: Set<String>) -> [TransitStop] {
        let luasStops = allStops.filter { $0.type == .luas }
            .sorted { classifiedIds.contains($0.id) && !classifiedIds.contains($1.id) }
        let nonLuas = allStops.filter { $0.type != .luas }
        var kept: [TransitStop] = []
        for stop in luasStops {
            let isDuplicate = kept.contains { existing in
                if WaypointGraph.meters(stop.coordinate, existing.coordinate) < 250 { return true }
                let a = stop.name.lowercased().replacingOccurrences(of: " luas", with: "")
                    .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                let b = existing.name.lowercased().replacingOccurrences(of: " luas", with: "")
                    .replacingOccurrences(of: " stop", with: "").trimmingCharacters(in: .whitespaces)
                return a == b || a.contains(b) || b.contains(a)
            }
            if !isDuplicate { kept.append(stop) }
        }
        return nonLuas + kept
    }
}
