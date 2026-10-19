import Foundation

@main
struct LocationKeepAliveChecks {
    static func main() {
        var stream = LocationKeepAlive()
        precondition(stream.needsResend(at: 0))
        for tick in 0..<100 {
            let now = Double(tick) * 0.5
            stream.confirmed(at: now)
            precondition(!stream.needsResend(at: now + 0.1))
        }
        print("PASS: continuous confirmed movement never needs duplicate hold fixes")
        precondition(!stream.needsResend(at: 54.49))
        precondition(stream.needsResend(at: 54.5))
        // A failed retry must not reset the last-success clock.
        precondition(stream.needsResend(at: 60))
        stream.confirmed(at: 60)
        precondition(!stream.needsResend(at: 64.9))
        precondition(stream.needsResend(at: 65))
        print("PASS: paused/stopped/stalled movement still receives hold maintenance; failed retries remain eligible")
        precondition(!stream.needsResend(at: .nan))
        stream.confirmed(at: .infinity)
        precondition(stream.needsResend(at: 65))
        print("PASS: invalid timestamps cannot corrupt the monotonic maintenance clock")
    }
}
