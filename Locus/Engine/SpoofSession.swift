import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk {
        didSet {
            if travelMode != oldValue { speedMPH = travelMode.baseSpeed / 0.44704 }
        }
    }
    @Published var speedMPH: Double = 30 {
        didSet { UserDefaults.standard.set(speedMPH, forKey: "locus.speedMPH") }
    }
    @Published var variesSpeed = true
    @Published private(set) var routeRunning = false
    @Published private(set) var routePaused = false
    @Published private(set) var routeRemainingMeters: Double = 0
    @Published private(set) var holdingDestination = false
    @Published var previewDistanceMeters: Double?
    @Published var previewIsRouting = false
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var routeID = UUID()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundSessionStarted = false
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()
    private let audioKeeper = SilentAudioKeepAlive()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        let storedSpeed = UserDefaults.standard.double(forKey: "locus.speedMPH")
        if storedSpeed.isFinite, storedSpeed >= 1, storedSpeed <= 85 { speedMPH = storedSpeed }
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        cancelMovement()
        previewDistanceMeters = nil
        pin = coordinate
        holdingDestination = apply(coordinate, pairing: pairing, markRecent: true)
    }

    func stop(pairing: PairingStore) {
        cancelMovement()
        holdingDestination = false
        UserDefaults.standard.removeObject(forKey: "locus.holdCoordinate")
        stopResend()
        stopHealth()
        if simulated == nil, !LocationEngine.isSessionActive {
            status = .idle
            lastError = nil
            endBackground()
            return
        }
        isBusy = true
        let result = LocationEngine.clear()
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            status = .idle
            endBackground()
            // Keep location updates running so the map puck / locate button
            // can return to the real GPS fix (not the leftover pin).
            locationKeeper.start()
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        cancelMovement()
        holdingDestination = false
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        guard coordinates.count >= 2 else { return }
        if let current = simulated ?? realCoordinate {
            let gap = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude))
            guard gap < 100 else {
                lastError = "This route starts away from your current position. Build a new route, or explicitly Teleport to its start."
                return
            }
        }
        cancelMovement()
        let currentRouteID = routeID
        routeRunning = true
        holdingDestination = false
        routeRemainingMeters = RouteBuilder.distance(coordinates)
        routeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.routeID == currentRouteID {
                    self.routeRunning = false
                    self.routePaused = false
                    self.routeTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            var previous = coordinates[0]
            while !self.apply(previous, pairing: pairing, markRecent: true) {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
            }
            for next in coordinates.dropFirst() {
                guard !Task.isCancelled else { return }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                let stepMeters = min(12, max(2, MovementTiming.metersPerSecond(mph: self.speedMPH) * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                let variation = self.variesSpeed ? Double.random(in: 0.92...1.08) : 1
                for i in 1...steps {
                    guard !Task.isCancelled else { return }
                    while self.routePaused {
                        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = MovementTiming.stepDuration(distanceMeters: distance, steps: steps, mph: self.speedMPH * variation)
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    while self.routePaused {
                        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    // Keep the route cursor in place during tunnel failures instead of skipping ahead.
                    while !self.apply(coord, pairing: pairing, markRecent: false) {
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        guard !Task.isCancelled else { return }
                    }
                    self.routeRemainingMeters = max(0, self.routeRemainingMeters - distance / Double(steps))
                }
                previous = next
            }
            self.routeRemainingMeters = 0
            self.holdingDestination = true
        }
    }

    var routeETA: TimeInterval {
        MovementTiming.duration(distanceMeters: routeRemainingMeters, mph: speedMPH)
    }

    func toggleRoutePause() {
        guard routeRunning else { return }
        routePaused.toggle()
    }

    func refreshAfterForeground(pairing: PairingStore) {
        guard pairing.hasPairingFile else { return }
        guard UserDefaults.standard.array(forKey: "locus.holdCoordinate") != nil || routeRunning || joystickActive else { return }
        if let current = simulated {
            _ = apply(current, pairing: pairing, markRecent: false)
        } else if let saved = UserDefaults.standard.array(forKey: "locus.holdCoordinate") as? [Double],
                  saved.count == 2, (-90...90).contains(saved[0]), (-180...180).contains(saved[1]) {
            let coordinate = CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
            holdingDestination = apply(coordinate, pairing: pairing, markRecent: false)
        }
    }

    private func cancelMovement() {
        routeID = UUID()
        routeTask?.cancel()
        routeTask = nil
        routeRunning = false
        routePaused = false
        routeRemainingMeters = 0
        stopJoystick()
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    @discardableResult
    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) -> Bool {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let result = LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            UserDefaults.standard.set([coordinate.latitude, coordinate.longitude], forKey: "locus.holdCoordinate")
            status = .active
            lastError = nil
            beginBackground()
            locationKeeper.start()
            startResend(pairing: pairing)
            startHealth(pairing: pairing)
            if markRecent {
                pushRecent(coordinate)
            }
            return true
        case .failure(let error):
            lastError = error.localizedDescription
            if simulated != nil {
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            } else {
                status = .idle
            }
            return false
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let variation = variesSpeed ? Double.random(in: 0.92...1.08) : 1
        let speed = MovementTiming.metersPerSecond(mph: speedMPH) * min(1.0, magnitude) * variation
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        guard resendTimer == nil else { return }
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.resendTimer != nil, let sim = self.simulated else { return }
                _ = self.apply(sim, pairing: pairing, markRecent: false)
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.healthTimer != nil, let sim = self.simulated else { return }
                if case .dropped = self.status {
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        audioKeeper.start()
        guard !backgroundSessionStarted else { return }
        backgroundSessionStarted = true
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackground() {
        audioKeeper.stop()
        backgroundSessionStarted = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
