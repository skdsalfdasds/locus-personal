import Foundation

@main
struct AutomaticPacingChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let locations = (0...6).map {
            AutomaticPacing.Location(latitude: 0, longitude: Double($0) * 0.0045)
        }
        let cumulative = (0...6).map { Double($0) * 500 }
        var profile = AutomaticPacing.makeProfile(locations: locations, cumulativeMeters: cumulative)!
        precondition(profile.isValid && profile.sections.count == 3)
        let city = AutomaticTravel.estimate(distanceMeters: 1000, seconds: 200, now: now)!
        let freeway = AutomaticTravel.estimate(distanceMeters: 1000, seconds: 40, now: now)!
        let jam = AutomaticTravel.estimate(distanceMeters: 1000, seconds: 500, now: now)!
        profile.sections[0].estimate = city
        profile.sections[1].estimate = freeway
        profile.sections[2].estimate = jam
        precondition(abs(profile.targetMPH(at: 2500, fallbackMPH: 30) - city.targetMPH) < 0.000001)
        precondition(abs(profile.targetMPH(at: 1800, fallbackMPH: 30) - freeway.targetMPH) < 0.000001)
        precondition(abs(profile.targetMPH(at: 500, fallbackMPH: 30) - jam.targetMPH) < 0.000001)
        precondition(profile.targetMPH(at: 1500, fallbackMPH: 30) < freeway.targetMPH)
        precondition(profile.targetMPH(at: 1010, fallbackMPH: 30) < profile.targetMPH(at: 1500, fallbackMPH: 30))
        precondition(freeway.targetMPH > city.targetMPH && city.targetMPH > jam.targetMPH)
        precondition(profile.index(at: 2000) == 1 && profile.index(at: 1000) == 2)
        precondition(abs(profile.remainingSeconds(2500, fallbackMPH: 30) - 640) < 0.00001)
        print("PASS: street, freeway, and congested sections set distinct local speeds; ETA integrates the remaining sections")

        // Offline/stale data remains useful; unknown sections use the explicit fallback.
        precondition(abs(profile.targetMPH(at: 500, fallbackMPH: 30) - jam.targetMPH) < 0.000001)
        profile.sections[1].estimate = nil
        precondition(abs(profile.targetMPH(at: 1800, fallbackMPH: 30) - 30) < 0.000001)
        precondition(profile.requestIndex(at: 2500, now: now.addingTimeInterval(400)) == 1)
        profile.sections[1].retryAfter = now.addingTimeInterval(500)
        precondition(profile.requestIndex(at: 2500, now: now.addingTimeInterval(400)) == 0)
        precondition(profile.requestIndex(at: 500, now: now.addingTimeInterval(400)) == 2)
        print("PASS: cached pace survives stale/offline conditions; lookahead stays ahead of the cursor and respects backoff")

        var gate = AutomaticPacing.RefreshGate()
        gate.succeeded(at: now)
        precondition(!gate.allows(now.addingTimeInterval(19)))
        precondition(gate.allows(now.addingTimeInterval(20)))
        for delay in [60.0, 120, 240, 300, 300] {
            gate.failed(at: now)
            precondition(abs(gate.nextRequest.timeIntervalSince(now) - delay) < 0.000001)
        }
        gate.succeeded(at: now)
        gate.failed(at: now)
        precondition(gate.nextRequest == now.addingTimeInterval(60))
        precondition(AutomaticPacing.acceptsDistance(pathMeters: 1000, etaMeters: 1020))
        precondition(!AutomaticPacing.acceptsDistance(pathMeters: 1000, etaMeters: 500))
        precondition(!AutomaticPacing.acceptsDistance(pathMeters: 1000, etaMeters: 1500))
        precondition(!AutomaticPacing.acceptsDistance(pathMeters: .nan, etaMeters: 1000))
        print("PASS: requests are spaced, errors back off, and obvious shortcut/detour ETA distances are rejected")

        // An overlapping route may revisit a coordinate; section selection uses progress.
        let loop = AutomaticPacing.makeProfile(locations: [locations[0], locations[1], locations[0], locations[1]],
                                               cumulativeMeters: [0, 1000, 2000, 3000])!
        precondition(loop.index(at: 2500) == 0 && loop.index(at: 500) == 2)
        let tail = AutomaticPacing.makeProfile(locations: Array(locations.prefix(4)), cumulativeMeters: [0, 500, 1000, 1100])!
        precondition(tail.sections.count == 1 && tail.totalMeters == 1100)
        precondition(AutomaticPacing.makeProfile(locations: Array(locations.prefix(3)), cumulativeMeters: [0, 1000, 500]) == nil)
        print("PASS: repeated coordinates cannot skip sections; tiny tails are merged and invalid paths rejected")

        let suite = "AutomaticPacingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let points = locations.map { PlaybackStore.Point(latitude: $0.latitude, longitude: $0.longitude) }
        let store = PlaybackStore(defaults: defaults)
        profile.sections[1].estimate = freeway
        store.beginRoute(points, paused: false, automaticEstimate: city, automaticProfile: profile)
        store.checkpoint(position: points[3], nextWaypoint: 4, paused: true, force: true)
        let recovered = PlaybackStore(defaults: defaults).recoverRoute()!
        precondition(recovered.paused && recovered.remaining.first == points[3])
        precondition(recovered.automaticProfile!.totalMeters == 3000)
        precondition(abs(recovered.automaticProfile!.targetMPH(at: 1500, fallbackMPH: 30)
            - profile.targetMPH(at: 1500, fallbackMPH: 30)) < 0.000001)
        store.setHold(points[3])
        precondition(store.recoverRoute() == nil && defaults.data(forKey: "locus.resumeAutomaticProfile") == nil)
        store.beginRoute(points, paused: false)
        precondition(store.recoverRoute()!.automaticProfile == nil)
        store.clear()
        precondition(defaults.data(forKey: "locus.resumeAutomaticProfile") == nil)
        print("PASS: reopening keeps section positions and cached speeds; Stop, manual routes, and Restore retire old profiles")
    }
}
