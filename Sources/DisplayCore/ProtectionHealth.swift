/// Describes observed protection health without changing settings or spending
/// the planner's correction budget. A saved policy alone is not proof of health.
public enum ProtectionHealth: Equatable {
    case off, paused, unknown, matching, mismatched, restoring, unavailable, suspended

    public static func evaluate(displayUUID: String, current: ConnectionMode?, policy: DisplayPolicy?,
                                paused: Bool, readFailed: Bool, decision: ProtectionDecision?) -> Self {
        guard let policy, policy.enabled, policy.displayUUID == displayUUID else { return .off }
        if paused { return .paused }
        if readFailed { return .unknown }
        // A latched suspension still needs a retry even if another app fixed the picture.
        if decision == .suspended { return .suspended }
        guard let current else { return .unknown }
        if policy.target.matches(current) { return .matching }
        switch decision {
        case .apply, .coolingDown: return .restoring
        case .unavailable: return .unavailable
        default: return .mismatched
        }
    }
}
