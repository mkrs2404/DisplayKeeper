import Foundation

/// The persistent, semantic properties of a selected connection mode.
public struct ModeTarget: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var bitDepth: Int
    public var pixelEncoding: Int
    public var dynamicRange: Int
    public var eotf: Int
    public var colorimetry: Int
    public var rawColorMode: String
    public var rawHDRMode: String
    public var rawColorGamut: String
    public var isVRR: Bool

    public init(mode: ConnectionMode) {
        width = mode.width
        height = mode.height
        refreshRate = mode.refreshRate
        bitDepth = mode.bitDepth
        pixelEncoding = mode.pixelEncoding
        dynamicRange = mode.dynamicRange
        eotf = mode.eotf
        colorimetry = mode.colorimetry
        rawColorMode = mode.rawColorMode
        rawHDRMode = mode.rawHDRMode
        rawColorGamut = mode.rawColorGamut
        isVRR = mode.isVRR
    }

    public func matches(_ mode: ConnectionMode) -> Bool {
        guard refreshRate.isFinite, mode.refreshRate.isFinite else {
            return false
        }

        // Account for floating-point representation at the inclusive 0.1 Hz
        // boundary without accepting a meaningfully different refresh rate.
        let roundingAllowance = max(refreshRate.ulp, mode.refreshRate.ulp)
        return width == mode.width
            && height == mode.height
            && abs(refreshRate - mode.refreshRate) <= 0.1 + roundingAllowance
            && bitDepth == mode.bitDepth
            && pixelEncoding == mode.pixelEncoding
            && dynamicRange == mode.dynamicRange
            && eotf == mode.eotf
            && colorimetry == mode.colorimetry
            && rawColorMode == mode.rawColorMode
            && rawHDRMode == mode.rawHDRMode
            && rawColorGamut == mode.rawColorGamut
            && isVRR == mode.isVRR
    }
}

public struct DisplayPolicy: Codable {
    public var displayUUID: String
    public var displayName: String
    public var target: ModeTarget
    public var enabled: Bool

    public init(
        displayUUID: String,
        displayName: String,
        target: ModeTarget,
        enabled: Bool = true
    ) {
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.target = target
        self.enabled = enabled
    }
}
