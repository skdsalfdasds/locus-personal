import XCTest
import CoreLocation

/// Experimental transport check. A successful setter is not evidence that another
/// app received speed; the observer's independent callbacks are the evidence.
@MainActor
final class LocationInterfaceTests: XCTestCase {
    func testRichLocationDelivery() throws {
        // Use the configured target application so XCTest can install its
        // simulation hooks. Explicit bundle selection remains an opt-in probe.
        let app: XCUIApplication
        if let bundleID = ProcessInfo.processInfo.environment["WAYPOINT_PROBE_HOST_BUNDLE_ID"] {
            app = XCUIApplication(bundleIdentifier: bundleID)
        } else {
            app = XCUIApplication()
        }
        // Follow Apple's documented ordering: configure the proxy before launch.
        // The independently seeded simulator baseline remains a separate control.
        let launchSample = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.3354, longitude: -122.0090),
            altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, courseAccuracy: 1, speed: 30, speedAccuracy: 0.1,
            timestamp: Date())
        XCUIDevice.shared.location = XCUILocation(location: launchSample)
        app.launch()
        addUIInterruptionMonitor(withDescription: "Probe observation permissions") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.buttons["start-observing"].tap()
        app.tap()
        #if targetEnvironment(simulator)
        let speedLabel = app.staticTexts["observed-speed"]
        let baseline = expectation(for: NSPredicate(format: "label != %@", "speed-ms: unavailable"),
                                   evaluatedWith: speedLabel)
        let baselineResult = XCTWaiter.wait(for: [baseline], timeout: 10)
        print("WAYPOINT_SIMULATOR_BASELINE \(speedLabel.label)")
        print("WAYPOINT_LAUNCH_PROXY \(app.staticTexts["observed-location"].label)")
        XCTAssertEqual(baselineResult, .completed,
                       "The independent simulator baseline delivered no location; rich-location delivery is inconclusive")
        guard baselineResult == .completed else { return }
        #endif
        let launchFields = app.staticTexts["observed-speed"].label
        let launchSpeed = launchFields.components(separatedBy: "speed-ms: ").last?
            .components(separatedBy: " ").first.flatMap(Double.init)
        print("WAYPOINT_LAUNCH_FIELDS requestedSpeed=30 requestedCourse=90 observed=\(launchFields)")
        XCTAssertNotNil(launchSpeed, "Launch proxy produced no speed sample")
        if let launchSpeed {
            XCTAssertEqual(launchSpeed, 30, accuracy: 0.2,
                           "The launch proxy did not preserve requested speed")
        }
        // Check Apple's minimal documented initializer before sending richer
        // samples. If even coordinates do not change, this is a proxy failure,
        // not evidence about which fields the proxy preserves.
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3359, longitude: -122.0090))
        let proxy = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "37.335900"),
                                evaluatedWith: app.staticTexts["observed-location"])
        let proxyResult = XCTWaiter.wait(for: [proxy], timeout: 10)
        print("WAYPOINT_COORDINATE_PROXY \(app.staticTexts["observed-location"].label)")
        XCTAssertEqual(proxyResult, .completed,
                       "XCTest coordinate proxy was ignored; this setup cannot establish rich-location delivery")
        guard proxyResult == .completed else { return }
        // Synthetic public coordinate. Never upload real observed coordinates.
        let latitude = 37.3349
        let longitude = -122.0090
        let metersPerLongitudeDegree = 111_320.0 * cos(latitude * .pi / 180)
        var position = 0.0
        for (name, speed, duration) in [("stationary", 0.0, 4), ("cruise", 30.0, 12), ("stopped", 0.0, 4)] {
            let observation = XCTContext.runActivity(named: name) { _ in
                for _ in 0..<(duration * 2) {
                    position += speed * 0.5
                    let sample = CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude + position / metersPerLongitudeDegree),
                        altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
                        course: 90, courseAccuracy: 1, speed: speed, speedAccuracy: 0.1,
                        timestamp: Date())
                    XCUIDevice.shared.location = XCUILocation(location: sample)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                return app.staticTexts["observed-speed"].label
            }
            print("WAYPOINT_LOCATION_PROBE phase=\(name) requestedSpeed=\(speed) observed=\(observation)")
            print("WAYPOINT_PROBE_AUTH \(app.staticTexts["observed-authorization"].label)")
            print("WAYPOINT_PROBE_LOCATION \(app.staticTexts["observed-location"].label)")
            if name == "cruise" {
                let value = observation.components(separatedBy: "speed-ms: ").last?
                    .components(separatedBy: " ").first.flatMap(Double.init)
                print("WAYPOINT_SPEED_DELIVERY requested=\(speed) observed=\(value.map(String.init(describing:)) ?? "unavailable")")
                // A green test now means the observer actually received speed,
                // not just that the XCTest setter accepted an input object.
                XCTAssertNotNil(value, "The independent observer did not report speed")
                if let value {
                    XCTAssertEqual(value, speed, accuracy: 0.2,
                                   "The location interface did not preserve requested speed")
                }
            }
            let attachment = XCTAttachment(string: "phase=\(name) requestedSpeed=\(speed) observed=\(observation)")
            attachment.name = "Location fields - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Deliberately no clear-location command: stopping and restoring remain
        // separate operations. XCTest itself may clean up when its session ends.
        XCTAssertTrue(app.staticTexts["observed-speed"].exists)
    }
}
