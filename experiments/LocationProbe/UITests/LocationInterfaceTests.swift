import XCTest
import CoreLocation

/// Independent observer callbacks are the evidence, not a successful setter.
@MainActor
final class LocationInterfaceTests: XCTestCase {
    private func waitForCoordinate(_ prefix: String, in app: XCUIApplication) -> Bool {
        let update = expectation(for: NSPredicate(format: "label BEGINSWITH %@", prefix),
                                 evaluatedWith: app.staticTexts["observed-location"])
        return XCTWaiter.wait(for: [update], timeout: 30) == .completed
    }

    func testRichLocationDelivery() throws {
        let app = XCUIApplication()
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
        let baseline = expectation(for: NSPredicate(format: "label != %@", "speed-ms: unavailable"),
                                   evaluatedWith: app.staticTexts["observed-speed"])
        XCTAssertEqual(XCTWaiter.wait(for: [baseline], timeout: 12), .completed,
                       "Independent simulator baseline delivered no location")
        print("WAYPOINT_STREAM_BASELINE \(app.staticTexts["observed-location"].label) \(app.staticTexts["observed-count"].label)")
        app.buttons["request-simulator-control"].tap()
        let streaming = waitForCoordinate("37.336900", in: app)
        print("WAYPOINT_STREAM_CONTROL delivered=\(streaming) \(app.staticTexts["observed-count"].label)")
        XCTAssertTrue(streaming, "Independent live simulator movement did not reach the observer; transport assessment is inconclusive")
        guard streaming else { return }
        #endif
        // No public launch proxy is configured: it must not mask the live stream.
        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.3354, longitude: -122.0090),
            altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, courseAccuracy: 1, speed: 30, speedAccuracy: 0.1, timestamp: Date())
        let reply = WPSetDaemonLocation(first)
        print("WAYPOINT_DAEMON_REPLY \(reply)")
        XCTAssertTrue(reply["supported"] as? Bool == true, "Runtime does not support daemon simulation")
        XCTAssertTrue(reply["accepted"] as? Bool == true, "Daemon rejected a rich location")
        guard reply["accepted"] as? Bool == true else { return }
        let delivered = waitForCoordinate("37.335400", in: app)
        print("WAYPOINT_DAEMON_DELIVERY delivered=\(delivered) \(app.staticTexts["observed-speed"].label)")
        XCTAssertTrue(delivered, "Live daemon sample was not delivered after independent streaming was confirmed")
        guard delivered else { return }

        let latitude = 37.3354
        let longitude = -122.0090
        let metersPerLongitudeDegree = 111_320.0 * cos(latitude * .pi / 180)
        var position = 0.0
        for (name, speed, duration) in [("stationary", 0.0, 4), ("cruise", 30.0, 12), ("stopped", 0.0, 4)] {
            for _ in 0..<(duration * 2) {
                position += speed * 0.5
                let sample = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude + position / metersPerLongitudeDegree),
                    altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
                    course: 90, courseAccuracy: 1, speed: speed, speedAccuracy: 0.1, timestamp: Date())
                let result = WPSetDaemonLocation(sample)
                XCTAssertTrue(result["accepted"] as? Bool == true, "Daemon rejected a route sample")
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            let observation = app.staticTexts["observed-speed"].label
            print("WAYPOINT_LOCATION_PROBE phase=\(name) requestedSpeed=\(speed) observed=\(observation) \(app.staticTexts["observed-count"].label)")
            let value = observation.components(separatedBy: "speed-ms: ").last?
                .components(separatedBy: " ").first.flatMap(Double.init)
            XCTAssertNotNil(value, "The observer did not report speed")
            if let value { XCTAssertEqual(value, speed, accuracy: 0.2, "Requested speed was not preserved") }
            let attachment = XCTAttachment(string: "phase=\(name) requestedSpeed=\(speed) observed=\(observation)")
            attachment.name = "Location fields - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // No command to restore real location: stopping and clearing are distinct.
    }
}
