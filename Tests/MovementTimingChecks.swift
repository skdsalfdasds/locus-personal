import Foundation

@main
struct MovementTimingChecks {
    static func main() {
        func close(_ actual: Double, _ expected: Double, _ description: String) {
            precondition(abs(actual - expected) < 0.00001, "\(description): got \(actual), expected \(expected)")
        }
        close(MovementTiming.duration(distanceMeters: 1609.344, mph: 60), 60, "One mile at 60 mph")
        close(MovementTiming.duration(distanceMeters: 1609.344, mph: 30), 120, "One mile at 30 mph")
        close(MovementTiming.stepDuration(distanceMeters: 10, steps: 3, mph: 60) * 3,
              10 / 26.8224, "Subdivision must not lengthen a road segment")
        close(MovementTiming.duration(distanceMeters: 0, mph: 30), 0, "Arrival")
        close(MovementTiming.duration(distanceMeters: 229492.4544, mph: 60), 8556, "142.6 mile route ETA")
        precondition(MovementTiming.etaLabel(seconds: 0) == "Arrived")
        precondition(MovementTiming.etaLabel(seconds: -1) == "Arrived")
        precondition(MovementTiming.etaLabel(seconds: 0.1) == "1 sec")
        precondition(MovementTiming.etaLabel(seconds: 59) == "59 sec")
        precondition(MovementTiming.etaLabel(seconds: 60) == "1 min 00 sec")
        precondition(MovementTiming.etaLabel(seconds: 61) == "1 min 01 sec")
        precondition(MovementTiming.etaLabel(seconds: 3599) == "59 min 59 sec")
        precondition(MovementTiming.etaLabel(seconds: 3600) == "1 hr 00 min 00 sec")
        precondition(MovementTiming.etaLabel(seconds: 3661) == "1 hr 01 min 01 sec")
        precondition(MovementTiming.etaLabel(seconds: .infinity) == "—")
        precondition(MovementTiming.etaLabel(seconds: .nan) == "—")
        print("Movement timing checks passed")
    }
}
