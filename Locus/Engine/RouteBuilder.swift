import CoreLocation
import Foundation
import MapKit

enum RouteBuilder {
    struct Plan {
        let coordinates: [CLLocationCoordinate2D]
        let automaticEstimate: AutomaticTravel.Estimate?
        let automaticProfile: AutomaticPacing.Profile?
    }
    static func distance(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
    static func roadRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> Plan {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = mode.mkTransportType
        request.requestsAlternateRoutes = false
        request.departureDate = Date()

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        guard let route = response.routes.first else {
            throw NSError(domain: "Locus", code: 1, userInfo: [NSLocalizedDescriptionKey: "No route found"])
        }
        let coordinates = sample(polyline: route.polyline, every: 12)
        // MKRoute.expectedTravelTime is documented as ideal-condition travel.
        // ETAResponse explicitly includes expected traffic; request that separately.
        let estimate = mode == .automatic
            ? try await trafficEstimate(from: start, to: end, distanceMeters: distance(coordinates)) : nil
        var profile = mode == .automatic ? automaticProfile(for: coordinates) : nil
        if let estimate, var local = profile, !local.sections.isEmpty {
            if local.sections.count == 1 {
                local.sections[0].estimate = estimate
            } else {
                do { local.sections[0].estimate = try await sectionTrafficEstimate(local.sections[0]) }
                catch {
                    try Task.checkCancellation()
                    local.sections[0].retryAfter = Date().addingTimeInterval(60)
                }
            }
            profile = local
        }
        try Task.checkCancellation()
        return Plan(coordinates: coordinates, automaticEstimate: estimate, automaticProfile: profile)
    }

    static func trafficEstimate(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                                distanceMeters: Double, matchingDistance: Bool = false,
                                departureDate: Date = Date()) async throws -> AutomaticTravel.Estimate {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        request.departureDate = departureDate
        let eta = try await MKDirections(request: request).calculateETA()
        try Task.checkCancellation()
        if matchingDistance, !AutomaticPacing.acceptsDistance(pathMeters: distanceMeters, etaMeters: eta.distance) {
            throw NSError(domain: "Locus", code: 4, userInfo: [NSLocalizedDescriptionKey: "The traffic estimate used a different path. Keeping the cached pace for this section."])
        }
        guard let estimate = AutomaticTravel.estimate(distanceMeters: distanceMeters, seconds: eta.expectedTravelTime) else {
            throw NSError(domain: "Locus", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple Maps did not return a usable traffic estimate. Try again or choose Drive for manual speed."])
        }
        return estimate
    }

    static func sectionTrafficEstimate(_ section: AutomaticPacing.Section,
                                       departureDate: Date = Date()) async throws -> AutomaticTravel.Estimate {
        try await trafficEstimate(
            from: CLLocationCoordinate2D(latitude: section.start.latitude, longitude: section.start.longitude),
            to: CLLocationCoordinate2D(latitude: section.end.latitude, longitude: section.end.longitude),
            distanceMeters: section.distanceMeters, matchingDistance: true, departureDate: departureDate)
    }

    static func automaticProfile(for coordinates: [CLLocationCoordinate2D]) -> AutomaticPacing.Profile? {
        guard let first = coordinates.first else { return nil }
        var cumulative = [0.0]
        var previous = first
        for coordinate in coordinates.dropFirst() {
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            cumulative.append(cumulative.last! + distance)
            previous = coordinate
        }
        return AutomaticPacing.makeProfile(locations: coordinates.map {
            AutomaticPacing.Location(latitude: $0.latitude, longitude: $0.longitude)
        }, cumulativeMeters: cumulative)
    }

    static func sample(polyline: MKPolyline, every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return sample(coordinates: coords, every: meters)
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / meters)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        return sampled
    }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "No track points found in GPX"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Waypoint Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Waypoint" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
