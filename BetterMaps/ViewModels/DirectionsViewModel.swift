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
/// rail-only probe (when they prefer rail) and, for each network they have
/// on, a probe with no walk limit so the fastest option on every network is
/// always offered; the user's walk limit then only sorts. With "cycle the
/// whole way" on, the bike router is asked at the same time and its route
/// stands in for the engine's own direct cycle. With rain awareness on, the
/// forecast is checked after the results land and, when a shower is likely,
/// the user's query and the rail probe are run again with a five-minute
/// walk limit; the no-limit probes have no walk limit to shorten, so their
/// first answers are kept and merged back in.
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
    /// How long the bike router may take before the plan goes on without it.
    nonisolated static let cyclingTimeout: Duration = .seconds(8)
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
    /// The options as ranked, with the rows the previews are drawn from.
    private(set) var ranked = RankedItineraries()
    var itineraries: [Itinerary] { ranked.itineraries }
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
    /// `rainWalkMinutes` for ranking costs and limit comparisons. Never nil:
    /// five minutes is a limit, not `noWalkLimit`.
    nonisolated static let rainWalkSeconds = DirectionsPreferencesSnapshot.walkSeconds(forMinutes: rainWalkMinutes) ?? 0
    /// The most `/plan` calls one search makes: the base, the rail probe and
    /// one no-limit probe per network family (bus, Luas, DART/Rail).
    /// Transitous asks clients to stay around 720 calls a day, so a search
    /// must stay cheap; `requests(for:)` drops probes that repeat another.
    nonisolated static let maxPlanCalls = 5
    /// How many options are previewed on the map before one is picked.
    nonisolated static let maxPreviews = 5
    /// Fallback forecast window when the plan found nothing to time it by.
    nonisolated static let fallbackWindow: TimeInterval = 90 * 60

    @ObservationIgnored private let provider: any JourneyProvider
    @ObservationIgnored private let weather: WeatherHintService
    @ObservationIgnored private let cycling: any CyclingRouteProvider
    @ObservationIgnored private let store: TransitLayerStore
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var prefsModel: DirectionsPreferences?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    /// A cycling-only refresh (the style changed); never outlives a re-plan.
    @ObservationIgnored private var cyclingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(provider: any JourneyProvider, store: TransitLayerStore = .shared,
         weather: WeatherHintService = WeatherHintService(),
         cycling: any CyclingRouteProvider = JourneyProviderFactory.makeCycling()) {
        self.provider = provider
        self.store = store
        self.weather = weather
        self.cycling = cycling
    }

    // MARK: - Preferences

    /// Binds to the preferences row. Idempotent; the first call reads it.
    func attach(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        guard let row = try? DirectionsPreferences.ensureRow(in: context) else { return }
        prefsModel = row
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

    /// Reopens the sheet on the search already on the map (the map's
    /// Directions chip). Unlike `start`, nothing about the journey changes:
    /// a picked starting point stays picked, as does the drawn option and a
    /// chosen time, and a "leave now" search re-plans from now.
    func resume() {
        if departNow { time = Date() }
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
        ranked = RankedItineraries()
        dropSelection()
        store.setPreviews([])
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

    /// Stores the style and asks the bike router again; the transit plan is
    /// left alone, since only the cycle option depends on it.
    func setCyclingStyle(_ style: CyclingStyle) {
        guard persist(prefs.replacing(cyclingStyle: style)) else { return }
        refreshCyclingRoute()
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

    /// Applies the whole snapshot (the `DirectionsTripControls` view). A
    /// change to the cycling style alone takes the cycling-only path.
    func apply(_ snapshot: DirectionsPreferencesSnapshot) {
        if snapshot.replacing(cyclingStyle: prefs.cyclingStyle) == prefs {
            setCyclingStyle(snapshot.cyclingStyle)
        } else {
            write(snapshot)
        }
    }

    /// Lifts the walk limit altogether.
    func relaxWalkingLimit() {
        write(prefs.replacing(walkToleranceMinutes: DirectionsPreferencesSnapshot.noWalkLimit))
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

    /// The bike router's question for the same journey: the user's style,
    /// leaving at the planned time.
    nonisolated static func cyclingRequest(for base: JourneyRequest) -> CyclingRouteRequest {
        CyclingRouteRequest(origin: base.origin, destination: base.destination,
                            style: base.preferences.cyclingStyle, departure: base.time)
    }

    /// The network families a no-limit probe is run for, in order.
    nonisolated static let probeFamilies: [Set<TransitMode>] = [[.bus], [.luas], [.dart, .rail]]

    /// The requests one plan is made of: the user's own query first, then
    /// the probes. The rail probe rides only the rail modes the user has on
    /// (Luas included, since it is how most people reach a DART station).
    /// Then one probe per network family the user has on, with no walk
    /// limit, so the fastest bus, tram and train are always among the
    /// options whatever the limit. A probe that would repeat an earlier
    /// request (same networks, same limit) is dropped, keeping a search at
    /// `maxPlanCalls` or fewer. `rainAdjusted` swaps the user's walk limit
    /// for the rain limit on the base and the rail probe and leaves the
    /// family probes out: a no-limit probe has nothing to shorten, so the
    /// caller reuses the first pass's answers (`PlanOutcome.probeItineraries`).
    nonisolated static func requests(for base: JourneyRequest, rainAdjusted: Bool = false) -> [JourneyRequest] {
        let prefs = base.preferences
        var main = base
        if rainAdjusted { main.walkToleranceOverrideMinutes = rainWalkMinutes }
        var result = [main]
        func add(_ probe: JourneyRequest) {
            let repeats = result.contains {
                $0.effectiveTransitModes == probe.effectiveTransitModes
                    && $0.effectiveWalkToleranceMinutes == probe.effectiveWalkToleranceMinutes
            }
            if !repeats { result.append(probe) }
        }

        let railModes = RankingRules.railModes.intersection(prefs.enabledModes)
        if prefs.preferRail, railModes.contains(.dart) || railModes.contains(.rail) {
            var rail = main
            rail.transitModesOverride = railModes
            add(rail)
        }
        guard !rainAdjusted else { return result }
        for family in probeFamilies {
            let modes = family.intersection(prefs.allowedTransitModes)
            guard !modes.isEmpty else { continue }
            var probe = base
            probe.transitModesOverride = modes
            probe.walkToleranceOverrideMinutes = DirectionsPreferencesSnapshot.noWalkLimit
            add(probe)
        }
        assert(result.count <= maxPlanCalls)
        return result
    }

    /// A per-network probe with no walk limit.
    nonisolated static func isFamilyProbe(_ request: JourneyRequest) -> Bool {
        request.transitModesOverride != nil
            && request.walkToleranceOverrideMinutes == DirectionsPreferencesSnapshot.noWalkLimit
    }

    /// A bike route to ask for alongside the transit plan.
    struct CyclingJob: Sendable {
        let provider: any CyclingRouteProvider
        let request: CyclingRouteRequest
    }

    /// What one round of planning produced, before ranking.
    struct PlanOutcome: Sendable {
        /// Base itineraries first, then each probe's, de-duplicated by id,
        /// with the bike router's option standing in for the engine's own
        /// direct cycle when it answered.
        var itineraries: [Itinerary]
        /// The bike router's answer, when asked and it came in time.
        var bike: Itinerary?
        /// What the no-limit family probes found, kept apart so a rain
        /// re-plan can merge them in without asking again.
        var probeItineraries: [Itinerary]

        init(itineraries: [Itinerary], bike: Itinerary? = nil, probeItineraries: [Itinerary] = []) {
            self.itineraries = itineraries
            self.bike = bike
            self.probeItineraries = probeItineraries
        }
    }

    private enum PlanPart: Sendable {
        case transit(Int, Result<[Itinerary], Error>)
        case bike(Itinerary?)
    }

    /// Runs `requests` together (and the cycling job, when given) and merges
    /// the answers. The first request is the base: its failure is only
    /// reported when every probe failed too, and a probe's failure is
    /// ignored whenever anything else succeeded. A bike router failure or
    /// timeout is silent: the engine's own direct cycle, if any, stays.
    nonisolated static func plan(_ requests: [JourneyRequest],
                                 with provider: any JourneyProvider,
                                 cycling: CyclingJob? = nil) async throws -> PlanOutcome {
        var results: [Int: Result<[Itinerary], Error>] = [:]
        var bike: Itinerary?
        await withTaskGroup(of: PlanPart.self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do { return .transit(index, .success(try await provider.plan(request))) }
                    catch { return .transit(index, .failure(error)) }
                }
            }
            if let cycling {
                group.addTask { .bike(await cyclingOption(cycling)) }
            }
            for await part in group {
                switch part {
                case .transit(let index, let result): results[index] = result
                case .bike(let found): bike = found
                }
            }
        }

        var answers: [[Itinerary]] = []
        var probeAnswers: [[Itinerary]] = []
        for index in requests.indices {
            guard case .success(let found)? = results[index] else { continue }
            answers.append(found)
            if isFamilyProbe(requests[index]) { probeAnswers.append(found) }
        }
        guard !answers.isEmpty else {
            if case .failure(let error)? = results[0] { throw error }
            throw JourneyProviderError.unavailable(status: nil)
        }
        var merged = deduplicated(answers)
        if let bike { merged = merging(bike: bike, into: merged) }
        return PlanOutcome(itineraries: merged, bike: bike, probeItineraries: deduplicated(probeAnswers))
    }

    /// The groups in order, each option once (by id) at its first appearance.
    nonisolated static func deduplicated(_ groups: [[Itinerary]]) -> [Itinerary] {
        var seen: Set<String> = []
        var merged: [Itinerary] = []
        for group in groups {
            for itinerary in group where seen.insert(itinerary.id).inserted {
                merged.append(itinerary)
            }
        }
        return merged
    }

    /// The bike router's answer, or nil when it failed or took longer than
    /// `timeout`; the slow request is cancelled.
    nonisolated static func cyclingOption(_ job: CyclingJob, timeout: Duration = cyclingTimeout) async -> Itinerary? {
        await withTaskGroup(of: Itinerary?.self) { group in
            group.addTask { try? await job.provider.route(job.request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Puts the bike router's option where the engine's direct cycle was
    /// (any further all-bike options go), or at the end when there was none.
    nonisolated static func merging(bike: Itinerary, into itineraries: [Itinerary]) -> [Itinerary] {
        var result: [Itinerary] = []
        result.reserveCapacity(itineraries.count + 1)
        var placed = false
        for itinerary in itineraries {
            if RankingRules.isBikeOnly(itinerary) {
                if !placed {
                    result.append(bike)
                    placed = true
                }
            } else {
                result.append(itinerary)
            }
        }
        if !placed { result.append(bike) }
        return result
    }

    /// Cancels any plan in flight and starts a new one after `debounce`
    /// (or at once). Only the newest generation may publish.
    func scheduleQuery(immediate: Bool = false) {
        queryTask?.cancel()
        cyclingTask?.cancel()
        generation &+= 1
        let gen = generation
        pinEndpoints()
        guard let request = buildRequest() else {
            ranked = RankedItineraries()
            phase = .idle
            dropSelection()
            store.setPreviews([])
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

    /// One whole search: the plan with its probes (and the bike route), then
    /// the forecast and, when rain is likely, the plan again with shorter
    /// walks. Every publish checks the generation so a superseded search
    /// changes nothing.
    private func runQuery(_ request: JourneyRequest, generation gen: Int) async {
        let provider = self.provider
        let prefs = request.preferences
        let cyclingJob = prefs.allowBikeDirect
            ? CyclingJob(provider: cycling, request: Self.cyclingRequest(for: request)) : nil
        let outcome: Result<PlanOutcome, Error>
        do {
            outcome = .success(try await Self.plan(Self.requests(for: request), with: provider, cycling: cyclingJob))
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
        guard hint != nil, prefs.walkToleranceSeconds.map({ $0 > Self.rainWalkSeconds }) ?? true else { return }

        // Only the base and the rail probe have a limit to shorten. The
        // family probes' answers and the bike route do not depend on it:
        // both are reused from the first pass.
        guard var adjusted = try? await Self.plan(Self.requests(for: request, rainAdjusted: true), with: provider) else { return }
        guard !Task.isCancelled, generation == gen else { return }
        adjusted.itineraries = Self.deduplicated([adjusted.itineraries, planned.probeItineraries])
        adjusted.probeItineraries = planned.probeItineraries
        guard !adjusted.itineraries.isEmpty else { return }
        if let bike = planned.bike {
            adjusted.itineraries = Self.merging(bike: bike, into: adjusted.itineraries)
            adjusted.bike = bike
        }
        rainAdjusted = true
        publish(.success(adjusted))
    }

    /// Asks the bike router again with the current style and swaps the
    /// answer in for the cycle option on screen. The transit results stay as
    /// they are; a re-plan started meanwhile wins.
    private func refreshCyclingRoute() {
        cyclingTask?.cancel()
        guard prefs.allowBikeDirect, let request = buildRequest() else { return }
        let job = CyclingJob(provider: cycling, request: Self.cyclingRequest(for: request))
        let gen = generation
        cyclingTask = Task { [weak self] in
            guard let bike = await Self.cyclingOption(job) else { return }
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.replaceBikeOption(with: bike)
        }
    }

    private func replaceBikeOption(with bike: Itinerary) {
        let bikeWasSelected = selectedItinerary.map(RankingRules.isBikeOnly) ?? false
        ranked = RankingRules.rank(Self.merging(bike: bike, into: itineraries), context: rankingContext)
        if case .empty = phase { phase = .results }
        if bikeWasSelected {
            select(bike)
        } else if selectedId == nil {
            store.setPreviews(Self.previewLegs(ranked))
        }
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

    /// The ranking inputs for the current preferences. When the results were
    /// planned for rain, walks beyond the rain limit are what cost extra.
    private var rankingContext: RankingContext {
        var enabled = prefs.allowedTransitModes
        if prefs.allowBikeDirect { enabled.insert(.bike) }
        return RankingContext(
            preferRail: prefs.preferRail,
            railWalkCeilingSeconds: prefs.preferRailWalkCeilingMinutes * 60,
            walkToleranceSeconds: rainAdjusted ? Self.rainWalkSeconds : prefs.walkToleranceSeconds,
            enabledModes: enabled)
    }

    private func publish(_ outcome: Result<PlanOutcome, Error>) {
        switch outcome {
        case .success(let planned):
            ranked = RankingRules.rank(planned.itineraries, context: rankingContext)
            if itineraries.isEmpty {
                // With a network on, a no-limit probe already ran for it, so
                // lifting the walk limit cannot find anything more.
                let probed = !prefs.allowedTransitModes.isEmpty
                phase = .empty(suggestRelaxWalk: prefs.walkToleranceSeconds != nil && !probed,
                               suggestTransfers: prefs.maxTransfers == 0)
            } else {
                phase = .results
            }
            // Keep the pick if the same option is still offered; otherwise
            // the map shows the previews.
            if let selectedId, let kept = itineraries.first(where: { $0.id == selectedId }) {
                draw(kept)
            } else {
                dropSelection()
                store.setPreviews(Self.previewLegs(ranked))
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

    /// Takes the option off the map and goes back to the list; the previews
    /// come back.
    func clearSelection() {
        dropSelection()
        store.setPreviews(Self.previewLegs(ranked))
    }

    /// Takes everything the search drew off the map (the chip's clear, a tap
    /// on empty map). The list stays for the sheet.
    func clearMap() {
        dropSelection()
        store.clearDirectionsEndpoints()
    }

    /// The map's clear chip. With the sheet up it only puts the picked
    /// option back in the list (the previews and pins are the sheet's
    /// context); with the sheet away it clears the map.
    func chipCleared() {
        if isPresented { clearSelection() } else { clearMap() }
    }

    private func dropSelection() {
        selectedId = nil
        drawnLabel = nil
        store.clearDrawnItinerary()
    }

    /// The options worth previewing before one is picked: the ranker's
    /// guaranteed rows (the first, the rail pin, the fastest per network and
    /// the bike), in list order, at most `maxPreviews`.
    nonisolated static func previewLegs(_ ranked: RankedItineraries) -> [[Leg]] {
        ranked.guaranteed.prefix(maxPreviews).map(\.legs)
    }

    /// Marks the search's ends on the map as soon as they are known. The
    /// user's own location is not marked twice.
    private func pinEndpoints() {
        guard let destination else {
            store.clearDirectionsEndpoints()
            return
        }
        let originPin = origin.flatMap { $0.isUserLocation ? nil : $0.coordinate }
        store.setDirectionsEndpoints(DirectionsEndpoints(origin: originPin, destination: destination.coordinate))
    }

    // MARK: - Lifecycle

    /// The sheet went away. Stops the work in flight and drops the forecast
    /// line. With results, the endpoints, the list and the drawn option
    /// stay: the map still shows the journey, and reopening has something
    /// to show at once. Without any, the pins go too, or they would mark a
    /// search nothing came of.
    func sheetDismissed() {
        isPresented = false
        queryTask?.cancel()
        queryTask = nil
        cyclingTask?.cancel()
        cyclingTask = nil
        generation &+= 1
        rainHint = nil
        if phase == .loading { phase = itineraries.isEmpty ? .idle : .results }
        if phase != .results { clearMap() }
    }

    /// Back to nothing.
    func reset() {
        queryTask?.cancel()
        queryTask = nil
        cyclingTask?.cancel()
        cyclingTask = nil
        generation &+= 1
        origin = nil
        destination = nil
        departNow = true
        arriveBy = false
        ranked = RankedItineraries()
        phase = .idle
        resetRainState()
        clearMap()
    }
}

extension DirectionsPreferencesSnapshot {
    /// A copy with the given fields changed; the initializer re-clamps.
    func replacing(walkToleranceMinutes: Int? = nil, enabledModes: Set<TransitMode>? = nil,
                   allowBikeDirect: Bool? = nil, maxTransfers: Int? = nil,
                   preferRail: Bool? = nil, preferRailWalkCeilingMinutes: Int? = nil,
                   rainAware: Bool? = nil, rainProbabilityThreshold: Int? = nil,
                   cyclingStyle: CyclingStyle? = nil) -> DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walkToleranceMinutes ?? self.walkToleranceMinutes,
            enabledModes: enabledModes ?? self.enabledModes,
            allowBikeDirect: allowBikeDirect ?? self.allowBikeDirect,
            maxTransfers: maxTransfers ?? self.maxTransfers,
            preferRail: preferRail ?? self.preferRail,
            preferRailWalkCeilingMinutes: preferRailWalkCeilingMinutes ?? self.preferRailWalkCeilingMinutes,
            rainAware: rainAware ?? self.rainAware,
            rainProbabilityThreshold: rainProbabilityThreshold ?? self.rainProbabilityThreshold,
            cyclingStyle: cyclingStyle ?? self.cyclingStyle
        )
    }
}
