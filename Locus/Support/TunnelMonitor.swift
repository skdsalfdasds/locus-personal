import Combine
import Foundation
import Network

/// Checks the endpoint used by the location engine. Interface addresses cannot
/// reliably identify a VPN owned by another app, and reachability is not pairing.
@MainActor
final class TunnelMonitor: ObservableObject {
    enum Status: Equatable {
        case checking, reachable, unavailable

        var title: String {
            switch self {
            case .checking: return "Checking developer tunnel…"
            case .reachable: return "Developer tunnel reachable"
            case .unavailable: return "Tunnel not responding"
            }
        }
    }

    @Published private(set) var status: Status = .checking
    private var connection: NWConnection?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?
    private let port: NWEndpoint.Port

    init(port: UInt16 = 49152) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func check() {
        guard connection == nil else { return }
        let id = UUID()
        requestID = id
        let probe = NWConnection(
            host: NWEndpoint.Host(TunnelConfig.targetIP),
            port: port,
            using: .tcp
        )
        connection = probe
        probe.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.finish(.reachable, request: id)
                case .failed: self?.finish(.unavailable, request: id)
                default: break
                }
            }
        }
        probe.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            self?.finish(.unavailable, request: id)
        }
    }

    func stop() {
        requestID = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish(_ result: Status, request: UUID) {
        guard requestID == request else { return }
        status = result
        stop()
    }
}
