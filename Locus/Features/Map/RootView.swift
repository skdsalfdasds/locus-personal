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
        case .dropped:
            return .status(session.requiresRestoreRetry ? "Restore failed · Retry in More" : "Connection interrupted · Retrying")
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
        case .notSpoofing: return "Ready"
        case .connectVPN: return "Open LocalDevVPN"
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
