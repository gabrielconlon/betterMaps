import CoreLocation
import Observation
import UIKit

/// Foreground-only location for the blue dot and "near me" lookups.
///
/// Tuned for battery: ten-metre accuracy, a 20 m distance filter and
/// automatic pausing. Updates run only while the app is in the foreground
/// and the user has granted When-In-Use access.
@Observable
@MainActor
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var userLocation: CLLocationCoordinate2D?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Whether updates are currently running.
    private(set) var isUpdating = false
    /// False while the app is backgrounded; `start()` is a no-op then.
    private var isInForeground = true
    @ObservationIgnored private var lifecycleTasks: [Task<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .fitness
        authorizationStatus = manager.authorizationStatus
        observeLifecycle()
    }

    deinit {
        for task in lifecycleTasks { task.cancel() }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Begins updates if authorized and in the foreground; otherwise no-op.
    func start() {
        guard isInForeground, Self.isAuthorized(authorizationStatus), !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// Stops updates. Safe to call when already stopped.
    func stop() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let background = center.notifications(named: UIApplication.didEnterBackgroundNotification)
            .map { _ in () }
        let foreground = center.notifications(named: UIApplication.willEnterForegroundNotification)
            .map { _ in () }

        lifecycleTasks.append(Task { [weak self] in
            for await _ in background {
                guard let self else { return }
                self.isInForeground = false
                self.stop()
            }
        })
        lifecycleTasks.append(Task { [weak self] in
            for await _ in foreground {
                guard let self else { return }
                self.isInForeground = true
                self.start()
            }
        })
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.userLocation = coordinate
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if Self.isAuthorized(status) {
                self.start()
            } else {
                self.stop()
            }
        }
    }
}
