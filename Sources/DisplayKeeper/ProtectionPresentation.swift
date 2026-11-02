import Foundation
import DisplayCore

enum StatusTone { case good, neutral, paused, warning, working }

struct ProtectionPresentation {
    let title: String
    let detail: String
    let symbol: String
    let tone: StatusTone
}

struct ActionFeedback {
    let title: String
    let detail: String
    let tone: StatusTone
    let date = Date()
}

@MainActor
extension DisplayController {
    var externalDisplays: [DisplaySnapshot] { displays.filter { !$0.builtIn } }

    var disconnectedPolicies: [DisplayPolicy] {
        configuration.policies.values.filter { policy in
            policy.enabled && !displays.contains { $0.uuid == policy.displayUUID }
        }.sorted { $0.displayName < $1.displayName }
    }

    func health(for display: DisplaySnapshot) -> ProtectionHealth {
        .evaluate(displayUUID: display.uuid, current: display.currentConnection,
                  policy: configuration.policies[display.uuid], paused: configuration.paused,
                  readFailed: snapshotError != nil || display.error != nil,
                  decision: decisions[display.uuid])
    }

    func presentation(for display: DisplaySnapshot) -> ProtectionPresentation {
        if let pending, pending.displayUUID == display.uuid {
            return .init(title: pending.phase == .reverting ? "Restoring previous settings" : "Waiting for confirmation",
                         detail: "Open controls to review this change.", symbol: "clock", tone: .working)
        }
        if let issue = restoreIssues[display.uuid], !configuration.paused,
           configuration.policies[display.uuid]?.enabled == true {
            return .init(title: "Could not restore format", detail: issue,
                         symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        switch health(for: display) {
        case .off:
            return .init(title: "Protection off", detail: "Turn on to remember the current format.", symbol: "shield", tone: .neutral)
        case .paused:
            return .init(title: "Protection paused", detail: "Your saved format is kept. Automatic corrections are paused.", symbol: "pause.circle.fill", tone: .paused)
        case .unknown:
            return .init(title: "Could not verify format", detail: snapshotError ?? display.error ?? "The monitor has not reported its current format.", symbol: "questionmark.circle", tone: .warning)
        case .matching:
            return .init(title: "Matches saved format", detail: "Automatic color protection is active.", symbol: "checkmark.circle.fill", tone: .good)
        case .mismatched:
            return .init(title: "Format differs from saved", detail: "Check now to restore your saved format.", symbol: "exclamationmark.circle.fill", tone: .warning)
        case .restoring:
            return .init(title: "Restoring saved format…", detail: "Waiting for the monitor to confirm the change.", symbol: "arrow.triangle.2.circlepath", tone: .working)
        case .unavailable:
            return .init(title: "Saved format unavailable", detail: "This connection does not offer the saved format.", symbol: "exclamationmark.triangle.fill", tone: .warning)
        case .suspended:
            return .init(title: "Protection needs a retry", detail: "Repeated changes stopped automatic correction. Review the picture, then retry.", symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
    }

    var protectionOverview: ProtectionPresentation {
        if let pending {
            return .init(title: pending.phase == .reverting ? "Restoring previous settings" : "Confirm your display change",
                         detail: "\(pending.displayName) needs your attention.", symbol: "clock.fill", tone: .working)
        }
        if configuration.paused {
            return .init(title: "Protection paused", detail: "Saved formats are kept. Automatic corrections are stopped.",
                         symbol: "pause.circle.fill", tone: .paused)
        }
        if let issue = snapshotError ?? eventError {
            return .init(title: "Protection needs attention", detail: issue, symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        let managed = externalDisplays.filter { display in
            guard let policy = configuration.policies[display.uuid] else { return false }
            return policy.enabled && policy.displayUUID == display.uuid
        }
        if managed.contains(where: { presentation(for: $0).tone == .warning }) {
            return .init(title: "Check your display formats", detail: "A monitor could not be verified. Review its status below.",
                         symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        if managed.contains(where: { health(for: $0) == .restoring }) {
            return .init(title: "Restoring saved formats…", detail: "Waiting for the monitors to confirm their settings.",
                         symbol: "arrow.triangle.2.circlepath", tone: .working)
        }
        if !managed.isEmpty {
            return .init(title: "\(managed.count) \(managed.count == 1 ? "display" : "displays") protected",
                         detail: "\(managed.count == 1 ? "Its current format matches" : "Current formats match") your saved settings.",
                         symbol: "checkmark.shield.fill", tone: .good)
        }
        if !disconnectedPolicies.isEmpty {
            return .init(title: "Waiting for your monitors", detail: "Saved protection will resume when they reconnect.",
                         symbol: "display", tone: .neutral)
        }
        return .init(title: "No displays protected", detail: "Enable protection after the picture looks right.", symbol: "shield", tone: .neutral)
    }
}
