import AppKit
import SwiftUI
import XCTest
@testable import M4Core
@testable import MomentumMenu

/// Renders the popover and Settings to PNGs, light and dark, without Bluetooth.
///
/// Opt-in: `SNAPSHOT_DIR=/some/dir swift test --filter SnapshotRender`.
/// Skipped otherwise, so the suite never writes files. Sliders render grey
/// because the off-screen window is never key.
@MainActor
final class SnapshotRender: XCTestCase {

    func testRender() async throws {
        guard let out = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("set SNAPSHOT_DIR to render")
        }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let device = FakeHeadset()
        device.modeTable = [1, 2, 2, 0, 3, 0]
        device.level = 62
        device.bass = 1
        device.bands = [0, 2.0, 2.5, 1.5, -2.0].map { Gain.encode(db: $0) }
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        fake.push(Reply.notification(Cmd.sampleRate, [0, 0, 0xAC, 0x44]))
        try await Task.sleep(for: .milliseconds(300))

        // A second headset with every slot taken, for the list's full state.
        let full = FakeHeadset()
        full.paired = [("MacBook Pro", true), ("Name's iPhone", true), ("iPad", false), ("Office PC", false)]
        full.firmware = [3, 38, 3]
        let fullFake = FakeTransport()
        fullFake.respond = { [weak fullFake] in full.respond($0, push: { fullFake?.push($0) }) }
        let fullController = HeadphoneController(transport: fullFake)
        await fullController.connect()
        device.paired = [("MacBook Pro", true), ("Name's iPhone", false), ("iPad", false), ("Office PC", false)]
        await controller.refreshPairedDevices()

        for (appearance, tag) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(MenuView(controller: controller, openSettings: {}),
                       to: "\(out)/popover-\(tag).png", appearance: appearance)
            try render(SettingsView(preferences: Preferences.shared, controller: controller),
                       to: "\(out)/settings-\(tag).png", appearance: appearance)
            for (name, owner) in [("devices", controller), ("devices-full", fullController)] {
                try render(PairedDevicesList(controller: owner, devices: owner.state.pairedDevices ?? [])
                    .padding(14).frame(width: 320),
                           to: "\(out)/\(name)-\(tag).png", appearance: appearance)
            }
        }
    }

    private func render<V: View>(_ view: V, to path: String, appearance: NSAppearance.Name) throws {
        // A bright, busy wallpaper under a translucent wash stands in for the
        // popover's glass: the case where tinted icons lose the most contrast.
        let wallpaper = LinearGradient(colors: [.green, .yellow, .orange, .green, .mint],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
        let glass = appearance == .darkAqua ? Color.black.opacity(0.45) : Color.white.opacity(0.45)
        let host = NSHostingView(rootView: view.background(glass).background(wallpaper))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // ARC owns the window; letting close() release it too crashes.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // Off-screen but ordered front: an unordered window never draws.
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
