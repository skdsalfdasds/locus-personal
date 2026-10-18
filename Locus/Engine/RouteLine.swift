import CoreLocation

enum RouteLine {
    /// Use playback's cursor, not the nearest road point: routes can cross or
    /// revisit the same coordinates without jumping to a later part of a loop.
    static func remaining(_ route: [CLLocationCoordinate2D],
                          from current: CLLocationCoordinate2D,
                          nextWaypoint: Int) -> [CLLocationCoordinate2D] {
        guard route.count > 1, nextWaypoint >= 1, nextWaypoint < route.count,
              CLLocationCoordinate2DIsValid(current) else { return [] }
        return [current] + route.dropFirst(nextWaypoint)
    }
}
