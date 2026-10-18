import CoreLocation

enum RouteLine {
    static func bendSeverity(_ route: [CLLocationCoordinate2D], nextWaypoint: Int) -> Double {
        guard nextWaypoint >= 1, nextWaypoint + 1 < route.count else { return 0 }
        var severity = 0.0
        var aheadMeters = 0.0
        for index in nextWaypoint..<min(route.count - 1, nextWaypoint + 12) {
            let a = route[index - 1], b = route[index], c = route[index + 1]
            if index > nextWaypoint {
                aheadMeters += CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            }
            if aheadMeters > 60 { break }
            let longitudeScale = cos(b.latitude * .pi / 180)
            let ux = (b.longitude - a.longitude) * longitudeScale, uy = b.latitude - a.latitude
            let vx = (c.longitude - b.longitude) * longitudeScale, vy = c.latitude - b.latitude
            let length = hypot(ux, uy) * hypot(vx, vy)
            guard length > 0 else { continue }
            let angle = acos(min(1, max(-1, (ux * vx + uy * vy) / length)))
            let bend = min(1, angle / (.pi * 2 / 3)) * (1 - aheadMeters / 60)
            severity = max(severity, bend)
        }
        return severity
    }

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
