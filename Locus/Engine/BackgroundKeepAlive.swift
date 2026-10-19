import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
    var onLocation: ((CLLocation) -> Void)?
    private var backgroundActivity: CLBackgroundActivitySession?
    private var updatesStarted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .otherNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        guard !updatesStarted else { return }
        updatesStarted = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    /// Start while foregrounded, before locking the screen or switching apps.
    func beginBackgroundActivity() {
        start()
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if backgroundActivity == nil {
            backgroundActivity = CLBackgroundActivitySession()
        }
    }

    func endBackgroundActivity() {
        backgroundActivity?.invalidate()
        backgroundActivity = nil
    }

    func stop() {
        endBackgroundActivity()
        updatesStarted = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        if backgroundActivity != nil { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastKnownCoordinate = locations.last?.coordinate
        if let location = locations.last { onLocation?(location) }
    }
}
