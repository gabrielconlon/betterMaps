import XCTest
import CoreLocation
import SwiftData
@testable import CustomMapApp

/// A planner the tests steer: records every request, answers with a set
/// result (or error) after an optional delay.
final class FakeJourneyProvider: JourneyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [JourneyRequest] = []
    private var _result: Result<[Itinerary], Error> = .success([])
    private var _delay: Duration = .zero

    var requests: [JourneyRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Requests without any override: the user's own query, not a probe.
    var baseRequests: [JourneyRequest] {
        requests.filter { $0.transitModesOverride == nil && $0.walkToleranceOverrideMinutes == nil }
    }

    /// The rail-only probe: a mode override at the base's walk limit.
    var railProbes: [JourneyRequest] {
        requests.filter { $0.transitModesOverride != nil && $0.walkToleranceOverrideMinutes != DirectionsPreferencesSnapshot.noWalkLimit }
    }

    /// The per-network probes with no walk limit, in request order.
    var familyProbes: [JourneyRequest] {
        requests.filter { $0.transitModesOverride != nil && $0.walkToleranceOverrideMinutes == DirectionsPreferencesSnapshot.noWalkLimit }
    }

    func walkProbes(_ minutes: Int) -> [JourneyRequest] {
        requests.filter { $0.transitModesOverride == nil && $0.walkToleranceOverrideMinutes == minutes }
    }

    var result: Result<[Itinerary], Error> {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); _result = newValue; lock.unlock() }
    }

    var delay: Duration {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }

    func plan(_ request: JourneyRequest) async throws -> [Itinerary] {
        // Captured at call time, so a later change answers only later calls.
        let (answer, wait): (Result<[Itinerary], Error>, Duration) = {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            return (_result, _delay)
        }()
        if wait > .zero { try await Task.sleep(for: wait) }
        return try answer.get()
    }
}

/// A bike router the tests steer: records every request and answers with a
/// set itinerary (or error) after an optional delay. Fails by default so the
/// transit results in older tests stay exactly what the planner gave.
final class FakeCyclingProvider: CyclingRouteProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [CyclingRouteRequest] = []
    private var _result: Result<Itinerary, Error> = .failure(JourneyProviderError.unavailable(status: 503))
    private var _delay: Duration = .zero

    var requests: [CyclingRouteRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var result: Result<Itinerary, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); _result = newValue; lock.unlock() }
    }

    var delay: Duration {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }

    func route(_ request: CyclingRouteRequest) async throws -> Itinerary {
        let (answer, wait): (Result<Itinerary, Error>, Duration) = {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
            return (_result, _delay)
        }()
        if wait > .zero { try await Task.sleep(for: wait) }
        return try answer.get()
    }
}

/// A weather service answering every point from one fixture, or failing
/// like a device offline when given none; counts the requests it saw.
final class FakeWeather: @unchecked Sendable {
    private let box: WeatherLoaderBox
    let service: WeatherHintService

    init(fixture: WeatherFixture? = nil) {
        let box = WeatherLoaderBox()
        let data = fixture.flatMap { try? $0.data() }
        self.box = box
        self.service = WeatherHintService(loader: { request in
            box.record(request)
            guard let data else { throw URLError(.notConnectedToInternet) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    var calls: Int { box.count }
}

/// A planner that answers each request from a closure, so probes and the
/// base can be told apart and made to succeed or fail separately. Every
/// request is logged.
struct RoutingFakeProvider: JourneyProvider {
    let route: @Sendable (JourneyRequest) throws -> [Itinerary]
    let log = RequestLog()
    func plan(_ request: JourneyRequest) async throws -> [Itinerary] {
        log.record(request)
        return try route(request)
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [JourneyRequest] = []
    var requests: [JourneyRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func record(_ request: JourneyRequest) { lock.lock(); _requests.append(request); lock.unlock() }
}

@MainActor
final class DirectionsViewModelTests: XCTestCase {
    private let heuston = DirectionsEndpoint(name: "Heuston", coordinate: CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923))
    private let dunLaoghaire = DirectionsEndpoint(name: "Dún Laoghaire", coordinate: CLLocationCoordinate2D(latitude: 53.2938, longitude: -6.1353))
    /// 2027-01-15T08:00:00Z, two hours into the weather fixtures.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeItinerary(_ id: String, minutes: Int = 30, startOffsetHours: Int = 0,
                               modes: [TransitMode] = [.bus]) -> Itinerary {
        let start = t0.addingTimeInterval(TimeInterval(startOffsetHours) * 3600)
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let each = minutes * 60 / modes.count
        let legs = modes.enumerated().map { index, mode in
            Leg(id: "\(id)-leg\(index == 0 ? "" : String(index))", mode: mode,
                routeShortName: mode.isTransit ? "39A" : nil, fromName: "A", toName: "B",
                start: start.addingTimeInterval(TimeInterval(index * each)),
                end: start.addingTimeInterval(TimeInterval((index + 1) * each)), durationSeconds: each,
                coordinates: [heuston.coordinate, dunLaoghaire.coordinate])
        }
        return Itinerary(id: id, legs: legs, start: start, end: end, durationSeconds: minutes * 60,
                         transfers: max(modes.filter(\.isTransit).count - 1, 0), walkSeconds: 0, bikeSeconds: 0)
    }

    /// A cycle the whole way, as the bike router or the engine would give it.
    private func makeBike(_ id: String, minutes: Int = 25, reason: String? = nil) -> Itinerary {
        let end = t0.addingTimeInterval(TimeInterval(minutes * 60))
        let leg = Leg(id: "\(id)-leg", mode: .bike, fromName: "Start", toName: "Destination",
                      start: t0, end: end, durationSeconds: minutes * 60,
                      coordinates: [heuston.coordinate, dunLaoghaire.coordinate])
        return Itinerary(id: id, legs: [leg], start: t0, end: end, durationSeconds: minutes * 60,
                         transfers: 0, walkSeconds: 0, bikeSeconds: minutes * 60, reason: reason)
    }

    private func makeModel(_ provider: FakeJourneyProvider, store: TransitLayerStore = TransitLayerStore(),
                           weather: FakeWeather = FakeWeather(),
                           cycling: FakeCyclingProvider = FakeCyclingProvider()) -> DirectionsViewModel {
        let model = DirectionsViewModel(provider: provider, store: store, weather: weather.service, cycling: cycling)
        model.origin = heuston
        model.destination = dunLaoghaire
        return model
    }

    /// Lets the planner's task hop back to the main actor.
    private func settle(_ duration: Duration = .milliseconds(100)) async {
        try? await Task.sleep(for: duration)
    }

    // MARK: Request building

    func testRequestReflectsControls() {
        let provider = FakeJourneyProvider()
        let model = makeModel(provider)
        model.setWalkTolerance(15)
        model.toggleMode(.bus)        // off
        model.toggleMode(.rail)       // off
        model.setBikeDirect(false)
        model.setMaxTransfers(1)
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        model.setTime(at)
        model.setArriveBy(true)

        let request = model.buildRequest()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.preferences.walkToleranceMinutes, 15)
        XCTAssertEqual(request?.preferences.enabledModes, [.luas, .dart])
        XCTAssertEqual(request?.preferences.allowBikeDirect, false)
        XCTAssertEqual(request?.preferences.maxTransfers, 1)
        XCTAssertEqual(request?.time, at)
        XCTAssertEqual(request?.arriveBy, true)
        XCTAssertEqual(request?.origin.latitude, heuston.coordinate.latitude)
        XCTAssertEqual(request?.destination.longitude, dunLaoghaire.coordinate.longitude)
    }

    func testLeaveNowIgnoresArriveByAndStoredTime() {
        let model = makeModel(FakeJourneyProvider())
        model.setTime(Date(timeIntervalSince1970: 1_900_000_000))
        model.setArriveBy(true)
        model.setDepartNow(true)
        let request = model.buildRequest()
        XCTAssertEqual(request?.arriveBy, false)
        XCTAssertGreaterThan(request?.time ?? .distantPast, Date().addingTimeInterval(-5))
    }

    func testNoRequestWithoutBothEndpoints() {
        let model = DirectionsViewModel(provider: FakeJourneyProvider(), store: TransitLayerStore(),
                                        weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.destination = dunLaoghaire
        XCTAssertNil(model.buildRequest())
        model.scheduleQuery(immediate: true)
        XCTAssertEqual(model.phase, .idle)
    }

    func testStartWithoutLocationStaysIdle() {
        let provider = FakeJourneyProvider()
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore(), weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.start(destination: dunLaoghaire, userLocation: nil)
        XCTAssertNil(model.origin)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testStartWithLocationPlansFromMyLocation() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore(), weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.start(destination: dunLaoghaire, userLocation: heuston.coordinate)
        XCTAssertEqual(model.origin?.isUserLocation, true)
        await settle()
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"])
    }

    func testSwapEndpoints() {
        let model = makeModel(FakeJourneyProvider())
        model.swapEndpoints()
        XCTAssertEqual(model.origin, dunLaoghaire)
        XCTAssertEqual(model.destination, heuston)
    }

    // MARK: Debounce and cancellation

    func testThreeQuickWritesPlanOnce() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = makeModel(provider)
        model.setWalkTolerance(5)
        try? await Task.sleep(for: .milliseconds(40))
        model.setWalkTolerance(15)
        try? await Task.sleep(for: .milliseconds(40))
        model.setMaxTransfers(3)
        XCTAssertEqual(model.phase, .loading)
        await settle(DirectionsViewModel.debounce + .milliseconds(300))
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(provider.requests.count, 5, "one plan: the base, its rail probe and three family probes")
        XCTAssertEqual(provider.baseRequests.first?.preferences.walkToleranceMinutes, 15)
        XCTAssertEqual(provider.baseRequests.first?.preferences.maxTransfers, 3)
        XCTAssertEqual(model.phase, .results)
    }

    func testSlowFirstPlanIsSupersededAndItsResultDropped() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("stale")])
        provider.delay = .milliseconds(300)
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        try? await Task.sleep(for: .milliseconds(50))
        provider.result = .success([makeItinerary("fresh")])
        provider.delay = .zero
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(500))
        XCTAssertEqual(provider.baseRequests.count, 2)
        XCTAssertEqual(model.itineraries.map(\.id), ["fresh"])
        XCTAssertEqual(model.phase, .results)
    }

    // MARK: Selection and the map

    func testSelectDrawsOnStoreAndClearRemoves() async {
        let provider = FakeJourneyProvider()
        let option = makeItinerary("a")
        provider.result = .success([option])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.scheduleQuery(immediate: true)
        await settle()

        XCTAssertEqual(store.previewItineraries, [option.legs], "the results are previewed before a pick")
        XCTAssertEqual(store.directionsEndpoints, DirectionsEndpoints(origin: heuston.coordinate,
                                                                      destination: dunLaoghaire.coordinate))

        model.select(option)
        XCTAssertEqual(model.selectedId, "a")
        XCTAssertEqual(store.drawnItinerary?.map(\.id), ["a-leg"])
        XCTAssertEqual(store.drawnItineraryLabel, "Dún Laoghaire")
        XCTAssertEqual(model.drawnLabel, "Dún Laoghaire")
        XCTAssertTrue(store.previewItineraries.isEmpty, "the picked journey is the map's one story")
        XCTAssertNotNil(store.directionsEndpoints, "the pins stay")

        model.clearSelection()
        XCTAssertNil(model.selectedId)
        XCTAssertNil(store.drawnItinerary)
        XCTAssertNil(store.drawnItineraryLabel)
        XCTAssertNil(model.drawnLabel)
        XCTAssertEqual(store.previewItineraries, [option.legs], "back to the list, previews back")
        XCTAssertNotNil(store.directionsEndpoints)

        model.clearMap()
        XCTAssertTrue(store.previewItineraries.isEmpty)
        XCTAssertNil(store.directionsEndpoints)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"], "the list is kept for the sheet")
    }

    func testPreviewsAreTheFastestPerModeAndTheUsersOwnLocationIsNotPinned() async {
        let provider = FakeJourneyProvider()
        let buses = (0..<6).map { makeItinerary("bus\($0)", minutes: 30 + $0, modes: [.walk, .bus, .walk]) }
        let dart = makeItinerary("dart", minutes: 50, modes: [.walk, .dart, .walk])
        let luas = makeItinerary("luas", minutes: 55, modes: [.walk, .luas, .walk])
        provider.result = .success(buses + [dart, luas])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(preferRail: false))
        model.start(destination: dunLaoghaire, userLocation: heuston.coordinate)
        XCTAssertEqual(store.directionsEndpoints, DirectionsEndpoints(origin: nil, destination: dunLaoghaire.coordinate),
                       "pinned before the plan answers; My Location is already on the map")
        await settle()
        XCTAssertEqual(model.itineraries.map(\.reason), [nil, nil, nil, nil, nil, nil, "Fastest by DART", "Fastest by Luas"])
        XCTAssertEqual(store.previewItineraries, [buses[0].legs, dart.legs, luas.legs],
                       "the first row and the fastest on each other network")

        let previews = DirectionsViewModel.previewLegs(model.ranked)
        XCTAssertEqual(previews.count, 3)
        XCTAssertEqual(model.ranked.guaranteedIds, ["bus0", "dart", "luas"])
        XCTAssertLessThanOrEqual(previews.count, DirectionsViewModel.maxPreviews)

        model.reset()
        XCTAssertTrue(store.previewItineraries.isEmpty)
        XCTAssertNil(store.directionsEndpoints)
    }

    func testBikeWithTheRoutersOwnReasonIsPreviewed() async {
        let provider = FakeJourneyProvider()
        let buses = (0..<3).map { makeItinerary("bus\($0)", minutes: 30 + $0, modes: [.walk, .bus, .walk]) }
        provider.result = .success(buses)
        let cycling = FakeCyclingProvider()
        let quiet = makeBike("bike", minutes: 60, reason: "Quiet roads")
        cycling.result = .success(quiet)
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store, cycling: cycling)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(preferRail: false).replacing(allowBikeDirect: true))
        model.scheduleQuery(immediate: true)
        await settle()

        XCTAssertEqual(model.itineraries.map(\.id), ["bus0", "bus1", "bus2", "bike"])
        XCTAssertEqual(model.itineraries.last?.reason, "Quiet roads", "the router's words, not \"Fastest by Bike\"")
        XCTAssertTrue(model.ranked.guaranteedIds.contains("bike"))
        XCTAssertEqual(store.previewItineraries, [buses[0].legs, quiet.legs],
                       "the only cycle option is previewed whatever its chip says")
    }

    func testPreviewsAreIgnoredWhileAnOptionIsDrawn() {
        let store = TransitLayerStore()
        let a = makeItinerary("a")
        store.setDrawnItinerary(a.legs, label: "Home")
        store.setPreviews([a.legs])
        XCTAssertTrue(store.previewItineraries.isEmpty)
        store.clearDrawnItinerary()
        store.setPreviews([a.legs])
        XCTAssertEqual(store.previewItineraries.count, 1)
        store.toggleHighlightedRoute("r1", label: "39A")
        XCTAssertTrue(store.previewItineraries.isEmpty, "a highlighted route replaces the previews too")
        store.clearHighlightedRoute()
    }

    func testSheetDismissedWithoutResultsClearsThePinsAndWithResultsKeepsThem() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.isPresented = true
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertNotNil(store.directionsEndpoints, "pinned while the sheet shows the empty state")
        if case .empty = model.phase {} else { XCTFail("expected empty, got \(model.phase)") }
        model.sheetDismissed()
        XCTAssertNil(store.directionsEndpoints, "nothing came of the search: no pins left behind")
        XCTAssertFalse(store.hasDirectionsContent)

        provider.result = .failure(JourneyProviderError.unavailable(status: 503))
        model.isPresented = true
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertNotNil(store.directionsEndpoints)
        model.sheetDismissed()
        XCTAssertNil(store.directionsEndpoints, "unreachable counts as no results")

        let a = makeItinerary("a")
        provider.result = .success([a])
        model.isPresented = true
        model.scheduleQuery(immediate: true)
        await settle()
        model.sheetDismissed()
        XCTAssertEqual(model.phase, .results)
        XCTAssertNotNil(store.directionsEndpoints, "the journey stays on the map")
        XCTAssertEqual(store.previewItineraries, [a.legs])
        XCTAssertTrue(store.hasDirectionsContent)
    }

    func testChipClearKeepsContextWhileTheSheetIsUpAndClearsTheMapOtherwise() async {
        let provider = FakeJourneyProvider()
        let a = makeItinerary("a")
        provider.result = .success([a])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.isPresented = true
        model.scheduleQuery(immediate: true)
        await settle()
        model.select(a)
        XCTAssertNotNil(store.drawnItinerary)

        model.chipCleared()
        XCTAssertNil(model.selectedId, "the option goes back in the list")
        XCTAssertNil(store.drawnItinerary)
        XCTAssertEqual(store.previewItineraries, [a.legs], "the previews come back")
        XCTAssertNotNil(store.directionsEndpoints, "the pins stay: the sheet is still about this journey")
        XCTAssertTrue(store.hasDirectionsContent, "so the chip stays too")

        model.select(a)
        model.sheetDismissed()
        model.chipCleared()
        XCTAssertNil(model.selectedId)
        XCTAssertNil(store.drawnItinerary)
        XCTAssertTrue(store.previewItineraries.isEmpty)
        XCTAssertNil(store.directionsEndpoints, "with the sheet away, the chip clears the map")
        XCTAssertFalse(store.hasDirectionsContent)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"], "the list is kept for a reopen")
    }

    func testSelectionSurvivesRequeryWhenStillOffered() async {
        let provider = FakeJourneyProvider()
        let a = makeItinerary("a"), b = makeItinerary("b", minutes: 40)
        provider.result = .success([a, b])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.scheduleQuery(immediate: true)
        await settle()
        model.select(b)

        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.selectedId, "b")
        XCTAssertEqual(store.drawnItinerary?.map(\.id), ["b-leg"])

        provider.result = .success([a])
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertNil(model.selectedId)
        XCTAssertNil(store.drawnItinerary)
    }

    func testDrawnItineraryAndHighlightedRouteAreExclusive() {
        let store = TransitLayerStore()
        store.toggleHighlightedRoute("r1", label: "39A")
        store.setDrawnItinerary([makeItinerary("a").legs[0]], label: "Home")
        XCTAssertNil(store.highlightedRouteId)
        XCTAssertNotNil(store.drawnItinerary)
        store.toggleHighlightedRoute("r1", label: "39A")
        XCTAssertNil(store.drawnItinerary)
        XCTAssertEqual(store.highlightedRouteId, "r1")
        store.clearHighlightedRoute()
    }

    // MARK: Outcomes

    func testEmptyResultAtDefaultsDoesNotSuggestRelaxingWalk() async {
        // The no-limit probes already ran for every network that is on, so a
        // longer walk cannot turn anything up.
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.familyProbes.count, 3)
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: false, suggestTransfers: false))
    }

    func testEmptyResultWithoutAnyNetworkOnSuggestsRelaxingWalk() async {
        // Nothing to probe without a network: the user's own limit is the
        // only thing that was planned with.
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let model = makeModel(provider)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bike]))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.requests.count, 1, "just the base")
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: true, suggestTransfers: false))

        model.setWalkTolerance(DirectionsPreferencesSnapshot.noWalkLimit)
        model.setMaxTransfers(0)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: false, suggestTransfers: true),
                       "nothing to relax when any walk is already fine; the transfer hint is untouched")
    }

    func testEmptyResultAtZeroTransfersSuggestsChanges() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let model = makeModel(provider)
        model.setWalkTolerance(DirectionsPreferencesSnapshot.noWalkLimit)
        model.setMaxTransfers(0)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: false, suggestTransfers: true),
                       "nothing to relax when any walk is already fine")
        model.allowTransfers()
        XCTAssertEqual(model.prefs.maxTransfers, 2)
        model.setWalkTolerance(20)
        model.relaxWalkingLimit()
        XCTAssertEqual(model.prefs.walkToleranceMinutes, DirectionsPreferencesSnapshot.noWalkLimit, "lifts the limit")
    }

    func testUnavailableErrorIsUnreachable() async {
        let provider = FakeJourneyProvider()
        provider.result = .failure(JourneyProviderError.unavailable(status: 503))
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .unreachable(message: JourneyProviderError.unavailable(status: 503).userMessage))
    }

    func testCancelledErrorIsIgnored() async {
        let provider = FakeJourneyProvider()
        provider.result = .failure(JourneyProviderError.cancelled)
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .loading)
    }

    // MARK: Persistence

    func testWritersPersistToPreferencesRow() throws {
        let container = try ModelContainer(for: DirectionsPreferences.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let model = makeModel(FakeJourneyProvider())
        model.attach(context: context)
        XCTAssertEqual(model.prefs, .default)

        model.setWalkTolerance(20)
        model.toggleMode(.luas)
        let rows = try context.fetch(FetchDescriptor<DirectionsPreferences>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.walkToleranceMinutes, 20)
        XCTAssertEqual(rows.first?.enabledModesRaw, ["bus", "dart", "rail"])

        // Settings edits the row behind the sheet's back; refresh picks it up.
        rows.first?.apply(model.prefs.replacing(maxTransfers: 0))
        try context.save()
        model.refreshPrefs()
        XCTAssertEqual(model.prefs.maxTransfers, 0)
    }

    // MARK: Probes

    func testDefaultPlanRunsBaseRailAndFamilyProbes() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.requests.count, 5)
        XCTAssertLessThanOrEqual(provider.requests.count, DirectionsViewModel.maxPlanCalls)
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(provider.railProbes.count, 1)
        XCTAssertEqual(provider.railProbes.first?.transitModesOverride, [.luas, .dart, .rail])
        XCTAssertNil(provider.railProbes.first?.walkToleranceOverrideMinutes)
        // The probes run concurrently in a task group, so compare as a set.
        XCTAssertEqual(Set(provider.familyProbes.compactMap(\.transitModesOverride)), [[.bus], [.luas], [.dart, .rail]])
        XCTAssertEqual(provider.familyProbes.first?.preferences.walkToleranceMinutes, 10, "preferences untouched")
        XCTAssertTrue(provider.familyProbes.allSatisfy { $0.effectiveWalkToleranceSeconds == nil })
    }

    func testRailProbeNeedsPreferRailAndARailMode() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = makeModel(provider)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(preferRail: false))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.railProbes.count, 0, "prefer rail off")
        XCTAssertEqual(provider.requests.count, 4, "the base and the three family probes")

        model.apply(DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bus, .luas]))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.railProbes.count, 0, "Luas alone is not a rail probe")

        model.apply(DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bus, .dart]))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.railProbes.count, 1)
        XCTAssertEqual(provider.railProbes.first?.transitModesOverride, [.dart], "only the rail modes the user has on")
    }

    func testFamilyProbesFollowEnabledModesAndSkipRepeats() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = makeModel(provider)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bus, .dart], preferRail: false))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(Set(provider.familyProbes.compactMap(\.transitModesOverride)), [[.bus], [.dart]], "only the families that are on")
        XCTAssertEqual(provider.requests.count, 3)

        // Bus only with no walk limit: the bus probe would repeat the base.
        model.apply(DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 0, enabledModes: [.bus], preferRail: false))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.requests.count, 4, "just the base this time")

        // DART only with no walk limit: the rail probe and the DART probe
        // would both repeat the base.
        model.apply(DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 0, enabledModes: [.dart]))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(provider.requests.count, 5, "again just the base")
    }

    func testRequestsBuilderIsPure() {
        let base = JourneyRequest(origin: heuston.coordinate, destination: dunLaoghaire.coordinate, preferences: .default)
        let plain = DirectionsViewModel.requests(for: base)
        XCTAssertEqual(plain.count, 5)
        XCTAssertNil(plain[0].walkToleranceOverrideMinutes)
        XCTAssertEqual(plain[1].transitModesOverride, [.luas, .dart, .rail])
        XCTAssertNil(plain[1].walkToleranceOverrideMinutes)
        XCTAssertEqual(plain[2...].map(\.transitModesOverride), [[.bus], [.luas], [.dart, .rail]])
        XCTAssertEqual(plain[2...].map(\.walkToleranceOverrideMinutes), [0, 0, 0])

        let rain = DirectionsViewModel.requests(for: base, rainAdjusted: true)
        XCTAssertEqual(rain.count, 2, "only the two requests with a limit to shorten; the probes' first answers are reused")
        XCTAssertEqual(rain.map(\.walkToleranceOverrideMinutes), [5, 5])
        XCTAssertEqual(rain[1].transitModesOverride, [.luas, .dart, .rail])
        XCTAssertFalse(rain.contains(where: DirectionsViewModel.isFamilyProbe))
        XCTAssertEqual(plain.filter(DirectionsViewModel.isFamilyProbe).count, 3)

        // No walk limit and no Luas: the rail probe is DART alone at the
        // no-limit walk, so the DART family probe would repeat it.
        var anyWalk = base
        anyWalk.preferences = DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 0, enabledModes: [.bus, .dart])
        let relaxed = DirectionsViewModel.requests(for: anyWalk)
        XCTAssertEqual(relaxed.map(\.transitModesOverride), [nil, [.dart], [.bus]])
    }

    func testMergeKeepsBaseFirstAndDropsDuplicates() async throws {
        let shared = makeItinerary("shared", minutes: 40, modes: [.walk, .bus, .walk, .bus, .walk])
        let baseOnly = makeItinerary("base", minutes: 30, modes: [.walk, .bus, .walk, .bus, .walk])
        let probeOnly = makeItinerary("probe", minutes: 50, modes: [.walk, .bus, .walk])
        let provider = RoutingFakeProvider { request in
            if request.transitModesOverride == [.bus], request.walkToleranceOverrideMinutes == 0 { return [probeOnly, shared] }
            if request.transitModesOverride != nil { return [] }
            return [shared, baseOnly]
        }
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore(), weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.origin = heuston
        model.destination = dunLaoghaire
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(Set(model.itineraries.map(\.id)), ["shared", "base", "probe"])
        XCTAssertEqual(model.itineraries.map(\.id), ["base", "shared", "probe"], "ranked by duration, no repeats")
        XCTAssertEqual(model.itineraries.compactMap(\.reason), [], "the fastest bus is the first row: no chip")
    }

    func testProbeFailureIsIgnoredAndBaseFailureFallsBackToProbes() async {
        let good = makeItinerary("a")
        let probeFails = RoutingFakeProvider { request in
            if request.walkToleranceOverrideMinutes == 0 { throw JourneyProviderError.unavailable(status: 503) }
            return [good]
        }
        let model = DirectionsViewModel(provider: probeFails, store: TransitLayerStore(), weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.origin = heuston
        model.destination = dunLaoghaire
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"])

        let baseFails = RoutingFakeProvider { request in
            if request.transitModesOverride == nil && request.walkToleranceOverrideMinutes == nil {
                throw JourneyProviderError.unavailable(status: 503)
            }
            return [good]
        }
        let fallback = DirectionsViewModel(provider: baseFails, store: TransitLayerStore(), weather: FakeWeather().service, cycling: FakeCyclingProvider())
        fallback.origin = heuston
        fallback.destination = dunLaoghaire
        fallback.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(fallback.phase, .results, "probe answers still show")
        XCTAssertEqual(fallback.itineraries.map(\.id), ["a"])
    }

    // MARK: Rain

    /// Journeys around 11:00, when the rain fixture climbs to 80 % at 12:00.
    private func rainyItineraries() -> [Itinerary] {
        [makeItinerary("a", minutes: 30, startOffsetHours: 3), makeItinerary("b", minutes: 45, startOffsetHours: 3)]
    }

    func testRainHintShortensWalksAndCanBeUndone() async {
        let provider = FakeJourneyProvider()
        provider.result = .success(rainyItineraries())
        let weather = FakeWeather(fixture: .rain)
        let model = makeModel(provider, weather: weather)
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))

        XCTAssertEqual(weather.calls, 2, "one forecast per end")
        XCTAssertEqual(model.rainHint?.probabilityPercent, 80)
        XCTAssertEqual(model.rainHint?.hour, t0.addingTimeInterval(4 * 3600))
        XCTAssertEqual(model.rainHint?.nearName, "Heuston", "origin wins the tie")
        XCTAssertTrue(model.rainAdjusted)
        XCTAssertEqual(provider.walkProbes(5).count, 1, "the base re-run with the rain walk limit")
        XCTAssertEqual(provider.requests.filter { $0.walkToleranceOverrideMinutes == 5 }.count, 2,
                       "and its rail probe shares the limit")
        XCTAssertEqual(provider.walkProbes(5).first?.preferences.walkToleranceMinutes, 10, "the preference is untouched")
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.itineraries.map(\.id), ["a", "b"])

        let before = provider.requests.count
        model.undoRainAdjustment()
        await settle(.milliseconds(300))
        XCTAssertFalse(model.rainAdjusted)
        XCTAssertNotNil(model.rainHint, "the forecast line stays")
        XCTAssertEqual(weather.calls, 2, "no second forecast after undo")
        XCTAssertEqual(provider.requests.count - before, 5, "base, rail and family probes with the user's own limit")
        XCTAssertEqual(provider.walkProbes(5).count, 1, "not shortened again")

        // A changed preference re-plans but honours the undo for this journey.
        model.setMaxTransfers(1)
        await settle(DirectionsViewModel.debounce + .milliseconds(300))
        XCTAssertFalse(model.rainAdjusted)
        XCTAssertEqual(provider.walkProbes(5).count, 1)

        // A new destination starts afresh.
        model.setDestination(DirectionsEndpoint(name: "Blanchardstown", coordinate: CLLocationCoordinate2D(latitude: 53.3928, longitude: -6.3903)))
        XCTAssertNil(model.rainHint)
        await settle(.milliseconds(300))
        XCTAssertTrue(model.rainAdjusted)
        XCTAssertEqual(model.rainHint?.nearName, "Heuston")
        XCTAssertEqual(provider.walkProbes(5).count, 2)
    }

    func testRainRePlanRunsOnlyTheBaseAndRailAndKeepsTheProbesFinds() async {
        let rainy = rainyItineraries()
        let train = makeItinerary("train", minutes: 50, startOffsetHours: 3, modes: [.walk, .dart, .walk])
        let provider = RoutingFakeProvider { request in
            if DirectionsViewModel.isFamilyProbe(request) {
                return request.transitModesOverride == [.dart, .rail] ? [train] : []
            }
            return rainy
        }
        let weather = FakeWeather(fixture: .rain)
        let store = TransitLayerStore()
        let model = DirectionsViewModel(provider: provider, store: store, weather: weather.service, cycling: FakeCyclingProvider())
        model.origin = heuston
        model.destination = dunLaoghaire
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))

        XCTAssertTrue(model.rainAdjusted)
        let requests = provider.log.requests
        XCTAssertEqual(requests.count, DirectionsViewModel.maxPlanCalls + 2, "the first pass, then the base and rail probe again")
        XCTAssertEqual(requests.filter(DirectionsViewModel.isFamilyProbe).count, 3, "the no-limit probes ran once")
        XCTAssertEqual(requests.filter { $0.walkToleranceOverrideMinutes == DirectionsViewModel.rainWalkMinutes }.count, 2)
        XCTAssertEqual(Set(model.itineraries.map(\.id)), ["a", "b", "train"], "the probe's train is still offered")
        XCTAssertEqual(model.itineraries.last?.reason, "Fastest by DART", "and still guaranteed its row")
        XCTAssertEqual(store.previewItineraries.count, 2, "the first row and the train")
    }

    func testRainHintWithoutAdjustmentWhenWalkLimitAlreadyShort() async {
        let provider = FakeJourneyProvider()
        provider.result = .success(rainyItineraries())
        let weather = FakeWeather(fixture: .rain)
        let model = makeModel(provider, weather: weather)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 5))
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))
        XCTAssertNotNil(model.rainHint)
        XCTAssertFalse(model.rainAdjusted)
        XCTAssertEqual(provider.walkProbes(5).count, 0, "nothing shorter to plan with")
    }

    func testDryForecastLeavesResultsAlone() async {
        let provider = FakeJourneyProvider()
        provider.result = .success(rainyItineraries())
        let weather = FakeWeather(fixture: .dry)
        let model = makeModel(provider, weather: weather)
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))
        XCTAssertEqual(weather.calls, 2)
        XCTAssertNil(model.rainHint)
        XCTAssertFalse(model.rainAdjusted)
        XCTAssertEqual(provider.requests.count, 5)
    }

    func testRainAwareOffNeverAsksForWeather() async {
        let provider = FakeJourneyProvider()
        provider.result = .success(rainyItineraries())
        let weather = FakeWeather(fixture: .rain)
        let model = makeModel(provider, weather: weather)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(rainAware: false))
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))
        XCTAssertEqual(weather.calls, 0)
        XCTAssertNil(model.rainHint)
        XCTAssertFalse(model.rainAdjusted)
        XCTAssertEqual(provider.requests.count, 5)
    }

    func testWeatherFailureIsSilent() async {
        let provider = FakeJourneyProvider()
        provider.result = .success(rainyItineraries())
        let weather = FakeWeather(fixture: nil)
        let model = makeModel(provider, weather: weather)
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))
        XCTAssertEqual(weather.calls, 2)
        XCTAssertNil(model.rainHint)
        XCTAssertEqual(model.phase, .results)
    }

    func testForecastWindowFallsBackToNinetyMinutes() {
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(DirectionsViewModel.forecastWindow(for: [], around: at), at...at.addingTimeInterval(90 * 60))
        let found = [makeItinerary("a", minutes: 30, startOffsetHours: 1), makeItinerary("b", minutes: 60)]
        XCTAssertEqual(DirectionsViewModel.forecastWindow(for: found, around: at), t0...t0.addingTimeInterval(90 * 60))
    }

    // MARK: Lifecycle (review fixes)

    func testStartWithNewDestinationClearsOldResultsBeforeLoading() async {
        let provider = FakeJourneyProvider()
        let a = makeItinerary("a")
        provider.result = .success([a])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.start(destination: dunLaoghaire, userLocation: heuston.coordinate)
        await settle()
        model.select(a)
        XCTAssertNotNil(store.drawnItinerary)

        // The same journey again (sheet reopened): the list and the drawn
        // option stay while the plan refreshes.
        provider.delay = .milliseconds(200)
        model.start(destination: dunLaoghaire, userLocation: heuston.coordinate)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"])
        XCTAssertEqual(model.selectedId, "a")
        await settle(.milliseconds(400))
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.selectedId, "a")

        // Another destination while the sheet is up: nothing stale lingers.
        provider.result = .success([makeItinerary("b")])
        let blanch = DirectionsEndpoint(name: "Blanchardstown", coordinate: CLLocationCoordinate2D(latitude: 53.3928, longitude: -6.3903))
        model.start(destination: blanch, userLocation: heuston.coordinate)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(model.itineraries.isEmpty)
        XCTAssertNil(model.selectedId)
        XCTAssertNil(store.drawnItinerary)
        XCTAssertNil(model.drawnLabel)
        await settle(.milliseconds(400))
        XCTAssertEqual(model.itineraries.map(\.id), ["b"])
        XCTAssertEqual(provider.baseRequests.last?.destination.latitude, blanch.coordinate.latitude)
    }

    func testEndpointChangeClearsStaleResultsAndPreferenceChangeKeepsThem() async {
        let provider = FakeJourneyProvider()
        let a = makeItinerary("a")
        provider.result = .success([a])
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store)
        model.scheduleQuery(immediate: true)
        await settle()
        model.select(a)

        // Preferences: the old list shows dimmed while the new one loads.
        provider.delay = .milliseconds(300)
        model.setWalkTolerance(20)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(model.itineraries.map(\.id), ["a"], "kept while loading")
        XCTAssertEqual(model.selectedId, "a")
        XCTAssertNotNil(store.drawnItinerary)
        await settle(DirectionsViewModel.debounce + .milliseconds(500))
        XCTAssertEqual(model.phase, .results)

        // Endpoints: the list, the pick and the drawn option go at once.
        for change in [
            { model.setDestination(DirectionsEndpoint(name: "Blanchardstown", coordinate: CLLocationCoordinate2D(latitude: 53.3928, longitude: -6.3903))) },
            { model.setOrigin(DirectionsEndpoint(name: "Howth", coordinate: CLLocationCoordinate2D(latitude: 53.3873, longitude: -6.0650))) },
            { model.swapEndpoints() },
        ] {
            await settle(.milliseconds(400))
            XCTAssertEqual(model.phase, .results)
            model.select(model.itineraries[0])
            XCTAssertNotNil(store.drawnItinerary)
            change()
            XCTAssertEqual(model.phase, .loading)
            XCTAssertTrue(model.itineraries.isEmpty)
            XCTAssertNil(model.selectedId)
            XCTAssertNil(store.drawnItinerary)
        }
    }

    func testSheetDismissedKeepsJourneyButStopsWork() async {
        let provider = FakeJourneyProvider()
        let a = makeItinerary("a")
        provider.result = .success(rainyItineraries() + [a])
        let weather = FakeWeather(fixture: .rain)
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store, weather: weather)
        model.isPresented = true
        model.scheduleQuery(immediate: true)
        await settle(.milliseconds(300))
        XCTAssertNotNil(model.rainHint)
        model.select(a)

        // A slow re-plan is in flight when the sheet closes: its answer must
        // never land.
        provider.result = .success([makeItinerary("late")])
        provider.delay = .milliseconds(200)
        model.setWalkTolerance(20)
        model.sheetDismissed()
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.rainHint, "the forecast line is for the open sheet")
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.origin, heuston)
        XCTAssertEqual(model.destination, dunLaoghaire)
        XCTAssertEqual(model.selectedId, "a", "the drawn option stays on the map")
        XCTAssertEqual(store.drawnItinerary?.map(\.id), ["a-leg"])
        let requestsBefore = provider.requests.count
        await settle(DirectionsViewModel.debounce + .milliseconds(500))
        XCTAssertEqual(provider.requests.count, requestsBefore, "the debounced plan was cancelled")
        XCTAssertEqual(model.selectedId, "a")
        XCTAssertTrue(model.itineraries.contains { $0.id == "a" })
        XCTAssertFalse(model.itineraries.contains { $0.id == "late" })
    }

    func testRefreshPrefsPlansOnlyWhileShown() async throws {
        let container = try ModelContainer(for: DirectionsPreferences.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = makeModel(provider)
        model.attach(context: context)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<DirectionsPreferences>()).first)

        // Hidden: the change is mirrored, nothing is planned, nothing fetched.
        row.apply(model.prefs.replacing(maxTransfers: 0))
        try context.save()
        model.refreshPrefs()
        XCTAssertEqual(model.prefs.maxTransfers, 0)
        await settle(DirectionsViewModel.debounce + .milliseconds(200))
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(model.phase, .idle)

        // An unrelated save with nothing changed: still nothing.
        model.refreshPrefs()
        await settle(DirectionsViewModel.debounce + .milliseconds(200))
        XCTAssertTrue(provider.requests.isEmpty)

        // Shown: the change re-plans.
        model.isPresented = true
        row.apply(model.prefs.replacing(maxTransfers: 3))
        try context.save()
        model.refreshPrefs()
        XCTAssertEqual(model.prefs.maxTransfers, 3)
        XCTAssertEqual(model.phase, .loading)
        await settle(DirectionsViewModel.debounce + .milliseconds(300))
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(provider.baseRequests.first?.preferences.maxTransfers, 3)
    }

    func testLateLocationFixFillsInTheOriginWhileShown() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore(),
                                        weather: FakeWeather().service, cycling: FakeCyclingProvider())
        model.start(destination: dunLaoghaire, userLocation: nil)
        XCTAssertNil(model.origin)
        XCTAssertEqual(model.phase, .idle)

        // Hidden: the fix is remembered for the picker, nothing more.
        model.userLocationDidUpdate(heuston.coordinate)
        XCTAssertNil(model.origin)
        XCTAssertEqual(model.userLocation?.latitude, heuston.coordinate.latitude)
        XCTAssertTrue(provider.requests.isEmpty)

        model.isPresented = true
        model.userLocationDidUpdate(heuston.coordinate)
        XCTAssertEqual(model.origin?.isUserLocation, true)
        XCTAssertEqual(model.phase, .loading)
        await settle()
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(model.phase, .results)

        // A later fix moves "My Location": the plan in hand stands.
        model.userLocationDidUpdate(CLLocationCoordinate2D(latitude: 53.35, longitude: -6.30))
        await settle()
        XCTAssertEqual(provider.baseRequests.count, 1)
        XCTAssertEqual(model.origin?.coordinate.latitude ?? 0, heuston.coordinate.latitude, accuracy: 1e-6)

        // No destination yet: a fix alone starts nothing.
        let bare = DirectionsViewModel(provider: provider, store: TransitLayerStore(),
                                       weather: FakeWeather().service, cycling: FakeCyclingProvider())
        bare.isPresented = true
        bare.userLocationDidUpdate(heuston.coordinate)
        XCTAssertNil(bare.origin)
    }

    // MARK: Cycling

    func testBikeRouterReplacesTheEnginesDirectCycle() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a", minutes: 40), makeBike("engine-bike", minutes: 30)])
        let cycling = FakeCyclingProvider()
        cycling.result = .success(makeBike("brouter", minutes: 32, reason: "Quiet roads"))
        let model = makeModel(provider, cycling: cycling)
        model.apply(model.prefs.replacing(allowBikeDirect: true))
        model.scheduleQuery(immediate: true)
        await settle()

        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.itineraries.map(\.id), ["brouter", "a"], "ranked by duration, engine cycle gone")
        XCTAssertEqual(model.itineraries.first?.reason, "Quiet roads", "ranking keeps the router's reason")
        XCTAssertEqual(cycling.requests.count, 1, "one bike route per plan, not per probe")
        let sent = cycling.requests[0]
        XCTAssertEqual(sent.style, .quiet)
        XCTAssertEqual(sent.origin.latitude, heuston.coordinate.latitude)
        XCTAssertEqual(sent.destination.longitude, dunLaoghaire.coordinate.longitude)
        XCTAssertEqual(sent.departure, provider.baseRequests[0].time)
    }

    func testEngineCycleKeptWhenBikeRouterFails() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a", minutes: 40), makeBike("engine-bike", minutes: 30)])
        let cycling = FakeCyclingProvider()
        cycling.result = .failure(JourneyProviderError.unavailable(status: 502))
        let model = makeModel(provider, cycling: cycling)
        model.apply(model.prefs.replacing(allowBikeDirect: true))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.itineraries.map(\.id), ["engine-bike", "a"])
        XCTAssertEqual(cycling.requests.count, 1)
    }

    func testBikeRouterAppendedWhenEngineHadNoCycle() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a", minutes: 20)])
        let cycling = FakeCyclingProvider()
        cycling.result = .success(makeBike("brouter", minutes: 32, reason: "Quiet roads"))
        let model = makeModel(provider, cycling: cycling)
        model.apply(model.prefs.replacing(allowBikeDirect: true))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.itineraries.map(\.id), ["a", "brouter"])

        let timedOut = await DirectionsViewModel.cyclingOption(
            DirectionsViewModel.CyclingJob(provider: {
                let slow = FakeCyclingProvider()
                slow.result = .success(makeBike("slow"))
                slow.delay = .seconds(2)
                return slow
            }(), request: cycling.requests[0]),
            timeout: .milliseconds(50))
        XCTAssertNil(timedOut, "a slow router is not waited for")
    }

    func testSetCyclingStyleRefreshesOnlyTheBikeOption() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a", minutes: 40), makeBike("engine-bike", minutes: 30)])
        let cycling = FakeCyclingProvider()
        let quiet = makeBike("brouter-quiet", minutes: 32, reason: "Quiet roads")
        cycling.result = .success(quiet)
        let store = TransitLayerStore()
        let model = makeModel(provider, store: store, cycling: cycling)
        model.apply(model.prefs.replacing(allowBikeDirect: true))
        model.scheduleQuery(immediate: true)
        await settle()
        model.select(quiet)
        let planRequests = provider.requests.count

        cycling.result = .success(makeBike("brouter-fast", minutes: 26))
        model.setCyclingStyle(.fast)
        XCTAssertEqual(model.prefs.cyclingStyle, .fast)
        XCTAssertEqual(model.phase, .results, "no loading state for a quiet swap")
        await settle()
        XCTAssertEqual(provider.requests.count, planRequests, "no transit re-plan")
        XCTAssertEqual(cycling.requests.count, 2)
        XCTAssertEqual(cycling.requests.last?.style, .fast)
        XCTAssertEqual(model.itineraries.map(\.id), ["brouter-fast", "a"], "swapped in place")
        XCTAssertNil(model.itineraries.first?.reason, "fastest has nothing to say")
        XCTAssertEqual(model.selectedId, "brouter-fast", "the pick follows the bike option")
        XCTAssertEqual(store.drawnItinerary?.map(\.id), ["brouter-fast-leg"])

        // The shared controls hand back a whole snapshot; a style-only
        // change still takes the cycling path.
        model.apply(model.prefs.replacing(cyclingStyle: .balanced))
        await settle()
        XCTAssertEqual(provider.requests.count, planRequests)
        XCTAssertEqual(cycling.requests.count, 3)
        XCTAssertEqual(cycling.requests.last?.style, .balanced)

        // The same style again is a no-op.
        model.setCyclingStyle(.balanced)
        await settle()
        XCTAssertEqual(cycling.requests.count, 3)
    }

    func testNoBikeRouteWhenCyclingTheWholeWayIsOff() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let cycling = FakeCyclingProvider()
        cycling.result = .success(makeBike("brouter"))
        let model = makeModel(provider, cycling: cycling)
        model.apply(DirectionsPreferencesSnapshot.default.replacing(allowBikeDirect: false))
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.itineraries.map(\.id), ["a"])
        XCTAssertTrue(cycling.requests.isEmpty)

        model.setCyclingStyle(.fast)
        await settle()
        XCTAssertTrue(cycling.requests.isEmpty, "a style change without the option asks nothing")
        XCTAssertEqual(model.prefs.cyclingStyle, .fast, "but is remembered")
    }

    func testFixtureCyclingProviderGivesASyntheticRoute() async throws {
        let route = try await FixtureCyclingProvider().route(
            CyclingRouteRequest(origin: heuston.coordinate, destination: dunLaoghaire.coordinate, style: .quiet, departure: t0))
        XCTAssertEqual(route.legs.count, 1)
        XCTAssertEqual(route.legs[0].mode, .bike)
        XCTAssertEqual(route.legs[0].coordinates.count, 8)
        XCTAssertEqual(route.durationSeconds, 1500)
        XCTAssertEqual(route.reason, "Quiet roads")
        XCTAssertEqual(route.start, t0)
        let fast = try await FixtureCyclingProvider().route(
            CyclingRouteRequest(origin: heuston.coordinate, destination: dunLaoghaire.coordinate, style: .fast, departure: t0))
        XCTAssertNil(fast.reason)
    }

    func testFixtureProviderHonoursOverrides() async throws {
        let provider = FixtureJourneyProvider()
        let base = JourneyRequest(origin: heuston.coordinate, destination: dunLaoghaire.coordinate)

        var railOnly = base
        railOnly.transitModesOverride = [.luas, .dart, .rail]
        let railResults = try await provider.plan(railOnly)
        XCTAssertEqual(railResults.map(\.id), ["fixture-rail"])

        var relaxed = base
        relaxed.walkToleranceOverrideMinutes = 20
        let relaxedResults = try await provider.plan(relaxed)
        XCTAssertEqual(relaxedResults.map(\.id), ["fixture-rail", "fixture-bus", "fixture-longbus"])
        let long = try XCTUnwrap(relaxedResults.last)
        XCTAssertEqual(long.transitLegs.count, 1)
        XCTAssertGreaterThan(long.firstAndLastWalkSeconds, 10 * 60)

        var shortened = base
        shortened.preferences = DirectionsPreferencesSnapshot.default.replacing(walkToleranceMinutes: 20)
        shortened.walkToleranceOverrideMinutes = 5
        let shortenedResults = try await provider.plan(shortened)
        XCTAssertEqual(shortenedResults.map(\.id), ["fixture-rail", "fixture-bus"],
                       "the override wins over a generous preference")

        var noLimit = base
        noLimit.transitModesOverride = [.bus]
        noLimit.walkToleranceOverrideMinutes = DirectionsPreferencesSnapshot.noWalkLimit
        let noLimitResults = try await provider.plan(noLimit)
        XCTAssertEqual(noLimitResults.map(\.id), ["fixture-bus", "fixture-longbus"], "no limit reaches the longer walks")
    }

    func testFixtureProviderRespectsModesAndTransfers() async throws {
        let provider = FixtureJourneyProvider()
        let base = JourneyRequest(origin: heuston.coordinate, destination: dunLaoghaire.coordinate)
        let all = try await provider.plan(base)
        XCTAssertEqual(all.map(\.id), ["fixture-rail", "fixture-bus"])

        var busOnly = base
        busOnly.preferences = DirectionsPreferencesSnapshot.default.replacing(enabledModes: [.bus])
        let busResults = try await provider.plan(busOnly)
        XCTAssertEqual(busResults.map(\.id), ["fixture-bus"])

        var noChanges = base
        noChanges.preferences = DirectionsPreferencesSnapshot.default.replacing(maxTransfers: 0)
        let noChangeResults = try await provider.plan(noChanges)
        XCTAssertTrue(noChangeResults.isEmpty)

        var arriveBy = base
        arriveBy.arriveBy = true
        for itinerary in try await provider.plan(arriveBy) {
            XCTAssertEqual(itinerary.end, base.time)
        }
    }
}
