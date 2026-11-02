import Foundation

public enum RecommendationPurpose: String, CaseIterable, Identifiable {
    case everyday, motion, hdr, lowerPower
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .everyday: return "Everyday"
        case .motion: return "Smooth motion"
        case .hdr: return "HDR content"
        case .lowerPower: return "Lower power"
        }
    }
}

/// Published panel capabilities constrain recommendations, never create modes.
/// The useful depth is a signal target, not a claim about native panel precision.
public struct MonitorCapabilities: Equatable {
    public let width: Int
    public let height: Int
    public let refreshLimit: Double
    public let usefulDepth: Int
    public let hdr: Bool
    public let sourceURL: String

    public static func known(vendorID: UInt32?, productID: UInt32?) -> Self? {
        guard vendorID == 2513 else { return nil }
        switch productID {
        case 32630:
            return .init(width: 2560, height: 1440, refreshLimit: 144, usefulDepth: 10, hdr: true,
                         sourceURL: "https://www.benq.com/en-ca/monitor/gaming/ex2780q/spec.html")
        case 30973:
            return .init(width: 2560, height: 1440, refreshLimit: 100, usefulDepth: 8, hdr: false,
                         sourceURL: "https://www.benq.com/en-us/monitor/home/gw2790q/spec.html")
        default: return nil
        }
    }
}

public struct ModeRecommendation: Equatable, Identifiable {
    public let purpose: RecommendationPurpose
    public let mode: ConnectionMode?
    public let explanation: String
    public let tradeoff: String
    public var id: RecommendationPurpose { purpose }
}

public struct RecommendationSet: Equatable {
    public let basis: String
    public let sourceURL: String?
    public let options: [ModeRecommendation]
}

/// Local, deterministic advice based solely on currently advertised modes.
/// Unknown models use the driver's preferred dimensions (not its color format),
/// or explicitly retain current dimensions when panel metadata is unavailable.
public enum ModeAdvisor {
    public static func recommend(modes: [ConnectionMode], current: ConnectionMode?,
                                 capabilities: MonitorCapabilities?, hdrAvailable: Bool) -> RecommendationSet {
        let valid = modes.filter { !$0.id.isEmpty && $0.width > 0 && $0.height > 0 &&
            $0.refreshRate.isFinite && $0.refreshRate >= 23 && $0.refreshRate <= 1000 &&
            $0.bitDepth >= 8 && $0.bitDepth <= (capabilities?.usefulDepth ?? 10) &&
            !$0.isVRR && (capabilities == nil || $0.refreshRate <= capabilities!.refreshLimit + 0.1) }
        let width: Int, height: Int, basis: String
        if let capabilities {
            width = capabilities.width; height = capabilities.height
            basis = "Monitor specifications + modes available on this connection."
        } else if let preferred = modes.first(where: { $0.isPreferred && $0.width > 0 && $0.height > 0 }) {
            width = preferred.width; height = preferred.height
            basis = "Using macOS-preferred dimensions; this panel's native resolution is not independently verified."
        } else if let current, current.width > 0, current.height > 0 {
            width = current.width; height = current.height
            basis = "Keeping the current resolution because native panel dimensions are unknown."
        } else {
            return .init(basis: "The monitor's resolution could not be established.", sourceURL: nil,
                         options: RecommendationPurpose.allCases.map {
                .init(purpose: $0, mode: nil, explanation: "Wait for readable display information.", tradeoff: "")
            })
        }
        let native = valid.filter { $0.width == width && $0.height == height }
        let sdr = native.filter { $0.pixelEncoding == 0 && $0.dynamicRange == 0 && $0.eotf == 0 &&
            $0.rawColorMode == "RGBFullRange" && $0.rawHDRMode == "SDR" }
        let hdr = native.filter { $0.pixelEncoding == 0 && $0.dynamicRange == 0 && $0.eotf == 2 &&
            $0.rawColorMode == "HDR10_RGBFullRange" && $0.rawHDRMode == "HDR10" && $0.bitDepth >= 10 }

        func choose(_ candidates: [ConnectionMode], purpose: RecommendationPurpose) -> ConnectionMode? {
            func score(_ mode: ConnectionMode) -> [Double] {
                let rate = (mode.refreshRate * 100).rounded() / 100
                let depth = Double(mode.bitDepth)
                let matching = current.map { ModeTarget(mode: $0).matches(mode) } == true ? 1.0 : 0.0
                switch purpose {
                case .everyday:
                    // Prefer smooth desktop rates before depth; do not pick 30 Hz
                    // just because it offers more bits than a good 8-bit mode.
                    let smooth = rate >= 89 ? 2.0 : rate >= 59 ? 1.0 : 0.0
                    return [smooth, depth, rate, matching]
                case .motion, .hdr: return [rate, depth, matching]
                case .lowerPower:
                    // Near 60 Hz is a practical reduced-work option, not the
                    // absolute lowest timing (e.g. 24 Hz) the sink might accept.
                    let distance = abs(rate - 60)
                    return [rate >= 59 ? 1 : 0, distance <= 1 ? 0 : -distance, -depth, -distance, matching]
                }
            }
            return candidates.max { a, b in
                let sa = score(a), sb = score(b)
                for (x, y) in zip(sa, sb) where x != y { return x < y }
                return a.id > b.id
            }
        }

        let everyday = choose(sdr, purpose: .everyday)
        let motion = choose(sdr, purpose: .motion)
        let options = RecommendationPurpose.allCases.map { purpose -> ModeRecommendation in
            if purpose == .hdr && (!hdrAvailable || capabilities?.hdr == false) {
                return .init(purpose: purpose, mode: nil,
                             explanation: "HDR is not available through this monitor's current connection and controls.",
                             tradeoff: "Use an SDR recommendation for this setup.")
            }
            guard let mode = choose(purpose == .hdr ? hdr : sdr, purpose: purpose) else {
                return .init(purpose: purpose, mode: nil,
                             explanation: "No suitable \(purpose == .hdr ? "10-bit HDR" : "SDR") RGB Full format is advertised at \(width) × \(height).",
                             tradeoff: "A lower-resolution or chroma-subsampled mode is not selected automatically.")
            }
            let explanation: String, tradeoff: String
            switch purpose {
            case .everyday:
                explanation = "RGB Full and SDR for desktop work. Prioritizes a smooth refresh rate, then up to \(capabilities?.usefulDepth ?? 10)-bit color."
                if let motion, motion.refreshRate > mode.refreshRate + 0.1 {
                    tradeoff = "\(rate(motion)) Hz RGB is available at \(motion.bitDepth)-bit. This option keeps \(mode.bitDepth)-bit at \(rate(mode)) Hz."
                } else {
                    tradeoff = "This also reaches the highest fixed-refresh SDR RGB format available at this resolution."
                }
            case .motion:
                explanation = "Highest fixed refresh rate with full RGB color detail and SDR."
                if let everyday, mode.bitDepth < everyday.bitDepth {
                    tradeoff = "Trades \(everyday.bitDepth)-bit at \(rate(everyday)) Hz for \(mode.bitDepth)-bit at \(rate(mode)) Hz. 8-bit alone does not cause washed-out contrast."
                } else {
                    tradeoff = "No color-depth tradeoff compared with the everyday recommendation."
                }
            case .hdr:
                explanation = "A 10-bit RGB Full HDR signal for HDR video and games."
                tradeoff = "HDR support does not guarantee better SDR desktop color or high HDR contrast. Use Everyday for ordinary desktop work."
            case .lowerPower:
                explanation = "SDR at the available fixed refresh rate closest to 60 Hz, with 8-bit color when offered."
                tradeoff = "May reduce display/GPU work, with less fluid motion. Actual power savings are hardware- and content-dependent; they are not measured here."
            }
            return .init(purpose: purpose, mode: mode, explanation: explanation, tradeoff: tradeoff)
        }
        return .init(basis: basis, sourceURL: capabilities?.sourceURL, options: options)
    }

    private static func rate(_ mode: ConnectionMode) -> String { String(format: "%.0f", mode.refreshRate) }
}
