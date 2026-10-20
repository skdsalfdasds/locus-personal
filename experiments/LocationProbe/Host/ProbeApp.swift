import SwiftUI
import CoreLocation
import CoreMotion

@main
struct ProbeApp: App {
    @StateObject private var observer = LocationObserver()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Location delivered by iOS") {
                        Text(observer.authorizationSummary).accessibilityIdentifier("observed-authorization")
                        Text(observer.locationSummary).accessibilityIdentifier("observed-location")
                        Text(observer.speedSummary).accessibilityIdentifier("observed-speed")
                        Text("Samples: \(observer.sampleCount)").accessibilityIdentifier("observed-count")
                        Text(observer.sourceSummary)
                    }
                    Section("Actual motion activity") {
                        Text(observer.motionSummary).accessibilityIdentifier("observed-motion")
                    }
                    Section {
                        Button("Start observing") { observer.start() }
                            .accessibilityIdentifier("start-observing")
                        Button("Request simulator control") { observer.requestSimulatorControl() }
                            .accessibilityIdentifier("request-simulator-control")
                        if ProcessInfo.processInfo.environment["WAYPOINT_PROBE_RELAY_TOKEN"] != nil {
                            Button("Relay cruise sample") { observer.relay(speed: 30, latitude: 37.3371) }
                                .accessibilityIdentifier("relay-cruise")
                            Button("Relay stationary sample") { observer.relay(speed: 0, latitude: 37.3381) }
                                .accessibilityIdentifier("relay-stationary")
                            Button("Try unauthorized relay sample") { observer.relay(speed: 90, latitude: 38, unauthorized: true) }
                                .accessibilityIdentifier("relay-unauthorized")
                        }
                        Text("This app observes iOS location and motion. Explicit relay buttons send test samples to the separate XCTest runner. No motion activity setter is used.")
                        Text("Observations are stored locally in Documents/location-observations.jsonl. They can contain location data.")
                    }
                }.navigationTitle("Waypoint Probe")
                    .safeAreaInset(edge: .bottom) {
                        Text(observer.relaySummary).font(.footnote).padding(8)
                            .frame(maxWidth: .infinity).background(.bar)
                            .accessibilityIdentifier("relay-status")
                    }
            }
        }
    }
}

final class LocationObserver: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var locationSummary = "Waiting for a location"
    @Published var speedSummary = "speed-ms: unavailable"
    @Published var sourceSummary = "No source information"
    @Published var motionSummary = "Not observing"
    @Published var authorizationSummary = "Authorization: not requested"
    @Published var sampleCount = 0
    @Published var relaySummary = "Relay not requested"
    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var started = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        guard !started else { return }
        started = true
        append(["kind": "started", "timestamp": Date().timeIntervalSince1970])
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            motion.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                let flags: [String: Bool] = ["automotive": activity.automotive,
                    "walking": activity.walking, "running": activity.running,
                    "cycling": activity.cycling, "stationary": activity.stationary,
                    "unknown": activity.unknown]
                self.motionSummary = flags.filter { $0.value }.map { $0.key }.sorted().joined(separator: ", ")
                self.append(["kind": "motion", "flags": flags,
                             "confidence": activity.confidence.rawValue,
                             "timestamp": activity.startDate.timeIntervalSince1970])
            }
        } else {
            motionSummary = "Motion activity unavailable on this device"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorizationSummary = "Authorization: \(status.rawValue)"
        append(["kind": "authorization", "status": status.rawValue,
                "timestamp": Date().timeIntervalSince1970])
        if started && (status == .authorizedWhenInUse || status == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for sample in locations {
            sampleCount += 1
            let age = Date().timeIntervalSince(sample.timestamp)
            locationSummary = String(format: "%.6f, %.6f · age %.1fs", sample.coordinate.latitude, sample.coordinate.longitude, age)
            speedSummary = String(format: "speed-ms: %.3f · accuracy: %.3f · course: %.2f", sample.speed, sample.speedAccuracy, sample.course)
            sourceSummary = "Simulated by software: \(sample.sourceInformation?.isSimulatedBySoftware == true ? "yes" : "no")"
            append(["kind": "location", "latitude": sample.coordinate.latitude,
                    "longitude": sample.coordinate.longitude, "speed": sample.speed,
                    "speedAccuracy": sample.speedAccuracy, "course": sample.course,
                    "horizontalAccuracy": sample.horizontalAccuracy, "age": age,
                    "timestamp": sample.timestamp.timeIntervalSince1970,
                    "simulatedBySoftware": sample.sourceInformation?.isSimulatedBySoftware ?? false])
        }
    }

    func requestSimulatorControl() {
        #if targetEnvironment(simulator)
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data("requested".utf8).write(to: directory.appendingPathComponent("simulator-control.request"), options: .atomic)
        #endif
    }

    func relay(speed: Double, latitude: Double, unauthorized: Bool = false) {
        guard let configured = ProcessInfo.processInfo.environment["WAYPOINT_PROBE_RELAY_TOKEN"] else { return }
        relaySummary = "Sending relay sample"
        let token = unauthorized ? String(repeating: "0", count: 64) : configured
        let sample = RichLocationSample(latitude: latitude, longitude: -122.009,
            altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: speed, speedAccuracy: 0.1, course: 90,
            courseAccuracy: 1, timestamp: Date().timeIntervalSince1970)
        Task { @MainActor in
            do {
                try await RichLocationRelayClient(token: token).send(sample)
                relaySummary = "Relay accepted"
            } catch {
                relaySummary = error.localizedDescription
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationSummary = error.localizedDescription
        append(["kind": "locationError", "domain": (error as NSError).domain,
                "code": (error as NSError).code, "timestamp": Date().timeIntervalSince1970])
    }

    private func append(_ record: [String: Any]) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let path = directory.appendingPathComponent("location-observations.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: path) else { return }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: data) } catch { }
    }
}
