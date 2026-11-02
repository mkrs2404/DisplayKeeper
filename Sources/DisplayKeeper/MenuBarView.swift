import SwiftUI

private let keeperGreen = Color(red: 0.20, green: 0.62, blue: 0.46)

extension StatusTone {
    var color: Color {
        switch self {
        case .good: return keeperGreen
        case .neutral: return .secondary
        case .paused, .warning: return .orange
        case .working: return .blue
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: DisplayController
    let openControls: (UInt32?) -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                overview
                HStack {
                    Text("DISPLAYS").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    if let checked = model.lastCheckedAt {
                        Text("Checked \(checked.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 10)).monospacedDigit()
                    }
                }.foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.externalDisplays) { display in
                            monitorCard(display)
                        }
                        ForEach(model.disconnectedPolicies, id: \.displayUUID) { policy in
                            HStack(spacing: 10) {
                                Image(systemName: "display").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(policy.displayName).font(.system(size: 12, weight: .medium))
                                    Text("Disconnected · saved format kept").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
                        }
                        ForEach(model.displays.filter(\.builtIn)) { display in
                            Button { openControls(display.id) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "laptopcomputer")
                                    Text(display.name).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("macOS").font(.caption2)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }.foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Open built-in display controls")
                        }
                        if model.displays.isEmpty && model.disconnectedPolicies.isEmpty {
                            Text("No displays detected. Check again from your active desktop session.")
                                .font(.callout).foregroundStyle(.secondary).padding(12)
                        }
                    }.padding(1)
                }.scrollIndicators(.hidden)
                    .frame(height: min(330, CGFloat(max(1, model.externalDisplays.count)) * 123
                                      + CGFloat(model.disconnectedPolicies.count) * 64
                                      + (model.displays.contains(where: \.builtIn) ? 34 : 0)))

                if let pending = model.pending {
                    Button { openControls(nil) } label: {
                        Label(pending.phase == .reverting ? "Review restoration…" : "Review pending change…", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }.controlSize(.large)
                }
                feedback
                HStack(spacing: 8) {
                    Button(action: model.refreshControls) {
                        HStack(spacing: 6) {
                            if model.isChecking { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(model.isChecking ? "Checking…" : "Check now")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.isChecking)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Read the current formats and check enabled protection")
                    Button(action: model.togglePause) {
                        Label(model.configuration.paused ? "Resume" : "Pause protection",
                              systemImage: model.configuration.paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.primary)
                    }.buttonStyle(PanelSecondaryButtonStyle())
                        .keyboardShortcut("p", modifiers: .command)
                        .disabled(model.enabledCount == 0 && !model.configuration.paused)
                        .help(model.configuration.paused ? "Resume automatic color protection" : "Pause automatic corrections; keep saved formats")
                }.controlSize(.large).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 16).padding(.bottom, 14)
            Divider()
            HStack {
                Button { openControls(nil) } label: { Label("All controls…", systemImage: "slider.horizontal.3") }
                    .help("Resolution, refresh rate, HDR, rotation and login settings")
                Spacer()
                Button(action: quit) { Label("Quit", systemImage: "power") }
                    .help("Quit DisplayKeeper and stop automatic protection")
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 13)
        }.frame(width: 380).background(.regularMaterial).tint(keeperGreen)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("DisplayKeeper").font(.system(size: 15, weight: .semibold))
                Text("Color & connection protection").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(model.loginEnabled ? keeperGreen : .secondary).frame(width: 4, height: 4)
                Text(model.loginEnabled ? "At login" : "Manual").font(.system(size: 9, weight: .medium))
            }.foregroundStyle(.secondary)
                .help(model.loginEnabled ? "Starts automatically at login" : "Open at login is off")
        }.padding(16)
    }

    private var overview: some View {
        let state = model.protectionOverview
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol).font(.system(size: 20)).foregroundStyle(state.tone.color)
                .frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Text(state.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(state.tone.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
    }

    private func monitorCard(_ display: DisplaySnapshot) -> some View {
        let state = model.presentation(for: display)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "display").font(.system(size: 14)).foregroundStyle(.secondary)
                Button { openControls(display.id) } label: {
                    HStack(spacing: 5) {
                        Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain).help("Open controls for \(display.name)")
                Spacer(minLength: 2)
                Toggle("Protect \(display.name)", isOn: Binding(
                    get: { model.configuration.policies[display.uuid]?.enabled == true },
                    set: { model.protect(display, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(model.pending != nil || display.uuid.isEmpty || display.currentConnection == nil)
                    .help("Remember and protect this monitor's current color format")
            }
            if let mode = display.currentConnection {
                Text("\(mode.width) × \(mode.height)  ·  \(String(format: "%.0f", mode.refreshRate)) Hz\(mode.isVRR ? " variable" : "")\(display.isMain ? "  ·  Main" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 5) {
                    formatPill("\(mode.pixelEncodingLabel) \(mode.dynamicRangeLabel)")
                    formatPill(mode.bitDepthLabel)
                    formatPill(mode.eotfLabel)
                    Spacer(minLength: 0)
                    if model.snapshotError != nil || display.error != nil {
                        Text("Last read").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Current format unavailable").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Image(systemName: state.symbol).font(.system(size: 10))
                Text(state.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(state.tone == .good ? Color.secondary : state.tone.color)
                Spacer(minLength: 0)
                if state.tone == .warning && model.pending == nil && !model.configuration.paused {
                    Button("Retry") { model.resume(display) }.controlSize(.mini)
                } else if model.recommendations[display.uuid] != nil {
                    Button { openControls(display.id) } label: {
                        Label("Setups…", systemImage: "lightbulb").font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Compare recommended configurations for \(display.name)")
                }
            }.foregroundStyle(state.tone.color).help(state.detail)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
    }

    private func formatPill(_ value: String) -> some View {
        Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.feedback?.tone == .warning ? "exclamationmark.circle" : "clock.arrow.circlepath")
                    .foregroundStyle(model.feedback?.tone.color ?? .secondary)
                Text(model.feedback?.title ?? "Watching for display changes").fontWeight(.medium)
                Spacer(minLength: 0)
                if let date = model.feedback?.date {
                    Text(date.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }.font(.system(size: 11))
            Text(model.feedback?.detail ?? "Changes and wake events trigger a check automatically.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            .accessibilityElement(children: .combine)
    }
}

private struct PanelSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 7)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
            .contentShape(Capsule())
    }
}
