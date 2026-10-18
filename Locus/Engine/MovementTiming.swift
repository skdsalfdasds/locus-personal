import Foundation

/// Shared units and pacing used by playback, the speed control, and ETA.
enum MovementTiming {
    static let metersPerMile = 1609.344
    static let paceAcceleration = 0.35
    static let paceBraking = 0.55

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
        let rounded = ceil(max(0, seconds))
        guard rounded < Double(Int.max) else { return "—" }
        let total = Int(rounded)
        if total == 0 { return "Arrived" }
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d hr %02d min %02d sec", hours, minutes, remainder) }
        if minutes > 0 { return String(format: "%d min %02d sec", minutes, remainder) }
        return "\(remainder) sec"
    }
}
