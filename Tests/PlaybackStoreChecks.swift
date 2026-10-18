import Foundation

@main
struct PlaybackStoreChecks {
    static func main() {
        let suite = "LocusPlaybackChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackStore(defaults: defaults)
        let start = PlaybackStore.Point(latitude: 0, longitude: 0)
        let middle = PlaybackStore.Point(latitude: 0, longitude: 0.001)
        let destination = PlaybackStore.Point(latitude: 0, longitude: 0.002)
        store.beginRoute([start, middle, destination], paused: false)
        let firstRecovery = store.recoverRoute()!
        precondition(firstRecovery.remaining == [start, middle, destination])
        precondition(!firstRecovery.paused)

        let confirmed = PlaybackStore.Point(latitude: 0, longitude: 0.0014)
        store.checkpoint(position: confirmed, nextWaypoint: 2, paused: true, force: true)
        let reopened = PlaybackStore(defaults: defaults)
        let recovery = reopened.recoverRoute()!
        precondition(recovery.remaining == [confirmed, destination])
        precondition(recovery.paused)
        print("PASS: reopening resumes from confirmed progress and preserves pause")

        reopened.setHold(destination)
        let afterArrival = PlaybackStore(defaults: defaults)
        precondition(afterArrival.recoverRoute() == nil)
        precondition(afterArrival.hold == destination)
        print("PASS: arrival persists destination hold and retires route")

        afterArrival.clear()
        let afterStop = PlaybackStore(defaults: defaults)
        precondition(afterStop.recoverRoute() == nil && afterStop.hold == nil)
        print("PASS: Stop removes all automatic restoration intent")

        store.beginRoute([start, middle], paused: false)
        store.checkpoint(position: start, nextWaypoint: 99, paused: false, force: true)
        precondition(store.recoverRoute() == nil)
        store.beginRoute([start, .init(latitude: 91, longitude: 0)], paused: false)
        precondition(store.recoverRoute() == nil)
        print("PASS: invalid coordinates and waypoint indexes cannot restore")
    }
}
