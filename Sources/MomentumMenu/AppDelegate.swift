import AppKit
import Combine
import M4Core
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = HeadphoneController()
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones",
                                          accessibilityDescription: "MOMENTUM 4")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 420)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        controller.disconnect()
    }

    private func updateStatusItem(_ state: DeviceState) {
        guard let button = statusItem.button else { return }
        if state.connected, let battery = state.batteryPercent {
            button.title = " \(battery)%"
        } else {
            button.title = ""
        }
        button.appearsDisabled = !state.connected
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await controller.connect() }
        }
    }
}
