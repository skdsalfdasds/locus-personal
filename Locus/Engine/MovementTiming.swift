import Foundation

/// Shared units and pacing used by playback, the speed control, and ETA.
enum MovementTiming {
    static let metersPerMile = 1609.344

    static func metersPerSecond(mph: Double) -> Double {
        max(0.1, mph.isFinite ? mph : 1) * metersPerMile / 3600
    }

    static func duration(distanceMeters: Double, mph: Double) -> TimeInterval {
        max(0, distanceMeters) / metersPerSecond(mph: mph)
    }

    static func stepDuration(distanceMeters: Double, steps: Int, mph: Double) -> TimeInterval {
        duration(distanceMeters: distanceMeters, mph: mph) / Double(max(1, steps))
    }

    static func etaLabel(seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let minutes = max(0, Int(ceil(seconds / 60)))
        if minutes == 0 { return "Arrived" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}
