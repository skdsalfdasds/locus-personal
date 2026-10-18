import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @State private var showSettings = false
    @State private var showPlaces = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView()

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear { session.refreshAfterForeground(pairing: pairing) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.refreshAfterForeground(pairing: pairing)
            } else {
                session.prepareForBackground(pairing: pairing)
            }
        }
        .onChange(of: pairing.hasPairingFile) { _, hasFile in
            if hasFile { session.refreshAfterForeground(pairing: pairing) }
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var tunnel = TunnelMonitor()

    private enum Display {
        case notSpoofing
        case connectVPN
        case checking
        case status(String)
    }

    private var display: Display {
        switch session.status {
        case .idle:
            switch tunnel.status {
            case .reachable: return .notSpoofing
            case .unavailable: return .connectVPN
            case .checking: return .checking
            }
        case .connecting:
            return .status("Connecting…")
        case .active:
            if session.routeRunning {
                return .status(session.routePaused ? "Movement paused" : "Moving")
            }
            return .status(session.holdingDestination ? "Holding location" : "Spoofing")
        case .reconnecting:
            return .status("Reconnecting…")
        case .dropped(let reason):
            return .status(reason.isEmpty ? "Disconnected" : "Disconnected — \(reason)")
        }
    }

    private var color: Color {
        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
        case .connectVPN:
            return LocusTheme.statusWarn
        case .checking:
            return Color.primary.opacity(0.55)
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return "Tunnel ready · Choose a destination"
        case .connectVPN: return "Tunnel not responding · Open VPN"
        case .checking: return "Checking developer tunnel…"
        case .status(let text): return text
        }
    }

    var body: some View {
        Group {
            if case .connectVPN = display {
                Button(action: LocalDevVPN.openOrInstall) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            defer { tunnel.stop() }
            while !Task.isCancelled {
                if session.status == .idle {
                    tunnel.check()
                } else {
                    // The engine's authenticated session is authoritative while active.
                    tunnel.stop()
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
        .onChange(of: session.status) { _, status in
            if status != .idle { tunnel.stop() }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if case .connectVPN = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { mode in
                    let selected = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(width: 44, height: 40)
                            .background(
                                Capsule().fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            SpeedControlView()

            if session.routeRunning {
                RouteEstimateView(distanceMeters: session.routeRemainingMeters)
            } else if let distance = session.previewDistanceMeters {
                RouteEstimateView(distanceMeters: distance)
            } else if session.previewIsRouting {
                HStack {
                    ProgressView()
                    Text("Finding road route…").font(.caption)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .locusMoveSelected, object: nil)
                } label: {
                    Label("Move", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.pin == nil || session.previewIsRouting || session.isBusy)

                Button {
                    guard let pin = session.pin else { return }
                    session.teleport(to: pin, pairing: pairing)
                } label: {
                    Label("Teleport", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.pin == nil || session.isBusy)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(LocusActionButtonStyle())

            if session.pin == nil {
                Text("Choose an address or map point to enable Move and Teleport.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if session.routeRunning {
                Button(session.routePaused ? "Resume movement" : "Pause movement") {
                    session.toggleRoutePause()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                trayIcon("gearshape.fill") { showSettings = true }
                trayIcon("star.fill") { showPlaces = true }

                Button {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick(pairing: pairing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        Text(session.joystickActive ? "On" : "Joy")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.joystickActive ? .black : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if session.hasLocationIntent {
                    Button {
                        session.stop(pairing: pairing)
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 72)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(LocusTheme.danger))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

    private func trayIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
    }
}
