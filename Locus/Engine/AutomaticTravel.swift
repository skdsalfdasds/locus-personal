import Foundation

enum AutomaticTravel {
    static let refreshInterval: TimeInterval = 300

    struct Estimate: Codable {
        let distanceMeters: Double
        let expectedSeconds: TimeInterval
        let fetchedAt: Date

        var targetMPH: Double {
            min(85, max(0.1, distanceMeters / expectedSeconds / 0.44704))
        }
    }

    static func estimate(distanceMeters: Double, seconds: TimeInterval, now: Date = Date()) -> Estimate? {
        guard distanceMeters.isFinite, distanceMeters > 0, seconds.isFinite, seconds > 0 else { return nil }
        return Estimate(distanceMeters: distanceMeters, expectedSeconds: seconds, fetchedAt: now)
    }
}
