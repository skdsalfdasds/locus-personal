/// Uses a monotonic clock. Successful route/joystick fixes already maintain the
/// simulation; repeating their coordinates between them adds stationary samples.
struct LocationKeepAlive {
    private var lastSuccess: Double?

    mutating func confirmed(at uptime: Double) {
        guard uptime.isFinite else { return }
        lastSuccess = uptime
    }

    func needsResend(at uptime: Double) -> Bool {
        guard uptime.isFinite else { return false }
        guard let lastSuccess else { return true }
        return uptime - lastSuccess >= 5
    }
}
