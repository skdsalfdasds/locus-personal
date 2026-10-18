import Foundation

/// Durable route intent and last confirmed progress; never advances by time spent
/// terminated. The large route is written once, and small checkpoints separately.
final class PlaybackStore {
    struct Point: Codable, Equatable {
        let latitude: Double
        let longitude: Double

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }

    struct Progress: Codable {
        let position: Point
        let nextWaypoint: Int
        let paused: Bool
    }

    struct Recovery {
        let remaining: [Point]
        let paused: Bool
    }

    private let defaults: UserDefaults
    private let planKey = "locus.resumeRoutePlan"
    private let progressKey = "locus.resumeRouteProgress"
    private let holdKey = "locus.holdCoordinate"
    private var lastCheckpoint = Date.distantPast

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func beginRoute(_ points: [Point], paused: Bool) {
        clearRoute()
        guard points.count >= 2, points.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(points) else { return }
        defaults.set(data, forKey: planKey)
        checkpoint(position: points[0], nextWaypoint: 1, paused: paused, force: true)
    }

    func checkpoint(position: Point, nextWaypoint: Int, paused: Bool, force: Bool = false) {
        guard position.isValid, force || Date().timeIntervalSince(lastCheckpoint) >= 2 else { return }
        let progress = Progress(position: position, nextWaypoint: nextWaypoint, paused: paused)
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: progressKey)
        lastCheckpoint = Date()
    }

    func recoverRoute() -> Recovery? {
        guard let planData = defaults.data(forKey: planKey),
              let progressData = defaults.data(forKey: progressKey),
              let plan = try? JSONDecoder().decode([Point].self, from: planData),
              let progress = try? JSONDecoder().decode(Progress.self, from: progressData),
              plan.count >= 2, plan.allSatisfy(\.isValid), progress.position.isValid,
              progress.nextWaypoint >= 1, progress.nextWaypoint < plan.count else { return nil }
        return Recovery(remaining: [progress.position] + plan.dropFirst(progress.nextWaypoint), paused: progress.paused)
    }

    var hold: Point? {
        guard let values = defaults.array(forKey: holdKey) as? [Double], values.count == 2 else { return nil }
        let point = Point(latitude: values[0], longitude: values[1])
        return point.isValid ? point : nil
    }

    func setHold(_ point: Point) {
        guard point.isValid else { return }
        defaults.set([point.latitude, point.longitude], forKey: holdKey)
        clearRoute()
    }

    func clearRoute() {
        defaults.removeObject(forKey: progressKey)
        defaults.removeObject(forKey: planKey)
        lastCheckpoint = .distantPast
    }

    func clear() {
        clearRoute()
        defaults.removeObject(forKey: holdKey)
    }
}
