import Foundation
import Testing
@testable import DisplayCore

struct ProtectionPlannerTests {
    private func mode(id: String = "original") -> ConnectionMode {
        ConnectionMode(
            id: id,
            width: 3840,
            height: 2160,
            refreshRate: 60,
            bitDepth: 10,
            pixelEncoding: 0,
            dynamicRange: 0,
            eotf: 0,
            colorimetry: 1,
            rawColorMode: "RGBFullRange",
            rawHDRMode: "SDR",
            rawColorGamut: "gamut_SRGB"
        )
    }

    private func policy(uuid: String = "display-a", enabled: Bool = true) -> DisplayPolicy {
        DisplayPolicy(
            displayUUID: uuid,
            displayName: "External display",
            target: ModeTarget(mode: mode()),
            enabled: enabled
        )
    }

    private func wrongMode() -> ConnectionMode {
        var result = mode(id: "washed-out")
        result.dynamicRange = 1
        return result
    }

    @Test
    func testCorrectModeWithChangedIdentifierRequiresNoWrite() {
        var planner = ProtectionPlanner()
        var current = mode(id: "new-driver-enumeration-id")
        current.isCurrent = true
        current.isPreferred = true

        #expect(planner.plan(displayUUID: "display-a", current: current, available: [], policy: policy(), now: 0) == .alreadyCorrect)
    }

    @Test
    func testCorrectionUsesCurrentEnumerationIdentifierAndRequiresReadback() {
        var planner = ProtectionPlanner()
        let candidate = mode(id: "new-id-after-reconnect")

        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [candidate], policy: policy(), now: 0) == .apply(candidate))
        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [candidate], policy: policy(), now: 1) == .coolingDown)
        #expect(planner.plan(displayUUID: "display-a", current: candidate, available: [candidate], policy: policy(), now: 1) == .alreadyCorrect)
    }

    @Test
    func testMissingDisabledAndMismatchedPoliciesAreUnmanaged() {
        for policy in [nil, policy(enabled: false), policy(uuid: "display-b")] as [DisplayPolicy?] {
            var planner = ProtectionPlanner()
            #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy, now: 0) == .unmanaged)
        }
    }

    @Test
    func testUnavailableTargetNeverFallsBackToAnotherColorModeOrConsumesAttempt() {
        var planner = ProtectionPlanner()
        for now in [0.0, 2, 4, 6] {
            #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [wrongMode()], policy: policy(), now: now) == .unavailable)
        }

        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: 6) == .apply(mode()))
    }

    @Test
    func testUnknownCurrentCanBeCorrectedOnlyToAnAvailableTarget() {
        var planner = ProtectionPlanner()
        #expect(planner.plan(displayUUID: "display-a", current: nil, available: [], policy: policy(), now: 0) == .unavailable)
        #expect(planner.plan(displayUUID: "display-a", current: nil, available: [mode()], policy: policy(), now: 0) == .apply(mode()))
    }

    @Test
    func testAttemptsAreSpacedAndSuspendUntilExplicitReset() {
        var planner = ProtectionPlanner()
        func plan(_ now: TimeInterval) -> ProtectionDecision {
            planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: now)
        }

        #expect(plan(0) == .apply(mode()))
        #expect(plan(1.999) == .coolingDown)
        #expect(plan(2) == .apply(mode()))
        #expect(plan(3.999) == .coolingDown)
        #expect(plan(4) == .apply(mode()))
        #expect(plan(6) == .suspended)
        #expect(plan(100) == .suspended)

        planner.reset(displayUUID: "display-a")
        #expect(plan(100) == .apply(mode()))
    }

    @Test
    func testCorrectReadbackAfterThirdAttemptDoesNotSuspend() {
        var planner = ProtectionPlanner()
        for now in [0.0, 2, 4] {
            #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: now) == .apply(mode()))
        }
        #expect(planner.plan(displayUUID: "display-a", current: mode(), available: [mode()], policy: policy(), now: 5) == .alreadyCorrect)
        // A successful readback does not erase the anti-oscillation budget.
        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: 6) == .suspended)
    }

    @Test
    func testRollingWindowAllowsOldAttemptsToExpireBeforeSuspension() {
        var planner = ProtectionPlanner()
        for now in [0.0, 10, 20, 30, 40] {
            #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: now) == .apply(mode()))
        }
    }

    @Test
    func testBudgetsAndResetAreIndependentForEachMonitor() {
        var planner = ProtectionPlanner()
        for uuid in ["display-a", "display-b"] {
            for now in [0.0, 2, 4] {
                #expect(planner.plan(displayUUID: uuid, current: wrongMode(), available: [mode()], policy: policy(uuid: uuid), now: now) == .apply(mode()))
            }
            #expect(planner.plan(displayUUID: uuid, current: wrongMode(), available: [mode()], policy: policy(uuid: uuid), now: 6) == .suspended)
        }

        planner.reset(displayUUID: "display-a")
        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: 6) == .apply(mode()))
        #expect(planner.plan(displayUUID: "display-b", current: wrongMode(), available: [mode()], policy: policy(uuid: "display-b"), now: 100) == .suspended)
    }

    @Test
    func testNonfiniteOrBackwardsTimeCannotDefeatSpacing() {
        var planner = ProtectionPlanner()
        for now in [TimeInterval.nan, .infinity, -.infinity] {
            #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: now) == .coolingDown)
        }
        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: 10) == .apply(mode()))
        #expect(planner.plan(displayUUID: "display-a", current: wrongMode(), available: [mode()], policy: policy(), now: 9) == .coolingDown)
    }

    @Test
    func testTargetAcceptsOnlyRefreshDifferencesWithinPointOneHz() {
        let target = ModeTarget(mode: mode())
        for refreshRate in [59.9, 59.94, 60, 60.1] {
            var candidate = mode()
            candidate.refreshRate = refreshRate
            #expect(target.matches(candidate), Comment(rawValue: "Should accept \(refreshRate) Hz"))
        }
        for refreshRate in [59.8999, 60.1001, 120, .nan, .infinity] {
            var candidate = mode()
            candidate.refreshRate = refreshRate
            #expect(!(target.matches(candidate)), Comment(rawValue: "Should reject \(refreshRate) Hz"))
        }
    }

    @Test
    func testTargetPreservesEveryResolutionAndColorProperty() {
        let target = ModeTarget(mode: mode())
        let properties: [WritableKeyPath<ConnectionMode, Int>] = [
            \.width, \.height, \.bitDepth, \.pixelEncoding,
            \.dynamicRange, \.eotf, \.colorimetry,
        ]
        for property in properties {
            var candidate = mode()
            candidate[keyPath: property] += 1
            #expect(!(target.matches(candidate)), Comment(rawValue: "Must preserve \(property)"))
        }
    }

    @Test
    func testTargetDoesNotCollapseUnknownRawFormatsOrVariableRefreshModes() {
        let target = ModeTarget(mode: mode())
        let properties: [WritableKeyPath<ConnectionMode, String>] = [
            \.rawColorMode, \.rawHDRMode, \.rawColorGamut,
        ]
        for property in properties {
            var candidate = mode()
            candidate[keyPath: property] = "unknown-driver-value"
            #expect(!(target.matches(candidate)), Comment(rawValue: "Must preserve \(property)"))
        }
        var candidate = mode()
        candidate.isVRR = true
        #expect(!(target.matches(candidate)))
    }

    @Test
    func testPolicyPersistenceRetainsSemanticsWithoutDriverIdentifier() throws {
        let original = policy()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DisplayPolicy.self, from: encoded)
        #expect(decoded.displayUUID == original.displayUUID)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.enabled == original.enabled)
        #expect(decoded.target == original.target)

        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let target = try #require(json["target"] as? [String: Any])
        #expect(target["id"] == nil)
        #expect(target["isCurrent"] == nil)
        #expect(target["isPreferred"] == nil)
        #expect(decoded.target.matches(mode(id: "different-after-reboot")))
    }

    @Test
    func testObservedLabelsAndUnknownFallbacks() {
        var candidate = mode()
        #expect(candidate.bitDepthLabel == "10-bit")
        #expect(candidate.summary == "3840 × 2160 · 60 Hz · 10-bit · RGB · Full · SDR · gamut_SRGB")
        for (value, label) in [(0, "RGB"), (3, "YCbCr 4:4:4"), (2, "YCbCr 4:2:2"), (6, "YCbCr 4:2:0"), (99, "Encoding 99")] {
            candidate.pixelEncoding = value
            #expect(candidate.pixelEncodingLabel == label)
        }
        for (value, label) in [(0, "Full"), (1, "Limited"), (99, "Range 99")] {
            candidate.dynamicRange = value
            #expect(candidate.dynamicRangeLabel == label)
        }
        for (value, label) in [(0, "SDR"), (2, "HDR"), (99, "EOTF 99")] {
            candidate.eotf = value
            #expect(candidate.eotfLabel == label)
        }
    }
}
