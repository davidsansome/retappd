import CoreLocation
import Observation

/// Publishes the user's location. The last fix is persisted so Discover can query
/// (and hit the cache) immediately at launch, before GPS warms up.
@Observable @MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    @ObservationIgnored private var isStarted = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "last_lat") != nil {
            location = CLLocation(
                coordinate: .init(latitude: d.double(forKey: "last_lat"), longitude: d.double(forKey: "last_lng")),
                altitude: 0, horizontalAccuracy: 1000, verticalAccuracy: -1,
                timestamp: Date(timeIntervalSince1970: d.double(forKey: "last_time")))
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func start() {
        isStarted = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() {
        isStarted = false
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, l.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            self.location = l
            let d = UserDefaults.standard
            d.set(l.coordinate.latitude, forKey: "last_lat")
            d.set(l.coordinate.longitude, forKey: "last_lng")
            d.set(l.timestamp.timeIntervalSince1970, forKey: "last_time")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            self.authorization = s
            if self.isStarted, s == .authorizedWhenInUse || s == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
