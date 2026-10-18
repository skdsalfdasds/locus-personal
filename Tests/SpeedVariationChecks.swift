import Foundation

@main
struct SpeedVariationChecks {
    static func main() {
        var last = SpeedVariation.multiplier(elapsed: 0, bendSeverity: 0)
        for tick in 1...12000 {
            let time = Double(tick) / 20
            let straight = SpeedVariation.multiplier(elapsed: time, bendSeverity: 0)
            let bend = SpeedVariation.multiplier(elapsed: time, bendSeverity: 1)
            precondition(straight >= 0.96 && straight <= 1.04)
            precondition(bend >= 0.92 && bend <= straight)
            precondition(abs(straight - last) < 0.001)
            precondition(straight == SpeedVariation.multiplier(elapsed: time, bendSeverity: 0))
            last = straight
        }
        print("PASS: deterministic continuous drift stays small; bends reduce the target")

        var profile = SpeedVariation()
        var elapsed = 0.0
        var prior = MovementTiming.metersPerSecond(mph: 30)
        for tick in 0..<1000 {
            let base = tick < 300 ? 30.0 : tick < 600 ? 60.0 : 20.0
            let seconds = profile.duration(distanceMeters: 2, baseMPH: base, elapsed: elapsed,
                                           bendSeverity: tick > 700 ? 1 : 0, enabled: true)
            let speed = profile.metersPerSecond!
            precondition(seconds.isFinite && seconds > 0 && speed > 0)
            let rate = (speed - prior) / seconds
            precondition(rate <= 0.350001 && rate >= -0.550001)
            elapsed += seconds
            prior = speed
        }
        print("PASS: even large baseline changes respect acceleration and braking limits")

        var manual = SpeedVariation()
        let seconds = manual.duration(distanceMeters: 1609.344, baseMPH: 60, elapsed: 40,
                                      bendSeverity: 1, enabled: false)
        precondition(abs(seconds - 60) < 0.000001)
        var shortStep = SpeedVariation()
        var longStep = SpeedVariation()
        let a = shortStep.duration(distanceMeters: 2, baseMPH: 30, elapsed: 0, bendSeverity: 0, enabled: true)
        let b = longStep.duration(distanceMeters: 12, baseMPH: 30, elapsed: 0, bendSeverity: 0, enabled: true)
        precondition(abs(a * 6 - b) < 0.000001)
        print("PASS: variation off preserves exact manual timing; sampling does not set the variation rate")

        var automatic = SpeedVariation()
        _ = automatic.duration(distanceMeters: 2, baseMPH: 60, elapsed: 0,
                               bendSeverity: 0, enabled: false, smoothTransitions: true)
        let before = automatic.metersPerSecond!
        let brakingTime = automatic.duration(distanceMeters: 2, baseMPH: 10, elapsed: 1,
                                              bendSeverity: 0, enabled: false, smoothTransitions: true)
        precondition(automatic.metersPerSecond! < before)
        precondition(abs((automatic.metersPerSecond! - before) / brakingTime + 0.55) < 0.000001)
        print("PASS: Automatic traffic transitions remain gradual with optional variation switched off")

        var joystick = SpeedVariation()
        var priorJoystick = MovementTiming.metersPerSecond(mph: 30)
        for tick in 0..<400 {
            _ = joystick.joystickSpeed(baseMPH: tick < 200 ? 30 : 60,
                                      elapsed: Double(tick) * 0.25, interval: 0.25, enabled: true)
            let speed = joystick.metersPerSecond!
            precondition(speed - priorJoystick <= 0.35 * 0.25 + 0.000001)
            precondition(priorJoystick - speed <= 0.55 * 0.25 + 0.000001)
            priorJoystick = speed
        }
        print("PASS: joystick uses the same bounded smooth changes")
    }
}
