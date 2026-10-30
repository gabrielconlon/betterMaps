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

@MainActor
final class DirectionsViewModelTests: XCTestCase {
    private let heuston = DirectionsEndpoint(name: "Heuston", coordinate: CLLocationCoordinate2D(latitude: 53.3464, longitude: -6.2923))
    private let dunLaoghaire = DirectionsEndpoint(name: "Dún Laoghaire", coordinate: CLLocationCoordinate2D(latitude: 53.2938, longitude: -6.1353))

    private func makeItinerary(_ id: String, minutes: Int = 30) -> Itinerary {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let leg = Leg(id: "\(id)-leg", mode: .bus, routeShortName: "39A", fromName: "A", toName: "B",
                      start: start, end: end, durationSeconds: minutes * 60,
                      coordinates: [heuston.coordinate, dunLaoghaire.coordinate])
        return Itinerary(id: id, legs: [leg], start: start, end: end, durationSeconds: minutes * 60,
                         transfers: 0, walkSeconds: 0, bikeSeconds: 0)
    }

    private func makeModel(_ provider: FakeJourneyProvider, store: TransitLayerStore = TransitLayerStore())
    -> DirectionsViewModel {
        let model = DirectionsViewModel(provider: provider, store: store)
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
        let model = DirectionsViewModel(provider: FakeJourneyProvider(), store: TransitLayerStore())
        model.destination = dunLaoghaire
        XCTAssertNil(model.buildRequest())
        model.scheduleQuery(immediate: true)
        XCTAssertEqual(model.phase, .idle)
    }

    func testStartWithoutLocationStaysIdle() {
        let provider = FakeJourneyProvider()
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore())
        model.start(destination: dunLaoghaire, userLocation: nil)
        XCTAssertNil(model.origin)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testStartWithLocationPlansFromMyLocation() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([makeItinerary("a")])
        let model = DirectionsViewModel(provider: provider, store: TransitLayerStore())
        model.start(destination: dunLaoghaire, userLocation: heuston.coordinate)
        XCTAssertEqual(model.origin?.isUserLocation, true)
        await settle()
        XCTAssertEqual(provider.requests.count, 1)
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
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.preferences.walkToleranceMinutes, 15)
        XCTAssertEqual(provider.requests.first?.preferences.maxTransfers, 3)
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
        XCTAssertEqual(provider.requests.count, 2)
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

        model.select(option)
        XCTAssertEqual(model.selectedId, "a")
        XCTAssertEqual(store.drawnItinerary?.map(\.id), ["a-leg"])
        XCTAssertEqual(store.drawnItineraryLabel, "Dún Laoghaire")
        XCTAssertEqual(model.drawnLabel, "Dún Laoghaire")

        model.clearSelection()
        XCTAssertNil(model.selectedId)
        XCTAssertNil(store.drawnItinerary)
        XCTAssertNil(store.drawnItineraryLabel)
        XCTAssertNil(model.drawnLabel)
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

    func testEmptyResultSuggestsRelaxingWalkAtDefaults() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let model = makeModel(provider)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: true, suggestTransfers: false))
    }

    func testEmptyResultAtZeroTransfersSuggestsChanges() async {
        let provider = FakeJourneyProvider()
        provider.result = .success([])
        let model = makeModel(provider)
        model.setWalkTolerance(20)
        model.setMaxTransfers(0)
        model.scheduleQuery(immediate: true)
        await settle()
        XCTAssertEqual(model.phase, .empty(suggestRelaxWalk: false, suggestTransfers: true))
        model.allowTransfers()
        XCTAssertEqual(model.prefs.maxTransfers, 2)
        model.relaxWalkingLimit()
        XCTAssertEqual(model.prefs.walkToleranceMinutes, 20)
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
