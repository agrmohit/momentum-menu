import AppKit
import Combine
import M4Core
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    /// Fade on the way out, instant on the way in and while resizing.
    nonisolated func popoverShouldClose(_ popover: NSPopover) -> Bool {
        MainActor.assumeIsolated { popover.animates = true }
        return true
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            (notification.object as? NSPopover)?.animates = false
        }
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = HeadphoneController()
    private let preferences = Preferences.shared
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
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
        preferences.reapplyAppIcon()
        preferences.onBatteryPercentageVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.controller.state)
        }

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
        //
        // animates covers both the show/close transition and content resizing,
        // and we want opposite things from those two. Resizing must be instant
        // or expanding a section drags the whole box about; closing should
        // fade. So it stays off while open and is switched on just before a
        // close, in popoverShouldClose.
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuView(controller: controller) { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        })
        // The popover reads the content's size and re-anchors under the status
        // item. Left to resize the window itself, the host grew it upwards
        // from its bottom edge, pushing the header off the top of the screen.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

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
    }

    /// Reopening a menu bar app has no window to restore, so send the user to
    /// Settings — which is the only way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        connectingTimer?.invalidate()
        controller.disconnect()
    }

    private func updateStatusItem(_ state: DeviceState) {
        guard let button = statusItem.button else { return }

        if state.isConnecting {
            startPulse(interval: 1.0 / 12, step: 0.07)
        } else if state.isCharging == true, state.connected, !state.isFullyCharged {
            startPulse(interval: 1.0 / 10, step: 0.02)   // slower: breathing, not racing
        } else {
            stopPulse()
        }

        // The battery bar carries the level, so the percentage text is opt-in:
        // it says the same thing twice and doubles the item's width, which
        // matters on a crowded menu bar.
        if preferences.showBatteryPercentage, state.connected, let percent = state.batteryPercent {
            button.title = "\(percent)%"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.image = StatusIcon.image(
            batteryPercent: state.batteryPercent,
            connected: state.connected,
            connectingPhase: state.isConnecting ? connectingPhase : nil,
            // A full battery stops pulsing: the bar sits solid at 100%.
            chargingPhase: (state.isCharging == true && state.connected && !state.isFullyCharged)
                ? connectingPhase : nil)
        // Not dimmed while connecting: the sweep should be visible.
        button.appearsDisabled = !state.connected && !state.isConnecting

        if state.isConnecting {
            button.toolTip = "MOMENTUM 4 — connecting…"
        } else if state.connected {
            let battery = state.batteryPercent.map { "\($0)%" } ?? "battery unknown"
            let mode = state.noiseMode?.rawValue ?? "unknown mode"
            let charge = state.chargeLabel.map { ", \($0.lowercased())" } ?? ""
            button.toolTip = "MOMENTUM 4 — \(battery)\(charge), \(mode)"
        } else if state.releasedByUser {
            button.toolTip = "MOMENTUM 4 — handed over to another device"
        } else {
            button.toolTip = "MOMENTUM 4 — not connected"
        }
    }

    /// Drives both the connecting sweep and the charging breath; which one is
    /// drawn is decided when the image is built.
    private func startPulse(interval: TimeInterval, step: Double) {
        guard connectingTimer == nil else { return }
        connectingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                self.connectingPhase += step
                let state = self.controller.state
                button.image = StatusIcon.image(
                    batteryPercent: state.batteryPercent,
                    connected: state.connected,
                    connectingPhase: state.isConnecting ? self.connectingPhase : nil,
                    chargingPhase: (state.isCharging == true && state.connected
                                    && !state.isFullyCharged)
                        ? self.connectingPhase : nil)
            }
        }
    }

    private func stopPulse() {
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
            popover.performClose(nil)   // delegate turns the fade on
        } else {
            // Sized before it appears, so it opens at its final height.
            if let content = popover.contentViewController?.view {
                content.layoutSubtreeIfNeeded()
                popover.contentSize = content.fittingSize
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task {
                if controller.state.connected {
                    // The headphones never announce a change to these, so the
                    // phone may have changed them since the last poll.
                    await controller.refreshSettings()
                } else {
                    await controller.connect()
                }
            }
        }
    }

    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.addItem(item("Settings…", symbol: "gearshape", action: #selector(openSettingsItem), key: ","))

        menu.addItem(.separator())
        let refresh = item("Refresh", symbol: "arrow.clockwise", action: #selector(refreshItem))
        refresh.isEnabled = controller.state.connected
        menu.addItem(refresh)
        let disconnect = item("Disconnect", symbol: "power", action: #selector(disconnectItem))
        disconnect.isEnabled = controller.state.connected
        disconnect.toolTip = "Free one of the headphones' two connection slots for another device."
        menu.addItem(disconnect)

        menu.addItem(.separator())
        // No ⌘Q: key equivalents go to the active app, and this menu does not
        // make the app active (that kept focus from the app in front), so ⌘Q
        // here could quit that app instead.
        let quit = item("Quit MomentumMenu", symbol: "xmark.circle",
                        action: #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        menu.addItem(quit)

        // Attaching the menu and clicking the button is what positions it under
        // the status item; it is detached again so the next left click still
        // reaches our action rather than opening this menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self
        return item
    }

    @objc private func openSettingsItem() { openSettings() }

    @objc private func refreshItem() { Task { await controller.refresh() } }

    @objc private func disconnectItem() { controller.releaseHeadphones() }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Momentum Menu Settings"
            window.contentViewController = NSHostingController(
                rootView: SettingsView(preferences: preferences))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // An accessory app has no Dock icon and does not get focus for free.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
