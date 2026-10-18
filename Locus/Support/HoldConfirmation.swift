import Foundation

/// Monotonic time is independent of animation frames and wall-clock changes.
struct HoldConfirmation {
    struct Permit {
        fileprivate let issuedAt: TimeInterval

        func isValid(at time: TimeInterval) -> Bool {
            time >= issuedAt && time - issuedAt < 5
        }
    }

    let duration: TimeInterval
    private(set) var startedAt: TimeInterval?
    private(set) var completed = false

    init(duration: TimeInterval = 3) { self.duration = max(1, duration) }

    mutating func begin(at time: TimeInterval) {
        guard !completed else { return }
        startedAt = time
    }

    mutating func cancel() { startedAt = nil }

    func progress(at time: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        return min(1, max(0, (time - startedAt) / duration))
    }

    mutating func confirm(at time: TimeInterval) -> Permit? {
        guard !completed, startedAt != nil, progress(at: time) >= 1 else { return nil }
        completed = true
        startedAt = nil
        return Permit(issuedAt: time)
    }
}
