import Foundation
import CoreLocation
import Observation
import SwiftData

/// State of the directions sheet: the two endpoints, when to travel, the
/// user's preferences (mirrored from the `DirectionsPreferences` row) and
/// the itineraries the provider returned for them.
///
/// Every control change writes the `@Model`, then re-plans after a short
/// debounce; a newer change cancels the in-flight plan so a slow answer
/// never lands on top of a newer one.
///
/// A plan is more than one request: beside the user's own query run a
/// rail-only probe (when they prefer rail) and a longer-walk probe (when
/// their walk limit is short), merged and ranked together. With rain
/// awareness on, the forecast is checked after the results land and, when a
/// shower is likely, the plan is run again with a five-minute walk limit.
@MainActor
@Observable
final class DirectionsViewModel {
    enum Phase: Equatable {
        /// No request can be built yet (an endpoint is missing).
        case idle
        case loading
        case results
        /// The provider answered with nothing. The flags say which of the
        /// user's own limits may be the reason.
        case empty(suggestRelaxWalk: Bool, suggestTransfers: Bool)
        case unreachable(message: String)
    }

    nonisolated static let debounce: Duration = .milliseconds(400)
    private static let genericFailure = "Directions are unavailable right now."

    var origin: DirectionsEndpoint?
    var destination: DirectionsEndpoint?
    var departNow = true
    var time = Date()
    var arriveBy = false
    /// Last known user location, offered by the endpoint picker.
    var userLocation: CLLocationCoordinate2D?
    /// True while the directions sheet is on screen. The host sets it; work
    /// that only matters to someone looking (re-planning after a preferences
    /// sync, filling in a late location fix) is gated on it.
    var isPresented = false
    private(set) var prefs: DirectionsPreferencesSnapshot = .default
    private(set) var itineraries: [Itinerary] = []
    var selectedId: Itinerary.ID?
    private(set) var phase: Phase = .idle
    /// Chip text for the drawn option; nil when nothing is drawn.
    var drawnLabel: String?
    /// The forecast's verdict for this search; nil when dry, off, or unknown.
    private(set) var rainHint: RainHint?
    /// True while the results shown were planned with the rain walk limit.
    private(set) var rainAdjusted = false
    /// Set by `undoRainAdjustment`; cleared when either endpoint changes.
    private var rainUndoneForSearch = false

    /// The walk limit planned with when rain is likely.
    nonisolated static let rainWalkMinutes = 5
    /// Walk limit the relaxed probe plans with.
    nonisolated static let relaxedWalkMinutes = 20
    /// Walk limits at or below this get a relaxed probe alongside.
    nonisolated static let relaxedProbeCeilingMinutes = 10
    /// Fallback forecast window when the plan found nothing to time it by.
    nonisolated static let fallbackWindow: TimeInterval = 90 * 60

    @ObservationIgnored private let provider: any JourneyProvider
    @ObservationIgnored private let weather: WeatherHintService
    @ObservationIgnored private let store: TransitLayerStore
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var prefsModel: DirectionsPreferences?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(provider: any JourneyProvider, store: TransitLayerStore = .shared,
         weather: WeatherHintService = WeatherHintService()) {
        self.provider = provider
        self.store = store
        self.weather = weather
    }

    // MARK: - Preferences

    /// Binds to the preferences row. Idempotent; the first call reads it.
    func attach(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        guard let row = try? DirectionsPreferences.fetchOrCreate(in: context) else { return }
        prefsModel = row
        try? context.save()
        prefs = row.snapshot
    }

    /// Re-reads the preferences (Settings or another device changed them).
    /// With the sheet up, the row is fetched again (collapsing anything
    /// CloudKit merged in) and a change re-plans; hidden, the bound row is
    /// only mirrored so a save elsewhere in the app costs no query.
    func refreshPrefs() {
        guard let context else { return }
        let fresh: DirectionsPreferencesSnapshot
        if isPresented {
            guard let row = try? DirectionsPreferences.fetchOrCreate(in: context) else { return }
            if row !== prefsModel { prefsModel = row }
            fresh = row.snapshot
        } else {
            guard let prefsModel, !prefsModel.isDeleted else { return }
            fresh = prefsModel.snapshot
        }
        guard fresh != prefs else { return }
        prefs = fresh
        if isPresented { scheduleQuery() }
    }

    var selectedItinerary: Itinerary? {
        guard let selectedId else { return nil }
        return itineraries.first { $0.id == selectedId }
    }

    // MARK: - Endpoints

    /// Opens the sheet for `destination`. With a location the origin is
    /// "My Location" and planning starts at once; without one the phase
    /// stays idle until the user picks a starting point. A different journey
    /// clears what was found for the old one first; the same journey (the
    /// sheet reopened) keeps its list and drawn option while it refreshes.
    func start(destination: DirectionsEndpoint, userLocation: CLLocationCoordinate2D?) {
        self.userLocation = userLocation
        let newOrigin: DirectionsEndpoint?
        if let userLocation {
            newOrigin = .userLocation(userLocation)
        } else if origin?.isUserLocation == true {
            newOrigin = nil
        } else {
            newOrigin = origin
        }
        // A fresher fix for "My Location" is still the same starting point.
        let bothUserLocation = newOrigin?.isUserLocation == true && origin?.isUserLocation == true
        let changed = destination != self.destination || (!bothUserLocation && newOrigin != origin)
        self.destination = destination
        origin = newOrigin
        departNow = true
        time = Date()
        if changed { forgetResults() }
        resetRainState()
        scheduleQuery(immediate: true)
    }

    func setOrigin(_ endpoint: DirectionsEndpoint) {
        if endpoint != origin {
            origin = endpoint
            forgetResults()
        }
        resetRainState()
        scheduleQuery(immediate: true)
    }

    func setDestination(_ endpoint: DirectionsEndpoint) {
        if endpoint != destination {
            destination = endpoint
            forgetResults()
        }
        resetRainState()
        scheduleQuery(immediate: true)
    }

    func swapEndpoints() {
        (origin, destination) = (destination, origin)
        forgetResults()
        resetRainState()
        scheduleQuery(immediate: true)
    }

    /// A location fix arrived. Fills in a missing starting point while the
    /// sheet is up (the first fix after permission was granted) and plans at
    /// once. A later fix that merely moves "My Location" changes nothing:
    /// the plan in hand started a few metres away, and re-planning on every
    /// fix would churn the list under the user's thumb.
    func userLocationDidUpdate(_ coordinate: CLLocationCoordinate2D) {
        userLocation = coordinate
        guard isPresented, origin == nil, destination != nil else { return }
        origin = .userLocation(coordinate)
        resetRainState()
        scheduleQuery(immediate: true)
    }

    /// The journey changed: nothing found for the old one may linger.
    private func forgetResults() {
        itineraries = []
        dropSelection()
    }

    /// A new journey: forget the old forecast and any undo.
    private func resetRainState() {
        rainHint = nil
        rainAdjusted = false
        rainUndoneForSearch = false
    }

    // MARK: - Control writers

    func setWalkTolerance(_ minutes: Int) {
        write(prefs.replacing(walkToleranceMinutes: minutes))
    }

    func toggleMode(_ mode: TransitMode) {
        var modes = prefs.enabledModes
        if modes.contains(mode) { modes.remove(mode) } else { modes.insert(mode) }
        write(prefs.replacing(enabledModes: modes))
    }

    func setBikeDirect(_ on: Bool) {
        write(prefs.replacing(allowBikeDirect: on))
    }

    func setMaxTransfers(_ count: Int) {
        write(prefs.replacing(maxTransfers: count))
    }

    func setDepartNow(_ now: Bool) {
        departNow = now
        if now { time = Date() }
        scheduleQuery()
    }

    func setTime(_ date: Date) {
        time = date
        departNow = false
        scheduleQuery()
    }

    func setArriveBy(_ on: Bool) {
        arriveBy = on
        scheduleQuery()
    }

    /// Applies the whole snapshot (the shared `DirectionsControls` view).
    func apply(_ snapshot: DirectionsPreferencesSnapshot) {
        write(snapshot)
    }

    func relaxWalkingLimit() {
        write(prefs.replacing(walkToleranceMinutes: 20))
    }

    func allowTransfers() {
        write(prefs.replacing(maxTransfers: 2))
    }

    private func write(_ snapshot: DirectionsPreferencesSnapshot) {
        guard persist(snapshot) else { return }
        scheduleQuery()
    }

    /// Mirrors and saves the snapshot without planning. False when it is
    /// what we already have.
    private func persist(_ snapshot: DirectionsPreferencesSnapshot) -> Bool {
        guard snapshot != prefs else { return false }
        prefs = snapshot
        if let prefsModel {
            prefsModel.apply(snapshot)
            try? context?.save()
        }
        return true
    }

    // MARK: - Planning

    /// The provider's input for the current state, or nil while an
    /// endpoint is missing.
    func buildRequest() -> JourneyRequest? {
        guard let origin, let destination else { return nil }
        return JourneyRequest(origin: origin.coordinate, destination: destination.coordinate,
                              time: departNow ? Date() : time,
                              arriveBy: departNow ? false : arriveBy,
                              preferences: prefs)
    }

    /// The requests one plan is made of: the user's own query first, then
    /// the probes. The rail probe rides only the rail modes the user has on
    /// (Luas included, since it is how most people reach a DART station).
    /// `rainAdjusted` swaps the user's walk limit for the rain limit and
    /// drops the longer-walk probe, which would defeat the point.
    nonisolated static func requests(for base: JourneyRequest, rainAdjusted: Bool = false) -> [JourneyRequest] {
        let prefs = base.preferences
        var main = base
        if rainAdjusted { main.walkToleranceOverrideMinutes = rainWalkMinutes }
        var result = [main]

        let railModes = RankingRules.railModes.intersection(prefs.enabledModes)
        if prefs.preferRail, railModes.contains(.dart) || railModes.contains(.rail) {
            var rail = main
            rail.transitModesOverride = railModes
            result.append(rail)
        }
        if !rainAdjusted, prefs.walkToleranceMinutes <= relaxedProbeCeilingMinutes {
            var relaxed = main
            relaxed.walkToleranceOverrideMinutes = relaxedWalkMinutes
            result.append(relaxed)
        }
        return result
    }

    /// What one round of planning produced, before ranking.
    struct PlanOutcome: Sendable {
        /// Base itineraries first, then each probe's, de-duplicated by id.
        var itineraries: [Itinerary]
        var baseIds: Set<String>
        var baseMinTransitLegs: Int?
    }

    /// Runs `requests` together and merges the answers. The first request is
    /// the base: its failure is only reported when every probe failed too,
    /// and a probe's failure is ignored whenever anything else succeeded.
    nonisolated static func plan(_ requests: [JourneyRequest],
                                 with provider: any JourneyProvider) async throws -> PlanOutcome {
        var results: [Int: Result<[Itinerary], Error>] = [:]
        await withTaskGroup(of: (Int, Result<[Itinerary], Error>).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do { return (index, .success(try await provider.plan(request))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group { results[index] = result }
        }

        var seen: Set<String> = []
        var merged: [Itinerary] = []
        var anySucceeded = false
        for index in requests.indices {
            guard case .success(let found)? = results[index] else { continue }
            anySucceeded = true
            for itinerary in found where seen.insert(itinerary.id).inserted {
                merged.append(itinerary)
            }
        }
        guard anySucceeded else {
            if case .failure(let error)? = results[0] { throw error }
            throw JourneyProviderError.unavailable(status: nil)
        }
        var baseIds: Set<String> = []
        var baseMin: Int?
        if case .success(let base)? = results[0] {
            baseIds = Set(base.map(\.id))
            baseMin = base.map(\.transitLegs.count).filter { $0 > 0 }.min()
        }
        return PlanOutcome(itineraries: merged, baseIds: baseIds, baseMinTransitLegs: baseMin)
    }

    /// Cancels any plan in flight and starts a new one after `debounce`
    /// (or at once). Only the newest generation may publish.
    func scheduleQuery(immediate: Bool = false) {
        queryTask?.cancel()
        generation &+= 1
        let gen = generation
        guard let request = buildRequest() else {
            itineraries = []
            phase = .idle
            dropSelection()
            return
        }
        phase = .loading
        queryTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            await self?.runQuery(request, generation: gen)
        }
    }

    /// One whole search: the plan with its probes, then the forecast and,
    /// when rain is likely, the plan again with shorter walks. Every publish
    /// checks the generation so a superseded search changes nothing.
    private func runQuery(_ request: JourneyRequest, generation gen: Int) async {
        let provider = self.provider
        let prefs = request.preferences
        let outcome: Result<PlanOutcome, Error>
        do {
            outcome = .success(try await Self.plan(Self.requests(for: request), with: provider))
        } catch {
            outcome = .failure(error)
        }
        guard !Task.isCancelled, generation == gen else { return }
        rainAdjusted = false
        publish(outcome)

        guard prefs.rainAware else {
            rainHint = nil
            return
        }
        guard !rainUndoneForSearch, case .success(let planned) = outcome else { return }

        let window = Self.forecastWindow(for: planned.itineraries, around: request.time)
        let hint = await weather.hint(
            origin: request.origin, destination: request.destination,
            originName: origin?.name ?? "the start", destinationName: destination?.name ?? "the destination",
            window: window, threshold: prefs.rainProbabilityThreshold)
        guard !Task.isCancelled, generation == gen else { return }
        rainHint = hint
        guard hint != nil, prefs.walkToleranceMinutes > Self.rainWalkMinutes else { return }

        guard let adjusted = try? await Self.plan(Self.requests(for: request, rainAdjusted: true), with: provider),
              !adjusted.itineraries.isEmpty else { return }
        guard !Task.isCancelled, generation == gen else { return }
        rainAdjusted = true
        publish(.success(adjusted))
    }

    /// First departure to last arrival of what was found, else the planned
    /// time plus `fallbackWindow`.
    nonisolated static func forecastWindow(for itineraries: [Itinerary], around time: Date) -> ClosedRange<Date> {
        guard let first = itineraries.map(\.start).min(), let last = itineraries.map(\.end).max(),
              first <= last else {
            return time...time.addingTimeInterval(fallbackWindow)
        }
        return first...last
    }

    /// Goes back to the user's own walk limit for this journey. The hint
    /// stays on screen; the adjustment is not applied again until an
    /// endpoint changes.
    func undoRainAdjustment() {
        rainUndoneForSearch = true
        rainAdjusted = false
        scheduleQuery(immediate: true)
    }

    private func publish(_ outcome: Result<PlanOutcome, Error>) {
        switch outcome {
        case .success(let planned):
            let ranked = RankingRules.rank(planned.itineraries, context: RankingContext(
                preferRail: prefs.preferRail,
                railWalkCeilingSeconds: prefs.preferRailWalkCeilingMinutes * 60,
                baseIds: planned.baseIds,
                baseMinTransitLegs: planned.baseMinTransitLegs))
            itineraries = ranked
            if ranked.isEmpty {
                phase = .empty(suggestRelaxWalk: prefs.walkToleranceMinutes < 20,
                               suggestTransfers: prefs.maxTransfers == 0)
            } else {
                phase = .results
            }
            // Keep the pick if the same option is still offered.
            if let selectedId, let kept = ranked.first(where: { $0.id == selectedId }) {
                draw(kept)
            } else {
                dropSelection()
            }
        case .failure(let error):
            if let known = error as? JourneyProviderError {
                if known == .cancelled { return }
                phase = .unreachable(message: known.userMessage)
            } else if error is CancellationError {
                return
            } else {
                phase = .unreachable(message: Self.genericFailure)
            }
        }
    }

    // MARK: - Selection

    func select(_ itinerary: Itinerary) {
        selectedId = itinerary.id
        draw(itinerary)
    }

    private func draw(_ itinerary: Itinerary) {
        let label = destination?.name ?? "Directions"
        drawnLabel = label
        store.setDrawnItinerary(itinerary.legs, label: label)
    }

    /// Takes the option off the map and goes back to the list.
    func clearSelection() {
        dropSelection()
    }

    private func dropSelection() {
        selectedId = nil
        drawnLabel = nil
        store.clearDrawnItinerary()
    }

    // MARK: - Lifecycle

    /// The sheet went away. Stops the work in flight and drops the forecast
    /// line, but keeps the endpoints, the list and the drawn option: the map
    /// still shows the journey, and reopening has something to show at once.
    func sheetDismissed() {
        isPresented = false
        queryTask?.cancel()
        queryTask = nil
        generation &+= 1
        rainHint = nil
        if phase == .loading { phase = itineraries.isEmpty ? .idle : .results }
    }

    /// Back to nothing.
    func reset() {
        queryTask?.cancel()
        queryTask = nil
        generation &+= 1
        origin = nil
        destination = nil
        departNow = true
        arriveBy = false
        itineraries = []
        phase = .idle
        resetRainState()
        dropSelection()
    }
}

extension DirectionsPreferencesSnapshot {
    /// A copy with the given fields changed; the initializer re-clamps.
    func replacing(walkToleranceMinutes: Int? = nil, enabledModes: Set<TransitMode>? = nil,
                   allowBikeDirect: Bool? = nil, maxTransfers: Int? = nil,
                   preferRail: Bool? = nil, preferRailWalkCeilingMinutes: Int? = nil,
                   rainAware: Bool? = nil, rainProbabilityThreshold: Int? = nil) -> DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walkToleranceMinutes ?? self.walkToleranceMinutes,
            enabledModes: enabledModes ?? self.enabledModes,
            allowBikeDirect: allowBikeDirect ?? self.allowBikeDirect,
            maxTransfers: maxTransfers ?? self.maxTransfers,
            preferRail: preferRail ?? self.preferRail,
            preferRailWalkCeilingMinutes: preferRailWalkCeilingMinutes ?? self.preferRailWalkCeilingMinutes,
            rainAware: rainAware ?? self.rainAware,
            rainProbabilityThreshold: rainProbabilityThreshold ?? self.rainProbabilityThreshold
        )
    }
}
