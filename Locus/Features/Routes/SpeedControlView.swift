import SwiftUI

struct SpeedControlView: View {
    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Speed", systemImage: "speedometer")
                Spacer()
                Text("\(session.speedMPH, specifier: "%.0f") mph")
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            Slider(value: $session.speedMPH, in: 1...85, step: 1)
                .tint(LocusTheme.accent)
                .accessibilityLabel("Movement speed in miles per hour")
                .accessibilityValue("\(Int(session.speedMPH)) miles per hour")
        }
    }
}

struct RouteEstimateView: View {
    let distanceMeters: Double
    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        let seconds = MovementTiming.duration(distanceMeters: distanceMeters, mph: session.speedMPH)
        HStack {
            Label(String(format: "%.1f mi", distanceMeters / MovementTiming.metersPerMile), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            Spacer()
            Label(MovementTiming.etaLabel(seconds: seconds), systemImage: "clock")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
