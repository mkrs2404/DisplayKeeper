import Foundation

/// A connection mode reported by the display driver.
///
/// The identifier belongs to the current driver enumeration. Persist a
/// `ModeTarget` instead when retaining a mode across reconnects or restarts.
public struct ConnectionMode: Codable, Hashable, Identifiable {
    public var id: String
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
    public var isCurrent: Bool
    public var isPreferred: Bool

    public init(
        id: String,
        width: Int,
        height: Int,
        refreshRate: Double,
        bitDepth: Int,
        pixelEncoding: Int,
        dynamicRange: Int,
        eotf: Int,
        colorimetry: Int,
        rawColorMode: String = "",
        rawHDRMode: String = "",
        rawColorGamut: String = "",
        isVRR: Bool = false,
        isCurrent: Bool = false,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.bitDepth = bitDepth
        self.pixelEncoding = pixelEncoding
        self.dynamicRange = dynamicRange
        self.eotf = eotf
        self.colorimetry = colorimetry
        self.rawColorMode = rawColorMode
        self.rawHDRMode = rawHDRMode
        self.rawColorGamut = rawColorGamut
        self.isVRR = isVRR
        self.isCurrent = isCurrent
        self.isPreferred = isPreferred
    }
}

public extension ConnectionMode {
    var bitDepthLabel: String { "\(bitDepth)-bit" }

    var summary: String {
        let refresh = String(format: "%g", refreshRate)
        let gamut = rawColorGamut.isEmpty ? "" : " · \(rawColorGamut)"
        let variableRefresh = isVRR ? " · VRR" : ""
        return "\(width) × \(height) · \(refresh) Hz · \(bitDepthLabel) · \(pixelEncodingLabel) · \(dynamicRangeLabel) · \(eotfLabel)\(gamut)\(variableRefresh)"
    }

    // These are observed driver values, rather than a complete enumeration of
    // every encoding or transfer function supported by macOS display drivers.
    var pixelEncodingLabel: String {
        switch pixelEncoding {
        case 0: return "RGB"
        case 3: return "YCbCr 4:4:4"
        case 2: return "YCbCr 4:2:2"
        case 6: return "YCbCr 4:2:0"
        default: return "Encoding \(pixelEncoding)"
        }
    }

    var dynamicRangeLabel: String {
        switch dynamicRange {
        case 0: return "Full"
        case 1: return "Limited"
        default: return "Range \(dynamicRange)"
        }
    }

    var eotfLabel: String {
        switch eotf {
        case 0: return "SDR"
        case 2: return "HDR"
        default: return "EOTF \(eotf)"
        }
    }
}
