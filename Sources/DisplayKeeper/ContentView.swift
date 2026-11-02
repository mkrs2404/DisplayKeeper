import SwiftUI
import DisplayCore

private let accent = Color(red: 0.18, green: 0.56, blue: 0.44)

struct ContentView: View {
    @EnvironmentObject var model: DisplayController

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if let pending = model.pending { confirmation(pending) }
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(Color.orange.opacity(0.09))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let display = model.selected { DisplayDetail(display: display) }
                        else {
                            ContentUnavailableView("No displays found", systemImage: "display",
                                                   description: Text("Refresh from your active desktop session."))
                        }
                        DisclosureGroup("Recent activity", isExpanded: $model.showActivity) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.activity.prefix(20)) { event in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(event.time, style: .time).foregroundStyle(.secondary).monospacedDigit()
                                        Text(event.message).frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.caption)
                                }
                            }.padding(.top, 12).textSelection(.enabled)
                        }.foregroundStyle(.secondary)
                    }.padding(28).frame(maxWidth: 950, alignment: .leading)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DisplayKeeper").font(.headline)
                    Text("Make it stay right.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 22)
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR DISPLAYS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                ForEach(model.displays) { display in
                    Button { model.selectedID = display.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: display.builtIn ? "laptopcomputer" : "display").font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(display.isMain ? "Main display" : display.builtIn ? "Built-in display" : "External display")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.configuration.policies[display.uuid]?.enabled == true {
                                Image(systemName: model.presentation(for: display).symbol).font(.caption)
                                    .foregroundStyle(model.presentation(for: display).tone.color)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selected?.id == display.id ? accent.opacity(0.13) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Label(model.protectionOverview.title, systemImage: model.protectionOverview.symbol)
                    .font(.callout).foregroundStyle(model.protectionOverview.tone.color)
                Button(model.configuration.paused ? "Resume protection" : "Pause protection") { model.togglePause() }
                    .disabled(model.enabledCount == 0 && !model.configuration.paused)
                if let feedback = model.feedback {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feedback.title).fontWeight(.medium)
                        Text(feedback.detail).foregroundStyle(.secondary)
                    }.font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    .toggleStyle(.switch).controlSize(.small).font(.callout)
                Text("Keep the app running to restore your saved formats after wake or reconnect.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Export diagnostics…", action: model.exportDiagnostics).buttonStyle(.link).font(.caption)
            }
        }.padding(18).background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Display controls").font(.system(size: 22, weight: .semibold))
                Text("Your setup, remembered.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button { model.refreshControls() } label: {
                    Label(model.isChecking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                }.controlSize(.regular).disabled(model.isChecking)
                if let checked = model.lastCheckedAt {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 28).padding(.vertical, 20)
    }

    private func confirmation(_ pending: PendingChange) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.display").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(pending.phase == .reverting ? "Restoring \(pending.displayName)" : "Does \(pending.displayName) look right?").font(.headline)
                if pending.phase == .reverting {
                    Text("Waiting for the previous settings to be confirmed.").font(.caption)
                } else { TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Previous settings return in \(max(0, Int(pending.expires.timeIntervalSince(context.date)))) seconds.")
                        .font(.caption).monospacedDigit()
                } }
            }
            Spacer()
            Button(pending.phase == .reverting ? "Retry restore" : "Revert", action: model.revertChange).keyboardShortcut(.cancelAction)
            if pending.phase == .awaitingConfirmation { Button("Keep settings", action: model.keepChange).buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }.padding(18).background(accent.opacity(0.14))
    }
}

struct DisplayDetail: View {
    @EnvironmentObject var model: DisplayController
    let display: DisplaySnapshot

    private var protected: Bool { model.configuration.policies[display.uuid]?.enabled == true }
    private var protectionStatus: String {
        model.presentation(for: display).title
    }
    private var formats: [ConnectionMode] {
        let current = display.currentConnection
        return display.connectionModes.filter {
            model.showAllFormats || (current != nil && $0.width == current!.width && $0.height == current!.height &&
                               abs($0.refreshRate - current!.refreshRate) < 0.1 && $0.isVRR == current!.isVRR)
        }.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if abs(a.refreshRate - b.refreshRate) > 0.1 { return a.refreshRate > b.refreshRate }
            return a.summary < b.summary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(accent.opacity(0.10)).frame(width: 90, height: 86)
                    Image(systemName: display.builtIn ? "laptopcomputer" : "display").font(.system(size: 42, weight: .light))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(display.name).font(.system(size: 28, weight: .semibold))
                    if let desktop = display.currentDesktop {
                        Text(desktop.label).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 7) {
                        tag(display.builtIn ? "BUILT IN" : "EXTERNAL")
                        if display.isMain { tag("MAIN") }
                    }
                }
                Spacer()
            }
            if let issue = display.error { Text(issue).font(.callout).foregroundStyle(.orange) }
            if !display.builtIn, let advice = model.recommendations[display.uuid] {
                RecommendationView(display: display, advice: advice).id(display.uuid)
            }
            if let current = display.currentConnection, !display.builtIn {
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("Color protection", systemImage: "shield.lefthalf.filled").font(.headline)
                            Spacer()
                            Toggle("Protect current format", isOn: Binding(get: { protected }, set: { model.protect(display, enabled: $0) }))
                                .labelsHidden().toggleStyle(.switch)
                                .accessibilityLabel("Protect current color format")
                                .disabled(model.pending != nil || display.uuid.isEmpty)
                        }
                        HStack(spacing: 22) {
                            metric("ENCODING", current.pixelEncodingLabel)
                            metric("RANGE", current.dynamicRangeLabel)
                            metric("DEPTH", current.bitDepthLabel)
                            metric("SIGNAL", current.eotfLabel)
                        }
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(protectionStatus)
                                    .font(.callout).fontWeight(.medium)
                                if let policy = model.configuration.policies[display.uuid], protected {
                                    Text("Saved: \(policy.target.width) × \(policy.target.height) · \(String(format: "%.0f", policy.target.refreshRate)) Hz · \(policy.target.bitDepth)-bit · \(policy.target.rawColorMode)")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Turn on after the picture looks right. The app remembers this monitor’s format.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if protected { Button("Retry", action: { model.resume(display) }).controlSize(.small) }
                        }
                    }.padding(12)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Picture & timing", systemImage: "slider.horizontal.3").font(.headline)
                    row("Resolution & refresh") {
                        Menu(display.currentDesktop?.label ?? "Choose a mode") {
                            ForEach(display.desktopModes.sorted(by: { $0.width == $1.width ? $0.refreshRate > $1.refreshRate : $0.width > $1.width })) { mode in
                                Button(mode.label + (mode.isCurrent ? " ✓" : "")) { model.chooseDesktop(mode, on: display) }
                            }
                        }.frame(maxWidth: 370)
                    }
                    if !display.builtIn && !formats.isEmpty {
                        row("Connection format") {
                            Menu {
                                ForEach(formats) { mode in
                                    Button(mode.summary + (mode.isCurrent ? " ✓" : "")) { model.chooseConnection(mode, on: display) }
                                }
                            } label: {
                                Text(display.currentConnection.map { "\($0.bitDepthLabel) · \($0.pixelEncodingLabel) \($0.dynamicRangeLabel) · \($0.eotfLabel)" } ?? "Choose format")
                            }.frame(maxWidth: 370)
                        }
                        Toggle("Show formats at other resolutions and refresh rates", isOn: $model.showAllFormats)
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Some RGB and 10-bit formats need a lower refresh rate. A format change may briefly blank the display.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.extras[display.id]?.hdrSupported == true {
                        row("High Dynamic Range") {
                            Toggle("HDR", isOn: Binding(get: { model.extras[display.id]?.hdrEnabled == true },
                                                      set: { model.chooseHDR($0, on: display) }))
                                .labelsHidden().toggleStyle(.switch).accessibilityLabel("High Dynamic Range")
                        }
                    }
                    if let brightness = display.brightness {
                        row("Brightness") {
                            Slider(value: Binding(get: { brightness }, set: { model.setBrightness($0, on: display) }), in: 0.05...1)
                                .frame(width: 210).accessibilityLabel("Display brightness")
                            Text("\(Int(brightness * 100))%").monospacedDigit().frame(width: 40)
                        }
                    }
                }.padding(12)
            }.disabled(model.pending != nil)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Workspace", systemImage: "rectangle.3.group").font(.headline)
                    if !display.builtIn && model.extras[display.id]?.rotationSupported == true {
                        row("Rotation") {
                            Picker("Rotation", selection: Binding(get: { model.extras[display.id]?.rotation ?? 0 },
                                                                  set: { model.chooseRotation($0, on: display) })) {
                                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                            }.labelsHidden().frame(width: 180)
                        }
                    }
                    row("Main display") {
                        if display.isMain { Label("This display", systemImage: "checkmark").foregroundStyle(accent) }
                        else { Button("Make main display") { model.makeMain(display) } }
                    }
                    row("Arrangement & profiles") {
                        Button("Open macOS display settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                    if let profile = model.extras[display.id]?.profileName {
                        row("Color profile") { Text(profile).foregroundStyle(.secondary).font(.callout) }
                    }
                }.padding(12)
            }.disabled(model.pending != nil)
            Text("Protection starts when DisplayKeeper runs. macOS controls the boot screen and the initial display handshake.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule())
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) { Text(title).font(.callout); Spacer(); content() }
    }
}
