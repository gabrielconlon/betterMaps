import Foundation
import MapKit
import os

/// The two MapKit/CoreLocation lookups a dropped pin can be named from.
/// Injectable so `PlaceLookupService` is testable without the network.
protocol PlaceLookupProvider: Sendable {
    /// Name of the nearest point of interest within `radius` metres, or nil.
    func pointOfInterestName(near coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> String?
    /// Short street address for the coordinate ("12 Pearse St"), or nil.
    func address(for coordinate: CLLocationCoordinate2D) async -> String?
}

/// Names a coordinate for fast place capture: the POI within 40 m if there
/// is one, else a reverse-geocoded street address. Bounded by a 3 s timeout
/// and silent on failure — callers get `nil` and keep an editable field, never
/// an error.
struct PlaceLookupService: Sendable {
    static let poiRadius: CLLocationDistance = 40
    static let shared = PlaceLookupService(provider: MapKitPlaceLookupProvider(), timeout: .seconds(3))

    let provider: any PlaceLookupProvider
    let timeout: Duration

    init(provider: any PlaceLookupProvider, timeout: Duration = .seconds(3)) {
        self.provider = provider
        self.timeout = timeout
    }

    static func lookup(_ coordinate: CLLocationCoordinate2D) async -> String? {
        await shared.lookup(coordinate)
    }

    /// POI name, else address, else nil. Returns nil as soon as `timeout`
    /// elapses even if the underlying request ignores cancellation.
    func lookup(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let provider = provider
        let timeout = timeout
        let gate = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                gate.install(continuation)
                let work = Task {
                    let name = await Self.resolve(coordinate, provider: provider)
                    gate.resume(with: name)
                }
                gate.setOnCancel { work.cancel() }
                Task {
                    try? await Task.sleep(for: timeout)
                    work.cancel()
                    gate.resume(with: nil)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private static func resolve(_ coordinate: CLLocationCoordinate2D,
                                provider: any PlaceLookupProvider) async -> String? {
        if let poi = await provider.pointOfInterestName(near: coordinate, radius: poiRadius), !poi.isEmpty {
            return poi
        }
        guard !Task.isCancelled else { return nil }
        if let address = await provider.address(for: coordinate), !address.isEmpty {
            return address
        }
        return nil
    }

    /// "12 Pearse St" from placemark parts: number + street, else the
    /// placemark name, else the locality.
    static func formatAddress(subThoroughfare: String?, thoroughfare: String?,
                              name: String?, locality: String?) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        if let street = clean(thoroughfare) {
            if let number = clean(subThoroughfare) { return "\(number) \(abbreviate(street))" }
            return abbreviate(street)
        }
        return clean(name) ?? clean(locality)
    }

    /// Shortens the common street-type suffix the way Maps labels do.
    static func abbreviate(_ street: String) -> String {
        let suffixes = ["Street": "St", "Road": "Rd", "Avenue": "Ave", "Place": "Pl",
                        "Square": "Sq", "Lane": "Ln", "Terrace": "Tce"]
        var words = street.split(separator: " ").map(String.init)
        if let last = words.last, let short = suffixes[last] {
            words[words.count - 1] = short
        }
        return words.joined(separator: " ")
    }
}

/// Resumes a continuation exactly once, from whichever of the lookup, the
/// timeout or cancellation finishes first. A result that arrives before the
/// continuation is installed is held and delivered on install.
private final class ResumeOnce: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String?, Never>?
        /// `.some` once a result (possibly nil) has been delivered.
        var result: String??
        var onCancel: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<String?, Never>) {
        let early: String?? = state.withLock { s in
            if let result = s.result { return .some(result) }
            s.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func setOnCancel(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onCancel = handler }
    }

    func resume(with value: String?) {
        let continuation = state.withLock { s -> CheckedContinuation<String?, Never>? in
            guard s.result == nil else { return nil }
            s.result = .some(value)
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume(returning: value)
    }

    func cancel() {
        state.withLock { $0.onCancel }?()
        resume(with: nil)
    }
}

// MARK: - Live provider

struct MapKitPlaceLookupProvider: PlaceLookupProvider {
    func pointOfInterestName(near coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> String? {
        await MapKitLookups.nearestPOI(to: coordinate, radius: radius, within: radius)?.name
    }

    func address(for coordinate: CLLocationCoordinate2D) async -> String? {
        guard let placemark = await MapKitLookups.reverseGeocode(coordinate) else { return nil }
        return PlaceLookupService.formatAddress(subThoroughfare: placemark.subThoroughfare,
                                                thoroughfare: placemark.thoroughfare,
                                                name: placemark.name,
                                                locality: placemark.locality)
    }
}

/// The raw MapKit / CoreLocation calls, shared by `PlaceLookupService`
/// (dropped pins) and `POILookup` (map taps).
enum MapKitLookups {
    /// Closest point of interest from a `radius` search, rejected when it is
    /// farther than `maxDistance` metres from `coordinate`.
    static func nearestPOI(to coordinate: CLLocationCoordinate2D,
                           radius: CLLocationDistance,
                           within maxDistance: CLLocationDistance? = nil) async -> MKMapItem? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let ranked = response.mapItems
            .map { ($0, WaypointGraph.meters($0.placemark.coordinate, coordinate)) }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        if let maxDistance, best.1 > maxDistance { return nil }
        return best.0
    }

    static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> CLPlacemark? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return try? await CLGeocoder().reverseGeocodeLocation(location).first
    }
}
