import CoreLocation
import Foundation
import Network

/// Transport for an explicitly started XCTest relay. Merely linking this file
/// does not connect, change backend, or alter an existing location session.
struct RichLocationSample: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double
    let speedAccuracy: Double
    let course: Double
    let courseAccuracy: Double
    let timestamp: Double

    func validatedLocation(at now: Date = Date()) throws -> CLLocation {
        let values = [latitude, longitude, altitude, horizontalAccuracy,
                      verticalAccuracy, speed, speedAccuracy, course,
                      courseAccuracy, timestamp]
        guard values.allSatisfy(\.isFinite), (-90...90).contains(latitude),
              (-180...180).contains(longitude), abs(altitude) <= 20_000,
              (0...10_000).contains(horizontalAccuracy),
              (0...10_000).contains(verticalAccuracy), (0...120).contains(speed),
              (0...120).contains(speedAccuracy), (0..<360).contains(course),
              (0...180).contains(courseAccuracy),
              abs(now.timeIntervalSince1970 - timestamp) <= 30 else {
            throw RichLocationRelayError.invalidSample
        }
        return CLLocation(coordinate: .init(latitude: latitude, longitude: longitude),
                          altitude: altitude, horizontalAccuracy: horizontalAccuracy,
                          verticalAccuracy: verticalAccuracy, course: course,
                          courseAccuracy: courseAccuracy, speed: speed,
                          speedAccuracy: speedAccuracy,
                          timestamp: Date(timeIntervalSince1970: timestamp))
    }
}

struct RichLocationRelayRequest: Codable {
    let version: Int
    let id: UUID
    let token: String
    let sample: RichLocationSample
}

struct RichLocationRelayReply: Codable {
    let version: Int
    let id: UUID
    let accepted: Bool
    let reason: String
}

enum RichLocationRelayError: LocalizedError {
    case invalidSample, invalidToken, unavailable, invalidReply, rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidSample: return "The location sample has invalid or expired fields."
        case .invalidToken: return "The relay requires its session credential."
        case .unavailable: return "The location relay is unavailable. No restore command was sent."
        case .invalidReply: return "The location relay returned an invalid response."
        case .rejected(let reason): return "The location relay rejected the sample: \(reason)"
        }
    }
}

func validRelayToken(_ token: String) -> Bool {
    token.utf8.count == 64 && token.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

/// Loopback only. The bearer token belongs to one explicitly started runner
/// session; no Apple password or pairing record is part of this protocol.
final class RichLocationRelayClient {
    static let defaultPort: UInt16 = 32777
    private let token: String
    private let port: NWEndpoint.Port

    init(token: String, port: UInt16 = defaultPort) throws {
        guard validRelayToken(token), let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw RichLocationRelayError.invalidToken
        }
        self.token = token
        self.port = endpoint
    }

    func send(_ sample: RichLocationSample) async throws {
        _ = try sample.validatedLocation()
        let request = RichLocationRelayRequest(version: 1, id: UUID(), token: token, sample: sample)
        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        let reply = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RichLocationRelayReply, Error>) in
            RelayExchange(port: port, request: request.id, data: data, continuation: continuation).start()
        }
        guard reply.accepted else { throw RichLocationRelayError.rejected(reply.reason) }
    }
}

private final class RelayExchange {
    private let queue = DispatchQueue(label: "app.waypoint.rich-location-reply")
    private let connection: NWConnection
    private let request: UUID
    private let data: Data
    private var continuation: CheckedContinuation<RichLocationRelayReply, Error>?
    private var received = Data()

    init(port: NWEndpoint.Port, request: UUID, data: Data,
         continuation: CheckedContinuation<RichLocationRelayReply, Error>) {
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.request = request
        self.data = data
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil { finish(.failure(RichLocationRelayError.unavailable)) }
                    else { receive() }
                })
            case .failed, .cancelled:
                finish(.failure(RichLocationRelayError.unavailable))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [self] in
            finish(.failure(RichLocationRelayError.unavailable))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, ended, error in
            guard continuation != nil else { return }
            if let data { received.append(data) }
            guard received.count <= 8192 else {
                finish(.failure(RichLocationRelayError.invalidReply)); return
            }
            if let newline = received.firstIndex(of: 0x0a) {
                guard newline == received.index(before: received.endIndex),
                      let reply = try? JSONDecoder().decode(RichLocationRelayReply.self, from: received[..<newline]),
                      reply.version == 1, reply.id == request else {
                    finish(.failure(RichLocationRelayError.invalidReply)); return
                }
                finish(.success(reply))
            } else if error != nil || ended {
                finish(.failure(RichLocationRelayError.unavailable))
            } else { receive() }
        }
    }

    private func finish(_ result: Result<RichLocationRelayReply, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(with: result)
    }
}
