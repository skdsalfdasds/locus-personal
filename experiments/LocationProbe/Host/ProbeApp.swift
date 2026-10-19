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
                        Text(observer.locationSummary).accessibilityIdentifier("observed-location")
                        Text(observer.speedSummary).accessibilityIdentifier("observed-speed")
                        Text(observer.sourceSummary)
                    }
                    Section("Actual motion activity") {
                        Text(observer.motionSummary).accessibilityIdentifier("observed-motion")
                    }
                    Section {
                        Button("Start observing") { observer.start() }
                            .accessibilityIdentifier("start-observing")
                        Text("This app reads iOS values. It does not alter speed or motion activity. The separate XCTest runner changes location only during an explicit probe.")
                        Text("Observations are stored locally in Documents/location-observations.jsonl. They can contain location data.")
                    }
                }.navigationTitle("Waypoint Probe")
            }
        }
    }
}

final class LocationObserver: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var locationSummary = "Waiting for a location"
    @Published var speedSummary = "speed-ms: unavailable"
    @Published var sourceSummary = "No source information"
    @Published var motionSummary = "Not observing"
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for sample in locations {
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

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationSummary = error.localizedDescription
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
