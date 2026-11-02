import AppKit
import Combine
import CoreGraphics
import DisplayCore
import DisplayNative
import ServiceManagement

private func displayChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                            _ context: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in DisplayController.shared.signal("Display configuration changed") }
}

private func hardwareDisplayChanged(_ registryID: UInt64, _ messageType: UInt32,
                                    _ context: UnsafeMutableRawPointer?) {
    Task { @MainActor in DisplayController.shared.signal("Display hardware changed") }
}

@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()
    @Published var displays: [DisplaySnapshot] = []
    @Published var extras: [UInt32: ExtraSnapshot] = [:]
    @Published var configuration = SavedConfiguration()
    @Published var decisions: [String: ProtectionDecision] = [:]
    @Published var restoreIssues: [String: String] = [:]
    @Published var snapshotError: String?
    @Published var eventError: String?
    @Published var lastCheckedAt: Date?
    @Published var isChecking = false
    @Published var feedback: ActionFeedback?
    @Published var recommendations: [String: RecommendationSet] = [:]
    @Published var activity: [ActivityEntry] = []
    @Published var error: String?
    @Published var pending: PendingChange?
    @Published var selectedID: UInt32?
    @Published var loginEnabled = false
    @Published var showActivity = false
    @Published var showAllFormats = false
    private var planner = ProtectionPlanner()
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var wakeWork: [DispatchWorkItem] = []
    private var rollbackWork: DispatchWorkItem?
    private var sleeping = false
    private var started = false
    private var lastRecoveryAttempt: TimeInterval = -.infinity
    private let configURL: URL
    private struct AdvisorInput: Equatable {
        let modes: [ConnectionMode]
        let current: ConnectionMode?
        let capabilities: MonitorCapabilities?
        let hdrAvailable: Bool
    }
    private var advisorInputs: [String: AdvisorInput] = [:]

    init() {
        configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DisplayKeeper/settings.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let saved = try JSONDecoder().decode(SavedConfiguration.self, from: Data(contentsOf: configURL))
                guard saved.version == 1 else { throw NativeFailure.message("Unsupported settings version.") }
                configuration = saved
                pending = saved.pendingChange
                // An unconfirmed change from an interrupted run must recover.
                pending?.phase = .reverting
                pending?.recoveryAttempts = 0
            } catch { self.error = "Could not load settings: \(error.localizedDescription). Protection is off." }
        }
    }

    var selected: DisplaySnapshot? { displays.first(where: { $0.id == selectedID }) ?? displays.first }
    var enabledCount: Int { configuration.policies.values.filter(\.enabled).count }
    var protectedCount: Int { displays.filter { configuration.policies[$0.uuid]?.enabled == true }.count }

    func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback(displayChanged, nil)
        do { try nativeResult(DKStartDisplayEvents(hardwareDisplayChanged, nil)) }
        catch {
            eventError = "Hardware display notifications unavailable: \(error.localizedDescription)"
            self.error = eventError
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.wake() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.refreshWork?.cancel()
                self?.wakeWork.forEach { $0.cancel() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.signal("Screen parameters changed") }
        })
        loginEnabled = SMAppService.mainApp.status == .enabled
        refresh(enforce: true)
        scheduleSettlingChecks()
        log("DisplayKeeper started. Protection responds to display and wake events.")
    }

    func signal(_ reason: String) {
        guard !sleeping else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh(enforce: true) }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func wake() {
        sleeping = false
        refresh(enforce: true)
        scheduleSettlingChecks()
        log("Wake detected; checking saved connection formats.")
    }

    private func scheduleSettlingChecks() {
        wakeWork.forEach { $0.cancel() }
        wakeWork = [0.5, 2.5, 6.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.refresh(enforce: true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    @discardableResult func refresh(enforce: Bool = false) -> Bool {
        guard !sleeping else { return false }
        do {
            let snapshot = try nativeJSON(DKCopySnapshotJSON(), as: NativeSnapshot.self)
            if let problem = snapshot.error { throw NativeFailure.message(problem) }
            snapshotError = nil
            displays = snapshot.displays
            let online = Set(displays.map(\.uuid))
            decisions = decisions.filter { online.contains($0.key) }
            restoreIssues = restoreIssues.filter { online.contains($0.key) }
            extras = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
                guard let extra = try? nativeJSON(DKCopyExtraJSON(display.id), as: ExtraSnapshot.self) else { return nil }
                return (display.id, extra)
            })
            updateRecommendations()
            if selectedID == nil || !displays.contains(where: { $0.id == selectedID }) { selectedID = displays.first?.id }
            if displays.isEmpty { error = "macOS did not expose any online displays. Open the app in your logged-in desktop session." }
            lastCheckedAt = Date()
            if enforce {
                if pending?.phase == .reverting { advanceRollback() }
                if !configuration.paused { reconcile() }
            }
            return true
        } catch {
            snapshotError = error.localizedDescription
            self.error = error.localizedDescription
            return false
        }
    }

    private func reconcile() {
        for display in displays where !display.builtIn && !display.uuid.isEmpty && display.uuid != pending?.displayUUID {
            let decision = planner.plan(displayUUID: display.uuid, current: display.currentConnection,
                                        available: display.connectionModes, policy: configuration.policies[display.uuid],
                                        now: ProcessInfo.processInfo.systemUptime)
            let previousDecision = decisions[display.uuid]
            decisions[display.uuid] = decision
            switch decision {
            case .unmanaged: restoreIssues[display.uuid] = nil
            case .alreadyCorrect:
                restoreIssues[display.uuid] = nil
                if case .apply = previousDecision {
                    report("Format restored", detail: "\(display.name): saved format verified.", tone: .good)
                } else if previousDecision == .coolingDown {
                    report("Format restored", detail: "\(display.name): saved format verified.", tone: .good)
                }
            case .unavailable, .coolingDown, .suspended: break
            case .apply(let mode):
                do {
                    try requestConnection(mode, on: display)
                    restoreIssues[display.uuid] = nil
                    log("\(display.name): requested \(mode.summary)")
                } catch {
                    restoreIssues[display.uuid] = error.localizedDescription
                    log("\(display.name): \(error.localizedDescription)")
                }
                // Verify/retry both accepted and failed requests, within the planner's budget.
                let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.refresh(enforce: true) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1, execute: work)
            }
        }
    }

    func protect(_ display: DisplaySnapshot, enabled: Bool) {
        guard refresh(), let fresh = displays.first(where: { $0.uuid == display.uuid && $0.id == display.id }),
              !fresh.builtIn, !fresh.uuid.isEmpty, let current = fresh.currentConnection else {
            report("Protection unchanged", detail: snapshotError ?? "This monitor's current format could not be read.", tone: .warning)
            return
        }
        let previous = configuration
        if enabled {
            configuration.policies[display.uuid] = DisplayPolicy(displayUUID: display.uuid, displayName: display.name,
                                                                  target: ModeTarget(mode: current), enabled: true)
        } else { configuration.policies[display.uuid]?.enabled = false }
        planner.reset(displayUUID: display.uuid)
        guard save() else {
            configuration = previous
            report("Protection unchanged", detail: error ?? "Settings could not be saved.", tone: .warning)
            return
        }
        refresh(enforce: true)
        report(enabled ? "Format saved" : "Protection turned off",
               detail: "\(display.name): \(enabled ? (configuration.paused ? "will protect this format when resumed." : "current format is now protected.") : "automatic correction is off.")",
               tone: enabled && !configuration.paused ? .good : .neutral)
    }

    func togglePause() {
        let previous = configuration.paused
        configuration.paused.toggle()
        if !configuration.paused {
            for display in displays { planner.reset(displayUUID: display.uuid) }
        }
        guard save() else {
            configuration.paused = previous
            report("Protection unchanged", detail: error ?? "Settings could not be saved.", tone: .warning)
            return
        }
        let refreshed = refresh(enforce: true)
        if configuration.paused {
            report("Protection paused", detail: "Automatic corrections are stopped. Your saved formats are kept.", tone: .paused)
        } else {
            let overview = protectionOverview
            report("Protection resumed", detail: refreshed ? overview.detail : "Current formats could not be verified. Check the monitor status.", tone: refreshed ? overview.tone : .warning)
        }
    }

    func resume(_ display: DisplaySnapshot) {
        planner.reset(displayUUID: display.uuid)
        refresh(enforce: true)
        let state = displays.first(where: { $0.uuid == display.uuid }).map { presentation(for: $0) }
            ?? ProtectionPresentation(title: "Monitor disconnected", detail: "Reconnect the monitor to retry.", symbol: "display", tone: .warning)
        report("\(display.name): retry checked", detail: state.title, tone: state.tone)
    }

    private func updateRecommendations() {
        let eligible = displays.filter { !$0.builtIn && !$0.uuid.isEmpty && $0.error == nil }
        let online = Set(eligible.map(\.uuid))
        for uuid in Array(advisorInputs.keys) where !online.contains(uuid) {
            advisorInputs.removeValue(forKey: uuid)
            recommendations.removeValue(forKey: uuid)
        }
        for display in eligible {
            let input = AdvisorInput(modes: display.connectionModes, current: display.currentConnection,
                                     capabilities: .known(vendorID: display.vendorID, productID: display.productID),
                                     hdrAvailable: extras[display.id]?.hdrSupported == true && extras[display.id]?.controlsError == nil)
            guard advisorInputs[display.uuid] != input else { continue }
            advisorInputs[display.uuid] = input
            recommendations[display.uuid] = ModeAdvisor.recommend(modes: input.modes, current: input.current,
                                                                 capabilities: input.capabilities, hdrAvailable: input.hdrAvailable)
        }
    }

    func tryRecommendation(_ purpose: RecommendationPurpose, on display: DisplaySnapshot) {
        guard pending == nil else { return }
        guard refresh(), let fresh = displays.first(where: { $0.uuid == display.uuid && $0.id == display.id }),
              fresh.error == nil,
              let mode = recommendations[fresh.uuid]?.options.first(where: { $0.purpose == purpose })?.mode else {
            report("Recommendation unavailable", detail: "The monitor or available formats changed. Check again before applying.", tone: .warning)
            return
        }
        if fresh.currentConnection.map({ ModeTarget(mode: mode).matches($0) }) == true {
            report("Already using this setup", detail: "\(fresh.name) matches the \(purpose.title.lowercased()) recommendation.", tone: .good)
            return
        }
        chooseConnection(mode, on: fresh)
    }

    func chooseConnection(_ mode: ConnectionMode, on display: DisplaySnapshot) {
        guard pending == nil, display.currentConnection?.id != mode.id else { return }
        let changesHDR = mode.rawHDRMode != display.currentConnection?.rawHDRMode
        beginChange(display, connection: mode, hdr: changesHDR ? mode.rawHDRMode != "SDR" : nil) {
            try requestConnection(mode, on: display)
        }
    }

    private func requestConnection(_ mode: ConnectionMode, on display: DisplaySnapshot) throws {
        guard refresh(), let fresh = displays.first(where: { $0.uuid == display.uuid }),
              let actual = fresh.currentConnection else {
            throw NativeFailure.message("The current connection cannot be read.")
        }
        if actual.rawHDRMode != mode.rawHDRMode {
            guard ["SDR", "HDR10"].contains(mode.rawHDRMode), extras[fresh.id]?.controlsError == nil,
                  extras[fresh.id]?.hdrSupported == true else {
                throw NativeFailure.message("The saved HDR state cannot be restored on this connection.")
            }
            try nativeResult(DKSetHDR(fresh.id, mode.rawHDRMode != "SDR"))
        }
        guard refresh(), let updated = displays.first(where: { $0.uuid == display.uuid }),
              let matching = updated.connectionModes.first(where: { ModeTarget(mode: mode).matches($0) }) else {
            throw NativeFailure.message("The requested format is no longer available.")
        }
        try nativeResult(DKSetConnectionMode(updated.id, matching.id))
    }

    func chooseDesktop(_ mode: DesktopMode, on display: DisplaySnapshot) {
        guard pending == nil, !mode.isCurrent else { return }
        beginChange(display, desktop: mode) { try nativeResult(DKSetDesktopMode(display.id, mode.id)) }
    }

    func chooseHDR(_ enabled: Bool, on display: DisplaySnapshot) {
        guard pending == nil else { return }
        beginChange(display, hdr: enabled) { try nativeResult(DKSetHDR(display.id, enabled)) }
    }

    func chooseRotation(_ degrees: Int, on display: DisplaySnapshot) {
        guard pending == nil else { return }
        beginChange(display, rotation: degrees) { try nativeResult(DKSetRotation(display.id, Int32(degrees))) }
    }

    private func beginChange(_ display: DisplaySnapshot, connection: ConnectionMode? = nil,
                             desktop: DesktopMode? = nil, rotation: Int? = nil, hdr: Bool? = nil,
                             action: () throws -> Void) {
        guard refresh(), let fresh = displays.first(where: { $0.uuid == display.uuid && $0.id == display.id }),
              !display.uuid.isEmpty, let current = fresh.currentConnection, let oldDesktop = fresh.currentDesktop else {
            error = "Cannot safely change this display until its current settings can be read."; return
        }
        if (rotation != nil || hdr != nil) && (extras[display.id] == nil || extras[display.id]?.controlsError != nil) {
            error = "The previous HDR or rotation state cannot be read safely."; return
        }
        let previous = ModeTarget(mode: current)
        pending = PendingChange(displayUUID: display.uuid, displayName: display.name,
                                previousConnection: previous, previousDesktop: oldDesktop,
                                previousRotation: rotation == nil ? nil : extras[display.id]?.rotation,
                                previousHDR: hdr == nil ? nil : extras[display.id]?.hdrEnabled,
                                expectedConnection: connection.map(ModeTarget.init(mode:)), expectedDesktop: desktop,
                                expectedRotation: rotation, expectedHDR: hdr, expires: Date().addingTimeInterval(15))
        guard save() else { pending = nil; return }
        do {
            try action()
            let rollback = DispatchWorkItem { [weak self] in Task { @MainActor in self?.revertChange() } }
            rollbackWork = rollback
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: rollback)
            refresh()
            signal("Verifying requested change")
        } catch {
            self.error = error.localizedDescription
            // A driver can partially apply a change before reporting an error.
            revertChange()
        }
    }

    func keepChange() {
        guard let pending, pending.phase == .awaitingConfirmation, refresh() else { return }
        guard let display = displays.first(where: { $0.uuid == pending.displayUUID }) else {
            error = "The display disconnected. The change has not been accepted."; return
        }
        if let target = pending.expectedConnection,
           display.currentConnection.map({ target.matches($0) }) != true {
            error = "The display has not reported the requested connection format. Revert or wait for it to settle."; return
        }
        if let expected = pending.expectedDesktop, !desktopMatches(display.currentDesktop, expected) {
            error = "The desktop mode did not match the requested setting."; return
        }
        if let expected = pending.expectedHDR,
           extras[display.id]?.controlsError != nil || extras[display.id]?.hdrEnabled != expected ||
            display.currentConnection.map({ ($0.rawHDRMode != "SDR") == expected }) != true {
            error = "HDR did not reach the requested state."; return
        }
        if let expected = pending.expectedRotation,
           extras[display.id]?.controlsError != nil || extras[display.id]?.rotation != expected {
            error = "Rotation did not reach the requested state."; return
        }
        rollbackWork?.cancel()
        self.pending = nil
        let previousPolicy = configuration.policies[display.uuid]
        if configuration.policies[display.uuid]?.enabled == true, let current = display.currentConnection {
            configuration.policies[display.uuid]?.target = ModeTarget(mode: current)
        }
        guard save() else {
            configuration.policies[display.uuid] = previousPolicy
            self.pending = pending
            revertChange()
            return
        }
        planner.reset(displayUUID: display.uuid)
        log("\(display.name): new settings verified and kept.")
        refresh(enforce: true)
    }

    func revertChange() {
        guard pending != nil else { return }
        rollbackWork?.cancel()
        pending?.phase = .reverting
        pending?.recoveryAttempts = 0
        lastRecoveryAttempt = -.infinity
        save()
        advanceRollback()
    }

    private func desktopMatches(_ actual: DesktopMode?, _ expected: DesktopMode) -> Bool {
        guard let actual else { return false }
        return actual.width == expected.width && actual.height == expected.height &&
            actual.pixelWidth == expected.pixelWidth && actual.pixelHeight == expected.pixelHeight &&
            abs(actual.refreshRate - expected.refreshRate) < 0.1
    }

    private func previousMatches(_ pending: PendingChange, _ display: DisplaySnapshot) -> Bool {
        if let mode = pending.previousConnection,
           display.currentConnection.map({ mode.matches($0) }) != true { return false }
        if let old = pending.previousDesktop,
           !desktopMatches(display.currentDesktop, old) { return false }
        if let rotation = pending.previousRotation,
           extras[display.id]?.controlsError != nil || extras[display.id]?.rotation != rotation { return false }
        if let hdr = pending.previousHDR,
           extras[display.id]?.controlsError != nil || extras[display.id]?.hdrEnabled != hdr { return false }
        return true
    }

    private func advanceRollback() {
        guard let recovery = pending, recovery.phase == .reverting, refresh() else { return }
        guard let display = displays.first(where: { $0.uuid == recovery.displayUUID }) else {
            error = "Reconnect \(recovery.displayName) to restore its previous setting. The recovery target is saved."; return
        }
        if previousMatches(recovery, display) {
            pending = nil; rollbackWork?.cancel(); save()
            log("\(display.name): previous settings restored and verified.")
            return
        }
        guard recovery.recoveryAttempts < 3 else {
            error = "Could not verify restoration for \(display.name). Check the picture and choose Retry restore. Recovery remains saved."
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecoveryAttempt >= 2 else { return }
        lastRecoveryAttempt = now
        pending?.recoveryAttempts += 1
        save()
        var failures: [String] = []
        func attempt(_ action: () throws -> Void) {
            do { try action() } catch { failures.append(error.localizedDescription) }
        }
        if let rotation = recovery.previousRotation, extras[display.id]?.rotation != rotation {
            attempt { try nativeResult(DKSetRotation(display.id, Int32(rotation))) }
        }
        if let hdr = recovery.previousHDR, extras[display.id]?.hdrEnabled != hdr {
            attempt { try nativeResult(DKSetHDR(display.id, hdr)) }
        }
        if refresh(), let current = displays.first(where: { $0.uuid == recovery.displayUUID }),
           let old = recovery.previousDesktop, !desktopMatches(current.currentDesktop, old) {
            attempt {
                guard let match = current.desktopModes.first(where: { desktopMatches($0, old) }) else {
                    throw NativeFailure.message("Previous desktop mode is unavailable.")
                }
                try nativeResult(DKSetDesktopMode(current.id, match.id))
            }
        }
        if refresh(), let current = displays.first(where: { $0.uuid == recovery.displayUUID }),
           let old = recovery.previousConnection, current.currentConnection.map({ old.matches($0) }) != true {
            attempt {
                guard let match = current.connectionModes.first(where: { old.matches($0) }) else {
                    throw NativeFailure.message("Previous connection format is unavailable.")
                }
                if !current.builtIn { try requestConnection(match, on: current) }
            }
        }
        if !failures.isEmpty { error = "Restoration awaiting verification: " + failures.joined(separator: " ") }
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.refresh(enforce: true) } }
        rollbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1, execute: work)
    }

    func setBrightness(_ value: Double, on display: DisplaySnapshot) {
        guard refresh(), displays.contains(where: { $0.id == display.id && $0.uuid == display.uuid }) else { return }
        do { try nativeResult(DKSetBrightness(display.id, Float(value))); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func refreshControls() {
        guard !isChecking else { return }
        isChecking = true
        // Let the button acknowledge the click before the main-thread native read.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let success = self.refresh(enforce: true)
            self.isChecking = false
            let overview = self.protectionOverview
            self.report(success ? "Check complete" : "Check failed",
                        detail: success ? "\(overview.title). \(overview.detail)" : self.snapshotError ?? "The current formats could not be read.",
                        tone: success ? overview.tone : .warning)
        }
    }

    func makeMain(_ display: DisplaySnapshot) {
        guard refresh(), displays.contains(where: { $0.id == display.id && $0.uuid == display.uuid }) else { return }
        do { try nativeResult(DKSetMainDisplay(display.id)); refresh(); log("\(display.name): requested main display.") }
        catch { self.error = error.localizedDescription }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { error = "Allow DisplayKeeper in System Settings → General → Login Items." }
        } catch { self.error = error.localizedDescription }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DisplayKeeper-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url, let pointer = DKCopySnapshotJSON() else { return }
        defer { DKFree(pointer) }
        do { try Data(String(cString: pointer).utf8).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    @discardableResult private func save() -> Bool {
        do {
            configuration.pendingChange = pending
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL, options: .atomic)
            return true
        } catch { self.error = "Could not save protection settings: \(error.localizedDescription)"; return false }
    }

    private func log(_ message: String) {
        activity.insert(ActivityEntry(message: message), at: 0)
        if activity.count > 80 { activity.removeLast(activity.count - 80) }
    }

    private func report(_ title: String, detail: String, tone: StatusTone) {
        feedback = ActionFeedback(title: title, detail: detail, tone: tone)
        log("\(title). \(detail)")
    }
}
