import Foundation
import Network

@main
struct TunnelMonitorChecks {
    @MainActor
    static func main() async throws {
        let previousIP = TunnelConfig.targetIP
        TunnelConfig.setTargetIP("127.0.0.1")
        defer { TunnelConfig.setTargetIP(previousIP) }

        let listener = try NWListener(using: .tcp, on: .any)
        var listenerReady = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady = true }
        }
        var accepted: [NWConnection] = []
        listener.newConnectionHandler = { connection in
            accepted.append(connection)
            connection.start(queue: .main)
        }
        listener.start(queue: .main)
        for _ in 0..<100 {
            if listenerReady { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard listenerReady, let port = listener.port else {
            fatalError("Test listener did not start")
        }
        let monitor = TunnelMonitor(port: port.rawValue)
        monitor.check()
        await waitForResult(monitor)
        precondition(monitor.status == .reachable, "Listening endpoint must be reachable")
        print("PASS: reachable endpoint detected without matching interface subnet")

        listener.cancel()
        accepted.forEach { $0.cancel() }
        try await Task.sleep(nanoseconds: 200_000_000)
        monitor.check()
        await waitForResult(monitor, expected: .unavailable)
        precondition(monitor.status == .unavailable, "Closed endpoint must be unavailable")
        print("PASS: closed endpoint detected")

        let cancelled = TunnelMonitor(port: port.rawValue)
        cancelled.check()
        cancelled.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(cancelled.status == .checking, "Cancelled callbacks must not overwrite status")
        print("PASS: cancelled probe cannot publish a stale result")
    }

    @MainActor
    private static func waitForResult(_ monitor: TunnelMonitor, expected: TunnelMonitor.Status = .reachable) async {
        for _ in 0..<150 {
            if monitor.status == expected { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
