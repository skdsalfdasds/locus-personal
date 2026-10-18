import Foundation

/// Local traffic estimates are anchored to distance remaining, so recovery of a
/// shortened route does not shift their location or confuse crossings/loops.
enum AutomaticPacing {
    static let sectionMeters = 1000.0
    static let requestInterval: TimeInterval = 20

    struct Location: Codable {
        let latitude: Double
        let longitude: Double

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite &&
                (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }

    struct Section: Codable {
        let start: Location
        let end: Location
        let upperRemaining: Double
        let lowerRemaining: Double
        var estimate: AutomaticTravel.Estimate?
        var retryAfter: Date?

        var distanceMeters: Double { upperRemaining - lowerRemaining }
    }

    struct Profile: Codable {
        var sections: [Section]

        var totalMeters: Double { sections.first?.upperRemaining ?? 0 }

        var isValid: Bool {
            guard !sections.isEmpty else { return false }
            for (index, section) in sections.enumerated() {
                guard section.start.isValid, section.end.isValid,
                      section.upperRemaining.isFinite, section.lowerRemaining.isFinite,
                      section.lowerRemaining >= 0, section.distanceMeters > 0 else { return false }
                if index > 0, abs(sections[index - 1].lowerRemaining - section.upperRemaining) > 0.01 {
                    return false
                }
                if let estimate = section.estimate,
                   AutomaticTravel.estimate(distanceMeters: estimate.distanceMeters,
                                            seconds: estimate.expectedSeconds) == nil { return false }
            }
            return abs(sections.last!.lowerRemaining) < 0.01
        }

        func index(at remaining: Double) -> Int? {
            guard remaining.isFinite, remaining >= 0, remaining <= totalMeters + 1 else { return nil }
            return sections.firstIndex { remaining > $0.lowerRemaining } ?? (sections.isEmpty ? nil : sections.count - 1)
        }

        func targetMPH(at remaining: Double, fallbackMPH: Double) -> Double {
            guard let index = index(at: remaining) else { return fallbackMPH }
            let currentMPH = sections[index].estimate?.targetMPH ?? fallbackMPH
            var speed = MovementTiming.metersPerSecond(mph: currentMPH)
            // Start easing down before a known slower section, instead of
            // carrying freeway pace across the start of a congestion estimate.
            for next in (index + 1)..<min(sections.count, index + 3) {
                guard let estimate = sections[next].estimate else { continue }
                let nextSpeed = MovementTiming.metersPerSecond(mph: estimate.targetMPH)
                let ahead = max(0, remaining - sections[next].upperRemaining)
                speed = min(speed, sqrt(nextSpeed * nextSpeed + 2 * MovementTiming.paceBraking * ahead))
            }
            return speed / 0.44704
        }

        func remainingSeconds(_ remaining: Double, fallbackMPH: Double) -> TimeInterval {
            guard remaining.isFinite, remaining > 0 else { return 0 }
            var covered = 0.0
            var seconds = 0.0
            for section in sections {
                let distance = max(0, min(remaining, section.upperRemaining) - section.lowerRemaining)
                covered += distance
                seconds += MovementTiming.duration(distanceMeters: distance,
                                                    mph: section.estimate?.targetMPH ?? fallbackMPH)
            }
            return seconds + MovementTiming.duration(distanceMeters: max(0, remaining - covered), mph: fallbackMPH)
        }

        /// One current section and at most two ahead. Missing samples take
        /// priority over refreshing stale ones; failed samples are backed off.
        func requestIndex(at remaining: Double, now: Date) -> Int? {
            guard let current = index(at: remaining) else { return nil }
            let candidates = current..<min(sections.count, current + 3)
            let eligible = candidates.filter { sections[$0].retryAfter.map { $0 <= now } ?? true }
            return eligible.first { sections[$0].estimate == nil } ?? eligible.first {
                now.timeIntervalSince(sections[$0].estimate!.fetchedAt) >= AutomaticTravel.refreshInterval
            }
        }
    }

    /// Inputs use actual cumulative path distances, not straight-line endpoints.
    static func makeProfile(locations: [Location], cumulativeMeters: [Double]) -> Profile? {
        guard locations.count >= 2, locations.count == cumulativeMeters.count,
              locations.allSatisfy(\.isValid), cumulativeMeters.first == 0,
              cumulativeMeters.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(cumulativeMeters, cumulativeMeters.dropFirst()).allSatisfy({ pair in pair.0 <= pair.1 }),
              let total = cumulativeMeters.last, total > 0 else { return nil }
        var bounds = [0]
        for index in 1..<locations.count {
            if cumulativeMeters[index] - cumulativeMeters[bounds.last!] >= sectionMeters {
                bounds.append(index)
            }
        }
        let last = locations.count - 1
        if bounds.last != last {
            // Avoid a tiny final section that would produce an unreliable ETA.
            if bounds.count > 1, total - cumulativeMeters[bounds.last!] < 250 { bounds.removeLast() }
            bounds.append(last)
        }
        let sections = zip(bounds, bounds.dropFirst()).compactMap { start, end -> Section? in
            guard cumulativeMeters[end] > cumulativeMeters[start] else { return nil }
            return Section(start: locations[start], end: locations[end],
                           upperRemaining: total - cumulativeMeters[start],
                           lowerRemaining: total - cumulativeMeters[end])
        }
        let profile = Profile(sections: sections)
        return profile.isValid ? profile : nil
    }

    /// ETA requests cannot constrain a route's intermediate path. Reject obvious
    /// shortcuts/detours; a similar distance still does not prove the same road.
    static func acceptsDistance(pathMeters: Double, etaMeters: Double) -> Bool {
        pathMeters.isFinite && etaMeters.isFinite && pathMeters > 0 && etaMeters > 0 &&
            abs(pathMeters - etaMeters) <= max(75, pathMeters * 0.15)
    }

    struct RefreshGate {
        private(set) var nextRequest = Date.distantPast
        private var failures = 0

        func allows(_ now: Date) -> Bool { now >= nextRequest }
        mutating func succeeded(at now: Date) {
            failures = 0
            nextRequest = now.addingTimeInterval(requestInterval)
        }
        mutating func failed(at now: Date) {
            failures = min(failures + 1, 4)
            nextRequest = now.addingTimeInterval(min(300, 30 * pow(2, Double(failures))))
        }
    }
}
