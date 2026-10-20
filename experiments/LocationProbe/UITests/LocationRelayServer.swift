import Foundation
import Network

/// Runs only inside an explicitly launched XCTest session. No clear/restore
/// command exists, and disconnecting a client never changes location.
final class LocationRelayServer {
    private let token: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.waypoint.location-relay-server")
    private let lock = NSLock()
    private var ready = false
    private var running = false
    private var connections: [UUID: NWConnection] = [:]
    private var replies: [UUID: RichLocationRelayReply] = [:]
    private var order: [UUID] = []
    private var pending: Set<UUID> = []
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    init(token: String, port: UInt16 = RichLocationRelayClient.defaultPort) throws {
        guard validRelayToken(token), let port = NWEndpoint.Port(rawValue: port) else {
            throw RichLocationRelayError.invalidToken
        }
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
    }

    func start() {
        lock.lock(); running = true; lock.unlock()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            if case .ready = state { self.ready = true } else { self.ready = false }
            self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, buffer: Data())
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.close(id) }
        }
        listener.start(queue: queue)
    }

    func stop() {
        lock.lock(); running = false; ready = false; lock.unlock()
        listener.cancel()
        queue.sync {
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            pending.removeAll()
        }
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192 else { self.close(id); return }
            if let newline = buffer.firstIndex(of: 0x0a) {
                guard newline == buffer.index(before: buffer.endIndex),
                      let request = try? JSONDecoder().decode(RichLocationRelayRequest.self, from: buffer[..<newline]) else {
                    self.close(id); return
                }
                self.handle(request, connection: connection, id: id)
            } else if error != nil || ended { self.close(id) }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }

    private func handle(_ request: RichLocationRelayRequest, connection: NWConnection, id: UUID) {
        // Compare a fixed-length credential before replay lookup or any setter.
        let candidate = Array(request.token.utf8), expected = Array(token.utf8)
        let matches = candidate.count == expected.count && zip(candidate, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        guard request.version == 1, matches else {
            send(.init(version: 1, id: request.id, accepted: false, reason: "Session authorization failed"), connection: connection, id: id)
            return
        }
        if let previous = replies[request.id] { send(previous, connection: connection, id: id); return }
        guard !pending.contains(request.id) else {
            send(.init(version: 1, id: request.id, accepted: false, reason: "Sample already pending"), connection: connection, id: id)
            return
        }
        guard let location = try? request.sample.validatedLocation() else {
            send(.init(version: 1, id: request.id, accepted: false, reason: "Invalid or expired sample"), connection: connection, id: id)
            return
        }
        pending.insert(request.id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = self.running; self.lock.unlock()
            guard active, self.queue.sync(execute: { self.connections[id] != nil }),
                  (try? request.sample.validatedLocation()) != nil else {
                self.queue.async { self.pending.remove(request.id); self.close(id) }
                return
            }
            let result = WPSetDaemonLocation(location)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.pending.remove(request.id)
                let reply = RichLocationRelayReply(version: 1, id: request.id,
                    accepted: result["accepted"] as? Bool == true,
                    reason: result["accepted"] as? Bool == true ? "" : "XCTest daemon rejected the sample")
                self.replies[request.id] = reply
                self.order.append(request.id)
                if self.order.count > 256 { self.replies.removeValue(forKey: self.order.removeFirst()) }
                self.send(reply, connection: connection, id: id)
            }
        }
    }

    private func send(_ reply: RichLocationRelayReply, connection: NWConnection, id: UUID) {
        guard var data = try? JSONEncoder().encode(reply) else { close(id); return }
        data.append(0x0a)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
}
