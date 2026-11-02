import Testing
@testable import DisplayCore

struct ModeAdvisorTests {
    private func mode(_ id: String, hz: Double = 120, depth: Int = 10, hdr: Bool = false,
                      rgb: Bool = true, width: Int = 2560, height: Int = 1440,
                      preferred: Bool = false, variable: Bool = false) -> ConnectionMode {
        .init(id: id, width: width, height: height, refreshRate: hz, bitDepth: depth,
              pixelEncoding: rgb ? 0 : 2, dynamicRange: rgb ? 0 : 1, eotf: hdr ? 2 : 0, colorimetry: 0,
              rawColorMode: hdr ? (rgb ? "HDR10_RGBFullRange" : "HDR10_422LimitedRange") : (rgb ? "RGBFullRange" : "YCbCr422LimitedRange"),
              rawHDRMode: hdr ? "HDR10" : "SDR", rawColorGamut: "gamut_SRGB",
              isVRR: variable, isPreferred: preferred)
    }
    private var ex: MonitorCapabilities { .known(vendorID: 2513, productID: 32630)! }
    private var gw: MonitorCapabilities { .known(vendorID: 2513, productID: 30973)! }
    private func choice(_ purpose: RecommendationPurpose, _ modes: [ConnectionMode],
                        capabilities: MonitorCapabilities? = nil, hdr: Bool = true,
                        current: ConnectionMode? = nil) -> ConnectionMode? {
        ModeAdvisor.recommend(modes: modes, current: current, capabilities: capabilities, hdrAvailable: hdr)
            .options.first { $0.purpose == purpose }?.mode
    }

    @Test func exTradeoffPreservesTextDetailInsteadOfMaximizingEveryNumber() {
        let modes = [mode("120-10"), mode("144-8", hz: 144, depth: 8),
                     mode("144-10-subsampled", hz: 144, rgb: false, preferred: true),
                     mode("4k-downsampled", hz: 60, width: 3840, height: 2160),
                     mode("144-adaptive", hz: 144, depth: 8, variable: true)]
        #expect(choice(.everyday, modes, capabilities: ex)?.id == "120-10")
        #expect(choice(.motion, modes, capabilities: ex)?.id == "144-8")
    }

    @Test func gwUsesActualEightBitHundredHzCapabilityAndDoesNotInventHDR() {
        let modes = [mode("60", hz: 59.95, depth: 8), mode("100", hz: 100, depth: 8),
                     mode("limited", hz: 100, depth: 8, rgb: false, preferred: true)]
        #expect(choice(.everyday, modes, capabilities: gw)?.id == "100")
        #expect(choice(.motion, modes, capabilities: gw)?.id == "100")
        #expect(choice(.lowerPower, modes, capabilities: gw)?.id == "60")
        #expect(choice(.hdr, modes, capabilities: gw) == nil)
    }

    @Test func hdrNeedsBothAnRGBTenBitModeAndWorkingControlSupport() {
        let modes = [mode("hdr120", hdr: true), mode("hdr144-subsampled", hz: 144, hdr: true, rgb: false),
                     mode("hdr60-12", hz: 60, depth: 12, hdr: true)]
        #expect(choice(.hdr, modes, capabilities: ex)?.id == "hdr120")
        #expect(choice(.hdr, modes, capabilities: ex, hdr: false) == nil)
        #expect(choice(.everyday, modes, capabilities: ex) == nil)
    }

    @Test func unavailableNativeRGBNeverSilentlyBecomesSubsampledOrLowerResolution() {
        let modes = [mode("subsampled", rgb: false), mode("1080p", width: 1920, height: 1080)]
        #expect(choice(.everyday, modes, capabilities: ex) == nil)
        #expect(choice(.motion, modes, capabilities: ex) == nil)
    }

    @Test func lowerPowerKeepsDesktopUsableAndDoesNotChaseTwentyFourHz() {
        let modes = [mode("24", hz: 24, depth: 8), mode("59-8", hz: 59.95, depth: 8),
                     mode("60-10", hz: 60), mode("120")]
        #expect(choice(.lowerPower, modes, capabilities: ex)?.id == "59-8")
        #expect(choice(.everyday, [mode("30-10", hz: 30), mode("120-8", depth: 8)], capabilities: ex)?.id == "120-8")
    }

    @Test func unknownPanelUsesPreferredDimensionsButNotPreferredYCbCrEncoding() {
        let modes = [mode("preferred-limited", hz: 144, rgb: false, preferred: true), mode("rgb"),
                     mode("larger-signal", hz: 60, width: 3840, height: 2160)]
        #expect(choice(.everyday, modes)?.id == "rgb")
        let current = mode("current", width: 1920, height: 1080)
        #expect(choice(.everyday, [current, modes[2]], current: current)?.id == "current")
        #expect(choice(.everyday, [modes[1]]) == nil)
    }

    @Test func resultsBelongToCurrentEnumerationAndAreStableAcrossOrderChanges() {
        let modes = [mode("a"), mode("b"), mode("c", hz: 144, depth: 8)]
        let original = choice(.everyday, modes, capabilities: ex, current: modes[0])
        #expect(original == choice(.everyday, modes.reversed(), capabilities: ex, current: modes[0]))
        #expect(modes.contains(original!))
        let renumbered = [mode("new-driver-id")]
        #expect(choice(.everyday, renumbered, capabilities: ex, current: modes[0])?.id == "new-driver-id")
    }

    @Test func invalidRatesUnknownEncodingsAndVariableOnlyModesAreNotSuggested() {
        var unknown = mode("unknown")
        unknown.rawColorMode = "FutureUnknownColorMode"
        let modes = [mode("nan", hz: .nan), mode("infinity", hz: .infinity),
                     mode("too-fast", hz: 2000), mode("adaptive", variable: true), unknown]
        #expect(choice(.everyday, modes, capabilities: ex) == nil)
    }

    @Test func monitorCatalogRequiresVendorAndProductIdentity() {
        #expect(MonitorCapabilities.known(vendorID: 1, productID: 32630) == nil)
        #expect(MonitorCapabilities.known(vendorID: 2513, productID: nil) == nil)
        #expect(ex.width == 2560 && ex.height == 1440)
    }
}
