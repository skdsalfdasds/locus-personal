import SwiftUI
import UIKit

struct RestoreLocationSheet: View {
    let onConfirm: (HoldConfirmation.Permit) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var touching = false
    @State private var gate = HoldConfirmation()
    @State private var progress = 0.0
    @State private var holding = false
    @State private var blocked = false
    @State private var completed = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.slash.circle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(LocusTheme.danger)
                .padding(.top, 12)
            Text("Restore real location?")
                .font(.title2.bold())
            Text("This ends movement, removes the simulated location, and clears its saved hold. Apps can then receive your real location.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("To stay where you are, cancel and use Stop instead.")
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)

            GeometryReader { geometry in
                ZStack {
                    Capsule().fill(LocusTheme.danger.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [LocusTheme.danger, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * progress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Image(systemName: completed ? "checkmark.circle.fill" : "hand.point.up.left.fill")
                        Text(completed ? "Restoring…" : holding ? "Keep holding…" : "Hold 3 seconds to restore")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(LocusTheme.danger.opacity(holding ? 0.9 : 0.4), lineWidth: 1))
                .shadow(color: LocusTheme.danger.opacity(holding ? 0.35 : 0), radius: holding ? 16 : 0)
                .scaleEffect(holding && !reduceMotion ? 0.98 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: holding)
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        let bounds = CGRect(origin: .zero, size: geometry.size)
                        guard bounds.contains(value.location) else {
                            blocked = true
                            cancelHold()
                            return
                        }
                        beginHold()
                    }
                    .onEnded { _ in
                        cancelHold()
                        blocked = false
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold for three seconds to restore real location")
                .accessibilityHint("Releasing early cancels. A tap cannot restore location.")
            }
            .frame(height: 58)

            Text("Release or slide off to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Keep simulated location", role: .cancel) { dismiss() }
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 10)
        }
        .padding(24)
        .presentationDetents([.height(460), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: touching) { _, isTouching in
            if !isTouching { cancelHold(); blocked = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { blocked = true; cancelHold() }
        }
        .onDisappear { cancelHold() }
    }

    private func beginHold() {
        guard !blocked, !holding, !completed, scenePhase == .active else { return }
        holding = true
        gate.begin(at: ProcessInfo.processInfo.systemUptime)
        progress = 0
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.linear(duration: gate.duration)) { progress = 1 }
        holdTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(gate.duration * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, holding, !blocked, touching, scenePhase == .active,
                  let permit = gate.confirm(at: ProcessInfo.processInfo.systemUptime) else { return }
            completed = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onConfirm(permit)
            dismiss()
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        guard !completed else { return }
        gate.cancel()
        holding = false
        withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
    }
}
