import Foundation

@main
struct HoldConfirmationChecks {
    static func main() {
        var gate = HoldConfirmation()
        precondition(gate.confirm(at: 100) == nil)
        gate.begin(at: 100)
        precondition(gate.confirm(at: 102.99) == nil)
        gate.cancel()
        precondition(gate.confirm(at: 104) == nil)
        print("PASS: taps, early release, and cancelled gestures cannot confirm")

        gate.begin(at: 200)
        precondition(gate.progress(at: 199) == 0)
        precondition(gate.confirm(at: 202.99) == nil)
        let permit = gate.confirm(at: 203)!
        precondition(gate.confirm(at: 204) == nil)
        precondition(permit.isValid(at: 203))
        precondition(!permit.isValid(at: 202))
        precondition(!permit.isValid(at: 208))
        print("PASS: uninterrupted three-second hold issues one expiring confirmation")

        var retry = HoldConfirmation()
        retry.begin(at: 10)
        retry.cancel()
        retry.begin(at: 12)
        precondition(retry.confirm(at: 14) == nil)
        precondition(retry.confirm(at: 15) != nil)
        print("PASS: separate partial holds cannot accumulate time")
    }
}
