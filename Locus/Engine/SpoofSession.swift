import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive, automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        case .automatic: return "Automatic"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        case .automatic: return "sparkles"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive, .automatic: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive, .automatic: return .automobile
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
    @Published var travelMode: TravelMode = .automatic {
        didSet {
            guard travelMode != oldValue else { return }
            automaticRefreshTask?.cancel()
            automaticRefreshTask = nil
            automaticEstimate = nil
            previewAutomaticEstimate = nil
            automaticProfile = nil
            previewAutomaticProfile = nil
            if travelMode == .automatic {
                if routeRunning {
                    automaticProfile = RouteBuilder.automaticProfile(for: remainingRouteCoordinates)
                    playbackStore.saveAutomaticProfile(automaticProfile)
                    startAutomaticUpdates()
                }
            } else {
                speedMPH = travelMode.baseSpeed / 0.44704
                if routeRunning {
                    playbackStore.saveAutomaticEstimate(nil)
                    playbackStore.saveAutomaticProfile(nil)
                }
            }
        }
    }
    @Published var speedMPH: Double = 30 {
        didSet { UserDefaults.standard.set(speedMPH, forKey: "locus.speedMPH") }
    }
    @Published var variesSpeed = true
    @Published var previewAutomaticEstimate: AutomaticTravel.Estimate?
    @Published private(set) var automaticEstimate: AutomaticTravel.Estimate?
    @Published var previewAutomaticProfile: AutomaticPacing.Profile?
    @Published private(set) var automaticProfile: AutomaticPacing.Profile?
    @Published private(set) var routeRunning = false
    @Published private(set) var routePaused = false
    @Published private(set) var routeRemainingMeters: Double = 0
    @Published private(set) var remainingRouteCoordinates: [CLLocationCoordinate2D] = []
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
    private let playbackStore = PlaybackStore()
    private var holdTarget: CLLocationCoordinate2D?
    private var nextWaypoint = 1
    private var activeRouteCoordinates: [CLLocationCoordinate2D] = []
    private var automaticRefreshTask: Task<Void, Never>?
    private var joystickVariation = SpeedVariation()
    private var joystickElapsed: TimeInterval = 0
    private var restorePending = false

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

    var hasLocationIntent: Bool {
        routeRunning || joystickActive || holdTarget != nil || simulated != nil || restorePending
    }

    var requiresRestoreRetry: Bool { restorePending }

    var currentAutomaticEstimate: AutomaticTravel.Estimate? {
        routeRunning ? automaticEstimate : previewAutomaticEstimate
    }

    var effectiveSpeedMPH: Double {
        guard travelMode == .automatic else { return speedMPH }
        let fallback = currentAutomaticEstimate?.targetMPH ?? speedMPH
        return currentAutomaticProfile?.targetMPH(at: automaticRemainingMeters, fallbackMPH: fallback) ?? fallback
    }

    private var currentAutomaticProfile: AutomaticPacing.Profile? {
        routeRunning ? automaticProfile : previewAutomaticProfile
    }

    private var automaticRemainingMeters: Double {
        routeRunning ? routeRemainingMeters : (previewDistanceMeters ?? previewAutomaticProfile?.totalMeters ?? 0)
    }

    var automaticPaceStatus: String {
        guard let profile = currentAutomaticProfile, let index = profile.index(at: automaticRemainingMeters),
              let estimate = profile.sections[index].estimate else {
            return "Route average · local traffic unavailable"
        }
        return Date().timeIntervalSince(estimate.fetchedAt) >= AutomaticTravel.refreshInterval
            ? "Cached traffic estimate for this section" : "Traffic estimate for this section"
    }

    func estimatedTravelSeconds(distanceMeters: Double) -> TimeInterval {
        let fallback = currentAutomaticEstimate?.targetMPH ?? speedMPH
        if travelMode == .automatic, let profile = currentAutomaticProfile {
            return profile.remainingSeconds(distanceMeters, fallbackMPH: fallback)
        }
        return MovementTiming.duration(distanceMeters: distanceMeters, mph: effectiveSpeedMPH)
    }

    var speedLabel: String {
        if travelMode == .automatic {
            return currentAutomaticEstimate == nil ? "Automatic" : String(format: "Auto · %.0f mph", effectiveSpeedMPH)
        }
        return String(format: "%.0f mph", speedMPH)
    }

    func useManualModeForCustomPath() {
        if travelMode == .automatic {
            let manualSpeed = speedMPH
            travelMode = .drive
            speedMPH = manualSpeed
        }
        previewAutomaticEstimate = nil
        previewAutomaticProfile = nil
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        cancelMovement()
        restorePending = false
        previewDistanceMeters = nil
        pin = coordinate
        holdTarget = coordinate
        playbackStore.setHold(Self.storedPoint(coordinate))
        prepareForBackground(pairing: pairing)
        holdingDestination = apply(coordinate, pairing: pairing, markRecent: true)
    }

    func stop(pairing: PairingStore) {
        // Stop at the last position confirmed by the engine, never at the route
        // destination or a pending teleport that has not succeeded.
        let current = simulated
        cancelMovement()
        restorePending = false
        previewDistanceMeters = nil
        if let current {
            holdTarget = current
            playbackStore.setHold(Self.storedPoint(current))
            prepareForBackground(pairing: pairing)
            holdingDestination = apply(current, pairing: pairing, markRecent: false)
        } else {
            holdTarget = nil
            holdingDestination = false
            playbackStore.clear()
            stopResend()
            stopHealth()
            endBackground()
            status = .idle
            lastError = nil
        }
    }

    func restoreRealLocation(pairing: PairingStore, confirmation: HoldConfirmation.Permit) {
        guard confirmation.isValid(at: ProcessInfo.processInfo.systemUptime) else { return }
        cancelMovement()
        restorePending = true
        holdingDestination = false
        holdTarget = nil
        playbackStore.clear()
        stopResend()
        stopHealth()
        endBackground()
        isBusy = true
        let result = LocationEngine.clear(pairingPath: pairing.pairingPath, deviceIP: TunnelConfig.targetIP)
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            restorePending = false
            status = .idle
            lastError = nil
            // Keep location updates running so the map puck / locate button
            // can return to the real GPS fix (not the leftover pin).
            locationKeeper.start()
        case .failure(let error):
            lastError = "Could not restore real location: \(error.localizedDescription) Keep LocalDevVPN connected and retry. If it still fails, restart the iPhone."
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription, restoring: true)
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
        guard travelMode != .automatic else {
            lastError = "Automatic needs a destination and an Apple Maps route. Choose a manual mode for joystick movement."
            return
        }
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
        playbackStore.clearRoute()
        restorePending = false
        holdTarget = nil
        holdingDestination = false
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickVariation = SpeedVariation()
        joystickElapsed = 0
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

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore,
                     restoring: Bool = false, initiallyPaused: Bool = false,
                     estimate: AutomaticTravel.Estimate? = nil,
                     profile: AutomaticPacing.Profile? = nil) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        guard coordinates.count >= 2 else { return }
        guard travelMode != .automatic || estimate != nil else {
            lastError = "Automatic needs an Apple Maps road route and traffic estimate. Build a road route, or choose Drive for a drawn/GPX path."
            return
        }
        if !restoring, let current = simulated ?? realCoordinate {
            let gap = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude))
            guard gap < 100 else {
                lastError = "This route starts away from your current position. Build a new route, or explicitly Teleport to its start."
                return
            }
        }
        cancelMovement()
        let currentRouteID = routeID
        restorePending = false
        routeRunning = true
        routePaused = initiallyPaused
        nextWaypoint = 1
        activeRouteCoordinates = coordinates
        automaticEstimate = travelMode == .automatic ? estimate : nil
        automaticProfile = travelMode == .automatic ? (profile ?? RouteBuilder.automaticProfile(for: coordinates)) : nil
        previewDistanceMeters = nil
        holdTarget = nil
        holdingDestination = false
        routeRemainingMeters = RouteBuilder.distance(coordinates)
        playbackStore.beginRoute(coordinates.map(Self.storedPoint), paused: initiallyPaused,
                                 automaticEstimate: automaticEstimate, automaticProfile: automaticProfile)
        prepareForBackground(pairing: pairing)
        if travelMode == .automatic { startAutomaticUpdates() }
        routeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.routeID == currentRouteID {
                    self.routeRunning = false
                    self.routePaused = false
                    self.routeTask = nil
                    self.automaticRefreshTask?.cancel()
                    self.automaticRefreshTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            var previous = coordinates[0]
            var variation = SpeedVariation()
            var movingTime: TimeInterval = 0
            var started = self.apply(previous, pairing: pairing, markRecent: true)
            while !started {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                started = self.apply(previous, pairing: pairing, markRecent: false, reportError: false)
            }
            for (index, next) in coordinates.enumerated().dropFirst() {
                self.nextWaypoint = index
                guard !Task.isCancelled else { return }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                let stepMeters = min(12, max(2, MovementTiming.metersPerSecond(mph: self.effectiveSpeedMPH) * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                let bend = RouteLine.bendSeverity(coordinates, nextWaypoint: index)
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
                    let delay = variation.duration(distanceMeters: distance / Double(steps),
                                                   baseMPH: self.effectiveSpeedMPH, elapsed: movingTime,
                                                   bendSeverity: bend, enabled: self.variesSpeed,
                                                   smoothTransitions: self.travelMode == .automatic)
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    while self.routePaused {
                        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    // Keep the route cursor in place during tunnel failures instead of skipping ahead.
                    while !self.apply(coord, pairing: pairing, markRecent: false, reportError: false) {
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        guard !Task.isCancelled else { return }
                    }
                    self.routeRemainingMeters = max(0, self.routeRemainingMeters - distance / Double(steps))
                    movingTime += delay
                    self.saveRouteCheckpoint()
                }
                previous = next
            }
            self.routeRemainingMeters = 0
            self.remainingRouteCoordinates = []
            self.activeRouteCoordinates = []
            self.holdTarget = previous
            self.playbackStore.setHold(Self.storedPoint(previous))
            self.holdingDestination = true
        }
    }

    var routeETA: TimeInterval {
        estimatedTravelSeconds(distanceMeters: routeRemainingMeters)
    }

    func toggleRoutePause() {
        guard routeRunning else { return }
        routePaused.toggle()
        saveRouteCheckpoint(force: true)
    }

    func refreshAfterForeground(pairing: PairingStore) {
        guard pairing.hasPairingFile, !restorePending else { return }
        if routeRunning || joystickActive {
            prepareForBackground(pairing: pairing)
            if let current = simulated {
                _ = apply(current, pairing: pairing, markRecent: false)
            }
        } else if let savedRoute = playbackStore.recoverRoute() {
            let coordinates = savedRoute.remaining.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            pin = coordinates.last
            if savedRoute.automaticEstimate != nil {
                travelMode = .automatic
            } else if travelMode == .automatic {
                useManualModeForCustomPath()
            }
            followRoute(coordinates, pairing: pairing, restoring: true, initiallyPaused: savedRoute.paused,
                        estimate: savedRoute.automaticEstimate, profile: savedRoute.automaticProfile)
        } else if let saved = playbackStore.hold {
            holdTarget = CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)
            prepareForBackground(pairing: pairing)
            if let holdTarget {
                holdingDestination = apply(holdTarget, pairing: pairing, markRecent: false)
            }
        } else if let current = simulated {
            _ = apply(current, pairing: pairing, markRecent: false)
        }
    }

    func prepareForBackground(pairing: PairingStore) {
        guard hasLocationIntent, !restorePending else { return }
        saveRouteCheckpoint(force: true)
        beginBackground()
        startResend(pairing: pairing)
        startHealth(pairing: pairing)
    }

    private static func storedPoint(_ coordinate: CLLocationCoordinate2D) -> PlaybackStore.Point {
        PlaybackStore.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func saveRouteCheckpoint(force: Bool = false) {
        guard routeRunning, routeTask != nil, let simulated else { return }
        playbackStore.checkpoint(position: Self.storedPoint(simulated), nextWaypoint: nextWaypoint,
                                 paused: routePaused, force: force)
    }

    private func cancelMovement() {
        routeID = UUID()
        routeTask?.cancel()
        routeTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        routeRunning = false
        routePaused = false
        routeRemainingMeters = 0
        remainingRouteCoordinates = []
        activeRouteCoordinates = []
        stopJoystick()
    }

    private func startAutomaticUpdates() {
        automaticRefreshTask?.cancel()
        let currentRouteID = routeID
        automaticRefreshTask = Task { [weak self] in
            guard let self else { return }
            var gate = AutomaticPacing.RefreshGate()
            // Route preview just requested an ETA; give it breathing room.
            gate.succeeded(at: Date())
            while !Task.isCancelled, self.routeID == currentRouteID, self.routeRunning,
                  self.travelMode == .automatic {
                let now = Date()
                let canRequest = gate.allows(now) && !self.routePaused && self.routeRemainingMeters > 1
                if canRequest, self.automaticEstimate != nil, let profile = self.automaticProfile,
                   let index = profile.requestIndex(at: self.routeRemainingMeters, now: now) {
                    let section = profile.sections[index]
                    let untilSection = max(0, profile.remainingSeconds(self.routeRemainingMeters,
                                                                      fallbackMPH: self.automaticEstimate!.targetMPH)
                        - profile.remainingSeconds(section.upperRemaining, fallbackMPH: self.automaticEstimate!.targetMPH))
                    do {
                        let estimate = try await RouteBuilder.sectionTrafficEstimate(section,
                            departureDate: now.addingTimeInterval(untilSection))
                        guard !Task.isCancelled, self.routeID == currentRouteID, self.travelMode == .automatic else { return }
                        self.automaticProfile?.sections[index].estimate = estimate
                        self.automaticProfile?.sections[index].retryAfter = nil
                        self.playbackStore.saveAutomaticProfile(self.automaticProfile)
                        gate.succeeded(at: Date())
                    } catch {
                        guard !Task.isCancelled, self.routeID == currentRouteID, self.travelMode == .automatic else { return }
                        gate.failed(at: Date())
                        self.automaticProfile?.sections[index].retryAfter = gate.nextRequest
                        self.playbackStore.saveAutomaticProfile(self.automaticProfile)
                    }
                } else if canRequest, self.automaticEstimate.map({
                    now.timeIntervalSince($0.fetchedAt) >= AutomaticTravel.refreshInterval
                }) ?? true, let current = self.simulated, let end = self.activeRouteCoordinates.last {
                    do {
                        let estimate = try await RouteBuilder.trafficEstimate(
                            from: current, to: end, distanceMeters: self.routeRemainingMeters)
                        guard !Task.isCancelled, self.routeID == currentRouteID, self.travelMode == .automatic else { return }
                        self.automaticEstimate = estimate
                        self.playbackStore.saveAutomaticEstimate(estimate)
                        gate.succeeded(at: Date())
                    } catch {
                        guard !Task.isCancelled else { return }
                        gate.failed(at: Date())
                    }
                }
                // Cached local estimates (or route average for unknown sections)
                // keep playback running through offline/throttled requests.
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
            }
        }
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
    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool,
                       reportError: Bool = true) -> Bool {
        let wasInterrupted = status.isDropped || status == .reconnecting
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
            if routeRunning {
                remainingRouteCoordinates = RouteLine.remaining(activeRouteCoordinates, from: coordinate,
                                                                nextWaypoint: nextWaypoint)
            }
            if !routeRunning {
                playbackStore.setHold(Self.storedPoint(holdTarget ?? coordinate))
            }
            if holdTarget != nil { holdingDestination = true }
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
            // An interruption never clears persistent intent or sends a clear
            // command. Freeze the route at its last confirmed cursor and retry.
            saveRouteCheckpoint(force: true)
            if !routeRunning, let saved = holdTarget ?? simulated {
                playbackStore.setHold(Self.storedPoint(saved))
            }
            if reportError { lastError = error.localizedDescription }
            if simulated != nil || holdTarget != nil || routeRunning {
                status = .dropped(error.localizedDescription)
                if !wasInterrupted { postDropNotification(error.localizedDescription) }
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
        let dt = 0.25
        let speed = joystickVariation.joystickSpeed(baseMPH: speedMPH * min(1, magnitude),
                                                    elapsed: joystickElapsed, interval: dt, enabled: variesSpeed)
        joystickElapsed += dt
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        guard resendTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.resendTimer != nil,
                      let target = self.holdTarget ?? self.simulated else { return }
                _ = self.apply(target, pairing: pairing, markRecent: false, reportError: false)
            }
        }
        resendTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.healthTimer != nil,
                      let sim = self.holdTarget ?? self.simulated else { return }
                self.audioKeeper.start()
                if case .dropped = self.status {
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false, reportError: false)
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false, reportError: false)
                }
            }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        locationKeeper.beginBackgroundActivity()
        audioKeeper.start()
        guard !backgroundSessionStarted else { return }
        backgroundSessionStarted = true
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackground() {
        locationKeeper.endBackgroundActivity()
        audioKeeper.stop()
        backgroundSessionStarted = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String, restoring: Bool = false) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = restoring ? "Location restore failed" : "Waypoint connection interrupted"
        content.body = restoring ? message : "Saved location kept. Retrying the developer tunnel. \(message)"
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
