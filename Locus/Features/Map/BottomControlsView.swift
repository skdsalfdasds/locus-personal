import SwiftUI

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool
    @State private var showMovementOptions = false
    @State private var showRestoreWarning = false
    @State private var showRestoreHold = false

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { session.updateJoystick(vector: $0) }
                    .frame(width: 132, height: 132)
            }
            HStack {
                Button { showMovementOptions = true } label: {
                    Label("\(Int(session.speedMPH)) mph", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Movement options, \(Int(session.speedMPH)) miles per hour")
                Spacer()
                Menu {
                    Button("Movement options", systemImage: "slider.horizontal.3") { showMovementOptions = true }
                    Button("Saved places", systemImage: "star") { showPlaces = true }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                    if session.routeRunning || session.joystickActive {
                        Button("Move to selected destination", systemImage: "play.fill", action: move)
                            .disabled(session.pin == nil || session.previewIsRouting || session.isBusy)
                        Button("Teleport to selected destination", systemImage: "location.fill", action: teleport)
                            .disabled(session.pin == nil || session.isBusy)
                    }
                    if session.hasLocationIntent {
                        Divider()
                        Button("Stop and hold current position", systemImage: "stop.fill") {
                            session.stop(pairing: pairing)
                        }
                        Button("Restore real location…", systemImage: "location.slash", role: .destructive) {
                            showRestoreWarning = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel("More options")
            }

            if session.routeRunning {
                RouteEstimateView(distanceMeters: session.routeRemainingMeters)
            } else if let distance = session.previewDistanceMeters {
                RouteEstimateView(distanceMeters: distance)
            } else if session.previewIsRouting {
                HStack { ProgressView(); Text("Finding route…").font(.caption); Spacer() }
            }

            HStack(spacing: 10) {
                if session.routeRunning {
                    Button { session.toggleRoutePause() } label: {
                        Label(session.routePaused ? "Resume" : "Pause", systemImage: session.routePaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    stopButton
                } else if session.joystickActive {
                    stopButton
                } else {
                    Button(action: move) {
                        Label("Move", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(session.pin == nil || session.previewIsRouting || session.isBusy)
                    Button(action: teleport) {
                        Label("Teleport", systemImage: "location.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(session.pin == nil || session.isBusy)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(LocusActionButtonStyle())
        }
        .padding(14)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .sheet(isPresented: $showMovementOptions) { MovementOptionsSheet() }
        .confirmationDialog("Restore your real location?", isPresented: $showRestoreWarning, titleVisibility: .visible) {
            Button("Continue to hold confirmation", role: .destructive) { showRestoreHold = true }
            Button("Keep simulated location", role: .cancel) {}
        } message: {
            Text("This removes the location override. To stop moving and stay where you are, use Stop instead. The next screen requires a three-second hold.")
        }
        .sheet(isPresented: $showRestoreHold) {
            RestoreLocationSheet { permit in
                session.restoreRealLocation(pairing: pairing, confirmation: permit)
            }
        }
    }

    private var stopButton: some View {
        Button { session.stop(pairing: pairing) } label: {
            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .accessibilityHint("Stop movement and hold the current simulated location")
    }

    private func move() {
        NotificationCenter.default.post(name: .locusMoveSelected, object: nil)
    }

    private func teleport() {
        guard let pin = session.pin else { return }
        session.teleport(to: pin, pairing: pairing)
    }
}

private struct MovementOptionsSheet: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Movement") {
                    Picker("Travel mode", selection: $session.travelMode) {
                        ForEach(TravelMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode)
                        }
                    }
                    SpeedControlView()
                    Toggle("Vary speed slightly", isOn: $session.variesSpeed)
                }
                Section("Joystick") {
                    Toggle("Show joystick", isOn: Binding(
                        get: { session.joystickActive },
                        set: { enabled in
                            if enabled { session.startJoystick(pairing: pairing) }
                            else { session.stop(pairing: pairing) }
                        }
                    ))
                    Text("Stop holds the current position. Routes, drawing, and GPX are available in Map tools.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let position = session.simulated {
                    Section("Current position") {
                        Text(String(format: "%.6f, %.6f", position.latitude, position.longitude))
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if case .dropped(let reason) = session.status {
                    Section("Connection") {
                        Text(reason).font(.footnote)
                        Text(session.requiresRestoreRetry
                             ? "Restoration failed. Retry from More options; your previous hold will not restart automatically."
                             : "Your route and location are saved. Locus retries without sending a restore command.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Movement options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
