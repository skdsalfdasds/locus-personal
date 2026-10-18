import Foundation

@main
struct AutomaticTravelChecks {
    static func main() {
        let normal = AutomaticTravel.estimate(distanceMeters: 1609.344, seconds: 60)!
        let traffic = AutomaticTravel.estimate(distanceMeters: 1609.344, seconds: 120)!
        precondition(abs(normal.targetMPH - 60) < 0.00001)
        precondition(abs(traffic.targetMPH - 30) < 0.00001)
        precondition(AutomaticTravel.estimate(distanceMeters: 1609344, seconds: 1)!.targetMPH == 85)
        precondition(AutomaticTravel.estimate(distanceMeters: 1, seconds: 1e9)!.targetMPH == 0.1)
        precondition(AutomaticTravel.estimate(distanceMeters: 1, seconds: 0) == nil)
        precondition(AutomaticTravel.estimate(distanceMeters: .nan, seconds: 1) == nil)
        precondition(AutomaticTravel.estimate(distanceMeters: 1, seconds: .infinity) == nil)
        print("PASS: traffic delay changes average speed; invalid ETA and speed bounds handled")

        let suite = "AutomaticTravelChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = PlaybackStore.Point(latitude: 0, longitude: 0)
        let end = PlaybackStore.Point(latitude: 0, longitude: 0.01)
        let store = PlaybackStore(defaults: defaults)
        store.beginRoute([start, end], paused: false, automaticEstimate: traffic)
        let restored = PlaybackStore(defaults: defaults).recoverRoute()!
        precondition(abs(restored.automaticEstimate!.targetMPH - 30) < 0.00001)
        precondition(restored.automaticEstimate!.fetchedAt == traffic.fetchedAt)
        print("PASS: cached automatic speed and timestamp survive route recovery without networking")

        store.saveAutomaticEstimate(normal)
        precondition(abs(store.recoverRoute()!.automaticEstimate!.targetMPH - 60) < 0.00001)
        store.setHold(end)
        store.beginRoute([start, end], paused: false)
        precondition(store.recoverRoute()!.automaticEstimate == nil)
        print("PASS: traffic refresh updates cache; manual routes cannot inherit stale automatic metadata")
    }
}
