import Foundation

/// Small, continuous changes around the selected/traffic-derived average.
/// Curvature adds a gentle slowdown; this is not a road-speed-limit model.
struct SpeedVariation {
    private(set) var metersPerSecond: Double?

    static func multiplier(elapsed: TimeInterval, bendSeverity: Double) -> Double {
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        let bend = bendSeverity.isFinite ? min(1, max(0, bendSeverity)) : 0
        let drift = 0.025 * sin(time * 2 * .pi / 50) + 0.015 * sin(time * 2 * .pi / 19)
        return min(1.08, max(0.92, 1 + drift - 0.04 * bend))
    }

    mutating func duration(distanceMeters: Double, baseMPH: Double, elapsed: TimeInterval,
                           bendSeverity: Double, enabled: Bool,
                           smoothTransitions: Bool = false) -> TimeInterval {
        let base = MovementTiming.metersPerSecond(mph: baseMPH)
        let target = base * (enabled ? Self.multiplier(elapsed: elapsed, bendSeverity: bendSeverity) : 1)
        let start = metersPerSecond ?? base
        guard distanceMeters > 0 else { return 0 }
        guard enabled || smoothTransitions, abs(target - start) > 0.000001 else {
            metersPerSecond = target
            return distanceMeters / target
        }
        let rate = target > start ? MovementTiming.paceAcceleration : -MovementTiming.paceBraking
        let rampTime = (target - start) / rate
        let rampDistance = (start + target) * 0.5 * rampTime
        if distanceMeters < rampDistance {
            let end = sqrt(max(0, start * start + 2 * rate * distanceMeters))
            metersPerSecond = end
            return 2 * distanceMeters / (start + end)
        }
        metersPerSecond = target
        return rampTime + (distanceMeters - rampDistance) / target
    }

    mutating func joystickSpeed(baseMPH: Double, elapsed: TimeInterval, interval: TimeInterval,
                                enabled: Bool) -> Double {
        let base = MovementTiming.metersPerSecond(mph: baseMPH)
        let target = base * (enabled ? Self.multiplier(elapsed: elapsed, bendSeverity: 0) : 1)
        guard enabled else {
            metersPerSecond = target
            return target
        }
        let start = metersPerSecond ?? base
        let limit = (target > start ? MovementTiming.paceAcceleration : MovementTiming.paceBraking) * interval
        let end = start + min(limit, max(-limit, target - start))
        metersPerSecond = end
        return (start + end) * 0.5
    }
}
