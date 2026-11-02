import SwiftUI
import DisplayCore

// Select the property wrapper explicitly. The macOS 27 SDK also exports a
// same-named State macro whose plugin is absent from Command Line Tools.
private typealias LocalViewState<Value> = SwiftUI.State<Value>

struct RecommendationView: View {
    @EnvironmentObject var model: DisplayController
    let display: DisplaySnapshot
    let advice: RecommendationSet
    @LocalViewState private var purpose: RecommendationPurpose = .everyday
    @LocalViewState private var showBasis = false

    private var recommendation: ModeRecommendation? { advice.options.first { $0.purpose == purpose } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Recommended setup", systemImage: "lightbulb").font(.headline)
                Picker("Optimize for", selection: $purpose) {
                    ForEach(RecommendationPurpose.allCases) { purpose in Text(purpose.title).tag(purpose) }
                }.pickerStyle(.segmented)

                if let recommendation {
                    if let mode = recommendation.mode {
                        let inUse = display.currentConnection.map { ModeTarget(mode: mode).matches($0) } == true
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(mode.width) × \(mode.height) · \(String(format: "%.0f", mode.refreshRate)) Hz")
                                    .font(.system(size: 20, weight: .medium)).monospacedDigit()
                                Text("\(mode.bitDepthLabel) · RGB Full · \(mode.eotfLabel)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if inUse && model.snapshotError == nil {
                                Label("Already using", systemImage: "checkmark.circle.fill")
                                    .font(.callout).foregroundStyle(StatusTone.good.color)
                            } else {
                                Button("Try this setup…") { model.tryRecommendation(purpose, on: display) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.pending != nil || model.snapshotError != nil || display.error != nil || display.currentConnection == nil)
                            }
                        }
                        if !inUse, let current = display.currentConnection {
                            Text(changes(from: current, to: mode)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Unavailable on this connection", systemImage: "minus.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(recommendation.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(recommendation.tradeoff).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("How this is chosen", isExpanded: $showBasis) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(advice.basis)
                        Text("Only formats currently offered by this connection are considered. Recommendations preserve full RGB detail and use fixed refresh rates. Signal format does not replace color calibration or an appropriate ICC profile.")
                        if let source = advice.sourceURL, let url = URL(string: source) {
                            Link("Monitor specifications ↗", destination: url)
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
                Text("Trying a setup may briefly blank the monitor. Keep it within 15 seconds or the previous settings return.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }

    private func changes(from current: ConnectionMode, to target: ConnectionMode) -> String {
        var differences: [String] = []
        if current.width != target.width || current.height != target.height {
            differences.append("\(current.width) × \(current.height) → \(target.width) × \(target.height)")
        }
        if abs(current.refreshRate - target.refreshRate) > 0.1 {
            differences.append("\(String(format: "%.0f", current.refreshRate)) → \(String(format: "%.0f", target.refreshRate)) Hz")
        }
        if current.bitDepth != target.bitDepth { differences.append("\(current.bitDepth) → \(target.bitDepth)-bit") }
        if current.rawColorMode != target.rawColorMode && (current.pixelEncoding != target.pixelEncoding || current.dynamicRange != target.dynamicRange) {
            differences.append("\(current.pixelEncodingLabel) \(current.dynamicRangeLabel) → RGB Full")
        }
        if current.rawHDRMode != target.rawHDRMode { differences.append("\(current.eotfLabel) → \(target.eotfLabel)") }
        if current.isVRR { differences.append("Variable → fixed refresh") }
        return differences.isEmpty ? "Updates the advertised signal format." : "Changes: " + differences.joined(separator: " · ")
    }
}
