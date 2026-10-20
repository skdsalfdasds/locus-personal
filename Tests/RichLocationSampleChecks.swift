import CoreLocation
import Foundation

@main
struct RichLocationSampleChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func sample(latitude: Double = 37.3349, longitude: Double = -122.009,
                    speed: Double = 30, accuracy: Double = 0.1,
                    course: Double = 90, age: Double = 0) -> RichLocationSample {
            RichLocationSample(latitude: latitude, longitude: longitude,
                altitude: 15, horizontalAccuracy: 5, verticalAccuracy: 5,
                speed: speed, speedAccuracy: accuracy, course: course,
                courseAccuracy: 1, timestamp: now.timeIntervalSince1970 - age)
        }
        let observed = try sample().validatedLocation(at: now)
        precondition(observed.speed == 30 && observed.speedAccuracy == 0.1 && observed.course == 90)
        let stationary = try sample(speed: 0).validatedLocation(at: now)
        let boundary = try sample(age: 30).validatedLocation(at: now)
        precondition(stationary.speed == 0 && boundary.speed == 30)
        for invalid in [sample(latitude: -91), sample(latitude: 91),
                        sample(longitude: -181), sample(longitude: 181),
                        sample(latitude: .nan), sample(speed: .infinity),
                        sample(speed: -1), sample(speed: 121), sample(accuracy: -1),
                        sample(course: -1), sample(course: 360),
                        sample(age: 31), sample(age: -31)] {
            do {
                _ = try invalid.validatedLocation(at: now)
                preconditionFailure("Invalid sample reached Core Location")
            } catch RichLocationRelayError.invalidSample { }
        }
        precondition(validRelayToken(String(repeating: "a1", count: 32)))
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                        String(repeating: "z", count: 64)] {
            precondition(!validRelayToken(invalid))
            do {
                _ = try RichLocationRelayClient(token: invalid)
                preconditionFailure("Invalid session credential was accepted")
            } catch RichLocationRelayError.invalidToken { }
        }
        let request = RichLocationRelayRequest(version: 1, id: UUID(),
            token: String(repeating: "a1", count: 32), sample: sample())
        let decoded = try JSONDecoder().decode(RichLocationRelayRequest.self, from: JSONEncoder().encode(request))
        precondition(decoded.id == request.id && decoded.sample.speed == 30)
        print("Rich location field bounds, freshness, credential and serialization checks passed.")
    }
}
