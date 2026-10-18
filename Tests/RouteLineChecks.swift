import CoreLocation

@main
struct RouteLineChecks {
    static func main() {
        func point(_ longitude: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: 0, longitude: longitude)
        }
        func longitudes(_ line: [CLLocationCoordinate2D]) -> [Double] { line.map(\.longitude) }
        let route = [point(0), point(0.001), point(0.002), point(0.003)]
        let middle = RouteLine.remaining(route, from: point(0.0015), nextWaypoint: 2)
        precondition(longitudes(middle) == [0.0015, 0.002, 0.003])
        precondition(longitudes(RouteLine.remaining(route, from: point(0.0025), nextWaypoint: 3)) == [0.0025, 0.003])
        print("PASS: traveled segments disappear and remaining line starts at the current position")

        let loop = [point(0), point(0.001), point(0), point(0.002)]
        precondition(longitudes(RouteLine.remaining(loop, from: point(0.0005), nextWaypoint: 1)) == [0.0005, 0.001, 0, 0.002])
        precondition(longitudes(RouteLine.remaining(loop, from: point(0), nextWaypoint: 3)) == [0, 0.002])
        print("PASS: crossing/repeated coordinates follow the cursor without skipping the loop")
        precondition(RouteLine.remaining(route, from: point(0.003), nextWaypoint: route.count).isEmpty)
        precondition(RouteLine.remaining([], from: point(0), nextWaypoint: 1).isEmpty)
        print("PASS: completed or missing routes draw no stale line")
        precondition(RouteLine.bendSeverity(route, nextWaypoint: 1) == 0)
        let turn = [point(0), point(0.0001), CLLocationCoordinate2D(latitude: 0.0001, longitude: 0.0001)]
        precondition(RouteLine.bendSeverity(turn, nextWaypoint: 1) > 0.7)
        precondition(RouteLine.bendSeverity(turn, nextWaypoint: turn.count - 1) == 0)
        precondition(RouteLine.bendSeverity([point(0), point(0), point(0.001)], nextWaypoint: 1) == 0)
        print("PASS: bend anticipation distinguishes turns from straight and repeated points")
    }
}
