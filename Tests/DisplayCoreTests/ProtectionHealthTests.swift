import Testing
@testable import DisplayCore

struct ProtectionHealthTests {
    private var good: ConnectionMode {
        ConnectionMode(id: "current", width: 2560, height: 1440, refreshRate: 120, bitDepth: 10,
                       pixelEncoding: 0, dynamicRange: 0, eotf: 0, colorimetry: 0,
                       rawColorMode: "RGBFullRange", rawHDRMode: "SDR", rawColorGamut: "gamut_SRGB")
    }

    private func health(current: ConnectionMode?, paused: Bool = false, readFailed: Bool = false,
                        decision: ProtectionDecision? = .alreadyCorrect, enabled: Bool = true,
                        policyUUID: String = "monitor") -> ProtectionHealth {
        .evaluate(displayUUID: "monitor", current: current,
                  policy: DisplayPolicy(displayUUID: policyUUID, displayName: "Monitor", target: ModeTarget(mode: good), enabled: enabled),
                  paused: paused, readFailed: readFailed, decision: decision)
    }

    @Test func staleSuccessCannotHideAMismatchOrFailedRead() {
        var changed = good
        changed.bitDepth = 8
        #expect(health(current: changed) == .mismatched)
        #expect(health(current: good, readFailed: true) == .unknown)
        #expect(health(current: nil) == .unknown)
    }

    @Test func pausedOrDisabledProtectionIsNeverReportedAsHealthy() {
        #expect(health(current: good, paused: true) == .paused)
        #expect(health(current: good, enabled: false) == .off)
        #expect(health(current: good, policyUUID: "different-monitor") == .off)
    }

    @Test func verifiedReadbackClearsRestoringButNotLatchedSuspension() {
        #expect(health(current: good, decision: .apply(good)) == .matching)
        #expect(health(current: good, decision: .coolingDown) == .matching)
        #expect(health(current: good, decision: .suspended) == .suspended)
    }

    @Test func appliedRequestIsNotProofOfRestoration() {
        var changed = good
        changed.dynamicRange = 1
        #expect(health(current: changed, decision: .apply(good)) == .restoring)
        #expect(health(current: changed, decision: .coolingDown) == .restoring)
        #expect(health(current: changed, decision: .unavailable) == .unavailable)
    }
}
