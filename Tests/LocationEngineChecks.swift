import Foundation
import idevice

@main
struct LocationEngineChecks {
    static func main() throws {
        stub_reset()
        try LocationEngine.set(latitude: 0, longitude: 0, pairingPath: "test", deviceIP: "127.0.0.1").get()
        stub_fail_next_sets(2)
        if case .success = LocationEngine.set(latitude: 0, longitude: 0.001, pairingPath: "test", deviceIP: "127.0.0.1") {
            fatalError("Injected send failure was not observed")
        }
        precondition(stub_clear_calls() == 0)
        stub_fail_next_connections(1)
        if case .success = LocationEngine.set(latitude: 0, longitude: 0.001, pairingPath: "test", deviceIP: "127.0.0.1") {
            fatalError("Injected tunnel outage was not observed")
        }
        precondition(stub_clear_calls() == 0)
        try LocationEngine.set(latitude: 0, longitude: 0, pairingPath: "test", deviceIP: "127.0.0.1").get()
        precondition(stub_clear_calls() == 0)
        print("PASS: failed sends, tunnel loss, and reconnection never send a clear command")

        let previousSets = stub_set_calls()
        try LocationEngine.clear(pairingPath: "test", deviceIP: "127.0.0.1").get()
        precondition(stub_clear_calls() == 1)
        try LocationEngine.clear(pairingPath: "test", deviceIP: "127.0.0.1").get()
        precondition(stub_clear_calls() == 2 && stub_set_calls() == previousSets)
        print("PASS: explicit restoration clears, including after reconnecting, without teleporting")
    }
}
