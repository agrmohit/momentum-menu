import AppKit
import Combine
import M4Core
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = HeadphoneController()
    private let preferences = Preferences.shared
    private let updateChecker = UpdateChecker()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var updateTimer: Timer?
    private var connectingTimer: Timer?
    private var connectingPhase: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(batteryPercent: nil, connected: false)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // Left click opens the popover, right click opens the menu. Without
        // this the button only reports left clicks.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        preferences.onMenuBarIconVisibilityChanged = { [weak self] visible in
            self?.statusItem.isVisible = visible
        }
        statusItem.isVisible = !preferences.hideMenuBarIcon

        // With the icon hidden there is nothing left to click, so opening the
        // app again has to lead somewhere useful: the window that can turn it
        // back on.
        if preferences.hideMenuBarIcon {
            openSettings()
        }

        popover = NSPopover()
        popover.behavior = .transient
        // No fixed contentSize: the popover grows and shrinks with its content,
        // so expanding Advanced Audio Settings is not clipped.
        popover.contentViewController = NSHostingController(rootView: MenuView(controller: controller))

        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                // receive(on:) already put us on the main run loop.
                MainActor.assumeIsolated { self?.updateStatusItem(state) }
            }
            .store(in: &cancellables)

        Task { await controller.connect() }

        // Battery and mode can change from the phone app or the headset's own
        // controls; a slow poll keeps the menu honest without hammering the link.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.controller.state.connected {
                    await self.controller.refresh()
                } else {
                    await self.controller.connect()
                }
            }
        }

        if preferences.automaticUpdateChecks {
            Task { await updateChecker.check() }
            updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.preferences.automaticUpdateChecks else { return }
                    await self.updateChecker.check()
                }
            }
        }
    }

    /// Reopening a menu bar app has no window to restore, so send the user to
    /// Settings — which is the only way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        updateTimer?.invalidate()
        connectingTimer?.invalidate()
        controller.disconnect()
    }

    private func updateStatusItem(_ state: DeviceState) {
        guard let button = statusItem.button else { return }

        if state.isConnecting { startConnectingAnimation() } else { stopConnectingAnimation() }

        // The battery bar carries the level, so no percentage text: it would
        // say the same thing twice and double the item's width, which matters
        // on a crowded menu bar. The exact figure is in the popover and the
        // tooltip.
        button.image = StatusIcon.image(batteryPercent: state.batteryPercent,
                                        connected: state.connected,
                                        connectingPhase: state.isConnecting ? connectingPhase : nil)
        // Not dimmed while connecting: the sweep should be visible.
        button.appearsDisabled = !state.connected && !state.isConnecting

        if state.isConnecting {
            button.toolTip = "MOMENTUM 4 — connecting…"
        } else if state.connected {
            let battery = state.batteryPercent.map { "\($0)%" } ?? "battery unknown"
            let mode = state.noiseMode?.rawValue ?? "unknown mode"
            button.toolTip = "MOMENTUM 4 — \(battery), \(mode)"
        } else if state.releasedByUser {
            button.toolTip = "MOMENTUM 4 — handed over to another device"
        } else {
            button.toolTip = "MOMENTUM 4 — not connected"
        }
    }

    private func startConnectingAnimation() {
        guard connectingTimer == nil else { return }
        connectingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                self.connectingPhase += 0.07
                button.image = StatusIcon.image(batteryPercent: nil, connected: false,
                                                connectingPhase: self.connectingPhase)
            }
        }
    }

    private func stopConnectingAnimation() {
        connectingTimer?.invalidate()
        connectingTimer = nil
        connectingPhase = 0
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await controller.connect() }
        }
    }

    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesItem), keyEquivalent: "")

        menu.addItem(.separator())
        let disconnect = menu.addItem(withTitle: "Disconnect",
                                      action: #selector(disconnectItem), keyEquivalent: "")
        disconnect.isEnabled = controller.state.connected
        disconnect.toolTip = "Free one of the headphones' two connection slots for another device."

        menu.addItem(.separator())
        menu.addItem(withTitle: "Exit App", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }

        // Attaching the menu and clicking the button is what positions it under
        // the status item; it is detached again so the next left click still
        // reaches our action rather than opening this menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsItem() { openSettings() }

    @objc private func disconnectItem() { controller.releaseHeadphones() }

    @objc private func checkForUpdatesItem() {
        openSettings()
        Task { await updateChecker.check() }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Momentum Menu Settings"
            window.contentViewController = NSHostingController(
                rootView: SettingsView(preferences: preferences, updates: updateChecker))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // An accessory app has no Dock icon and does not get focus for free.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
