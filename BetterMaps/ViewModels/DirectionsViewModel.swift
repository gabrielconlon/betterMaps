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
    private(set) var prefs: DirectionsPreferencesSnapshot = .default
    private(set) var itineraries: [Itinerary] = []
    var selectedId: Itinerary.ID?
    private(set) var phase: Phase = .idle
    /// Chip text for the drawn option; nil when nothing is drawn.
    var drawnLabel: String?

    @ObservationIgnored private let provider: any JourneyProvider
    @ObservationIgnored private let store: TransitLayerStore
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var prefsModel: DirectionsPreferences?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(provider: any JourneyProvider, store: TransitLayerStore = .shared) {
        self.provider = provider
        self.store = store
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

    /// Re-reads the row (Settings or another device changed it) and
    /// re-plans if anything differs.
    func refreshPrefs() {
        guard let context else { return }
        guard let row = try? DirectionsPreferences.fetchOrCreate(in: context) else { return }
        if row !== prefsModel { prefsModel = row }
        let fresh = row.snapshot
        guard fresh != prefs else { return }
        prefs = fresh
        scheduleQuery()
    }

    var selectedItinerary: Itinerary? {
        guard let selectedId else { return nil }
        return itineraries.first { $0.id == selectedId }
    }

    // MARK: - Endpoints

    /// Opens the sheet for `destination`. With a location the origin is
    /// "My Location" and planning starts at once; without one the phase
    /// stays idle until the user picks a starting point.
    func start(destination: DirectionsEndpoint, userLocation: CLLocationCoordinate2D?) {
        self.userLocation = userLocation
        self.destination = destination
        if let userLocation {
            origin = .userLocation(userLocation)
        } else if origin?.isUserLocation == true {
            origin = nil
        }
        departNow = true
        time = Date()
        clearSelection()
        scheduleQuery(immediate: true)
    }

    func setOrigin(_ endpoint: DirectionsEndpoint) {
        origin = endpoint
        scheduleQuery(immediate: true)
    }

    func setDestination(_ endpoint: DirectionsEndpoint) {
        destination = endpoint
        scheduleQuery(immediate: true)
    }

    func swapEndpoints() {
        (origin, destination) = (destination, origin)
        scheduleQuery(immediate: true)
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
        guard snapshot != prefs else { return }
        prefs = snapshot
        if let prefsModel {
            prefsModel.apply(snapshot)
            try? context?.save()
        }
        scheduleQuery()
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
        let provider = self.provider
        queryTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            let outcome: Result<[Itinerary], Error>
            do {
                outcome = .success(try await provider.plan(request))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.publish(outcome)
        }
    }

    private func publish(_ outcome: Result<[Itinerary], Error>) {
        switch outcome {
        case .success(let found):
            let ranked = RankingRules.rank(found, context: RankingContext(
                preferRail: prefs.preferRail,
                railWalkCeilingSeconds: prefs.preferRailWalkCeilingMinutes * 60))
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

    /// Back to nothing: the sheet closed.
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
        dropSelection()
    }
}

extension DirectionsPreferencesSnapshot {
    /// A copy with the given fields changed; the initializer re-clamps.
    func replacing(walkToleranceMinutes: Int? = nil, enabledModes: Set<TransitMode>? = nil,
                   allowBikeDirect: Bool? = nil, maxTransfers: Int? = nil) -> DirectionsPreferencesSnapshot {
        DirectionsPreferencesSnapshot(
            walkToleranceMinutes: walkToleranceMinutes ?? self.walkToleranceMinutes,
            enabledModes: enabledModes ?? self.enabledModes,
            allowBikeDirect: allowBikeDirect ?? self.allowBikeDirect,
            maxTransfers: maxTransfers ?? self.maxTransfers,
            preferRail: preferRail,
            preferRailWalkCeilingMinutes: preferRailWalkCeilingMinutes,
            rainAware: rainAware,
            rainProbabilityThreshold: rainProbabilityThreshold
        )
    }
}
