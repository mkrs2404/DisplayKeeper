import AppKit
import SwiftUI
import DisplayNative
import Carbon
import Combine

@main
enum DisplayKeeperMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--diagnose") {
            guard let value = DKCopySnapshotJSON() else {
                fputs("No display snapshot returned.\n", stderr); exit(1)
            }
            print(String(cString: value)); DKFree(value); return
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); return
        }
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var stateObservation: AnyCancellable?
    private var menuIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DisplayKeeper")
        let quickControls = NSMenuItem(title: "Quick controls", action: #selector(togglePopover), keyEquivalent: "d")
        quickControls.keyEquivalentModifierMask = [.command, .shift]
        quickControls.target = self
        appMenu.addItem(quickControls)
        let allControls = NSMenuItem(title: "All controls…", action: #selector(showWindow), keyEquivalent: ",")
        allControls.target = self
        appMenu.addItem(allControls)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DisplayKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApplication.shared.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuIcon = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "pdf")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "display", accessibilityDescription: "DisplayKeeper")
        menuIcon?.size = NSSize(width: 20, height: 18)
        menuIcon?.isTemplate = true
        statusItem?.button?.image = menuIcon
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        let panel = NSHostingController(rootView: MenuBarView(
            model: DisplayController.shared,
            openControls: { [weak self] displayID in
                if let displayID { DisplayController.shared.selectedID = displayID }
                self?.showWindow()
            }, quit: { [weak self] in self?.quit() }))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        stateObservation = DisplayController.shared.objectWillChange
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }
        DisplayController.shared.start()
        updateStatusItem()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || launchEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if !loginLaunch && !CommandLine.arguments.contains("--background") { showWindow() }
    }

    @objc func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let root = ContentView().environmentObject(DisplayController.shared)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "DisplayKeeper"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: root)
            window.minSize = NSSize(width: 900, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        DisplayController.shared.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = "DisplayKeeper Quick Controls"
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        let state = DisplayController.shared.protectionOverview
        let symbol: String?
        switch state.tone {
        case .paused: symbol = "pause.rectangle"
        case .warning: symbol = "exclamationmark.triangle"
        case .working: symbol = "arrow.triangle.2.circlepath"
        case .good, .neutral: symbol = nil
        }
        let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? menuIcon
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        statusItem?.button?.setAccessibilityLabel("DisplayKeeper: \(state.title)")
        statusItem?.button?.toolTip = "DisplayKeeper — \(state.title)\n\(state.detail)"
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        DisplayController.shared.revertChange()
        DKStopDisplayEvents()
    }
}
