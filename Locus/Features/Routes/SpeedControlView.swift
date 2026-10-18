import SwiftUI

struct SpeedControlView: View {
    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(session.travelMode == .automatic ? "Average speed" : "Speed", systemImage: "speedometer")
                Spacer()
                Text(session.speedLabel)
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            if session.travelMode == .automatic {
                Text(session.currentAutomaticEstimate == nil
                     ? (session.routeRunning ? "Fetching a traffic-aware ETA. Your current speed continues while waiting." : "Select an Apple Maps road route to fetch a traffic-aware ETA. Custom paths and joystick use a manual mode.")
                     : "Average speed uses Apple Maps traffic ETA and route distance, with a base speed between 0.1 and 85 mph. Refreshes about every five minutes; cached speed continues if offline. This does not model individual lights or road speed limits.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Slider(value: $session.speedMPH, in: 1...85, step: 1)
                .tint(LocusTheme.accent)
                .accessibilityLabel("Movement speed in miles per hour")
                .accessibilityValue("\(Int(session.speedMPH)) miles per hour")
            }
        }
    }
}

struct RouteEstimateView: View {
    let distanceMeters: Double
    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        let seconds = MovementTiming.duration(distanceMeters: distanceMeters, mph: session.effectiveSpeedMPH)
        HStack {
            Label(String(format: "%.1f mi", distanceMeters / MovementTiming.metersPerMile), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            Spacer()
            Label(session.travelMode == .automatic && session.currentAutomaticEstimate == nil
                  ? "ETA unavailable" : MovementTiming.etaLabel(seconds: seconds), systemImage: "clock")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
