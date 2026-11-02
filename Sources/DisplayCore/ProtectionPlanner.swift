import Foundation

public enum ProtectionDecision: Equatable {
    case unmanaged
    case alreadyCorrect
    case unavailable
    case apply(ConnectionMode)
    case coolingDown
    case suspended
}

/// Plans bounded, per-display corrections without performing any display I/O.
///
/// An `.apply` decision consumes an attempt; it does not assert that the driver
/// accepted the mode. The caller must read the connection mode again to verify
/// the result. Only explicitly enabled, UUID-matched policies can cause writes.
public struct ProtectionPlanner {
    private struct AttemptState {
        var attempts: [TimeInterval] = []
        var suspended = false
    }

    private var states: [String: AttemptState] = [:]

    public init() {}

    /// Use a monotonic time source for `now`, such as system uptime.
    ///
    /// Three attempts may occur in a rolling 30-second window, at least two
    /// seconds apart. If another correction is needed while that budget is
    /// exhausted, protection latches off until `reset(displayUUID:)` is called.
    public mutating func plan(
        displayUUID: String,
        current: ConnectionMode?,
        available: [ConnectionMode],
        policy: DisplayPolicy?,
        now: TimeInterval
    ) -> ProtectionDecision {
        guard let policy,
              policy.enabled,
              policy.displayUUID == displayUUID else {
            return .unmanaged
        }

        var state = states[displayUUID] ?? AttemptState()
        guard !state.suspended else {
            return .suspended
        }

        if let current, policy.target.matches(current) {
            return .alreadyCorrect
        }

        guard let candidate = available.first(where: policy.target.matches) else {
            return .unavailable
        }

        // Invalid clocks must never defeat the rate limit. A clock that moves
        // backwards is also held by the spacing check below until it catches up.
        guard now.isFinite else {
            return .coolingDown
        }

        state.attempts.removeAll { now - $0 >= 30 }
        if state.attempts.count >= 3 {
            state.suspended = true
            states[displayUUID] = state
            return .suspended
        }

        if let lastAttempt = state.attempts.last, now - lastAttempt < 2 {
            return .coolingDown
        }

        state.attempts.append(now)
        states[displayUUID] = state
        return .apply(candidate)
    }

    /// Resets only this display's attempt budget and any latched suspension.
    public mutating func reset(displayUUID: String) {
        states.removeValue(forKey: displayUUID)
    }
}
