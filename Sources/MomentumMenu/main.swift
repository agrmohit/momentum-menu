import AppKit
import Foundation
import M4Core

// `--probe` does a read-only pass over the headphones and prints what it
// found. It sends no writes at all, which makes it the safe way to check that
// the control channel works before trusting the UI with anything.
// Development aid: render the menu bar icon large, at several charge levels,
// on both a dark and a light background.
if let index = CommandLine.arguments.firstIndex(of: "--icon-preview"),
   index + 1 < CommandLine.arguments.count {
    try StatusIcon.writePreview(to: CommandLine.arguments[index + 1])
    print("wrote \(CommandLine.arguments[index + 1])")
    exit(0)
}

// Lists paired devices and their SDP records, without connecting to anything.
if CommandLine.arguments.contains("--devices") {
    print(BluetoothDiagnostics.inventory())
    exit(0)
}

// Opens candidate RFCOMM channels and reports which complete. Sends no
// GAIA commands.
if CommandLine.arguments.contains("--try-rfcomm") {
    Task { @MainActor in
        print(await BluetoothDiagnostics.probeChannels())
        exit(0)
    }
    RunLoop.main.run()
}

// Connects and prints every frame the headphones send, so unsolicited pushes
// (charging, on-head detection) can be seen. Sends nothing but the connect
// handshake.
if let index = CommandLine.arguments.firstIndex(of: "--listen") {
    let seconds = Double(CommandLine.arguments.dropFirst(index + 1).first ?? "") ?? 45
    Task { @MainActor in
        let controller = HeadphoneController()
        controller.frameLogger = { print($0) }
        await controller.connect(userInitiated: true)
        guard controller.state.connected else {
            FileHandle.standardError.write(Data(
                ((controller.state.lastError ?? "Could not reach the headphones.") + "\n").utf8))
            exit(1)
        }
        print("Listening \(Int(seconds))s — plug or unplug the charging cable now.")
        try? await Task.sleep(for: .seconds(seconds))
        print("Done.")
        controller.disconnect()
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--probe") {
    // IOBluetooth delivers its callbacks on the run loop, so we need one even
    // for a command line pass.
    Task { @MainActor in
        let controller = HeadphoneController()
        await controller.connect()

        guard controller.state.connected else {
            FileHandle.standardError.write(Data(
                ((controller.state.lastError ?? "Could not reach the headphones.") + "\n").utf8))
            exit(1)
        }
        print(await controller.probeReport())
        if CommandLine.arguments.contains("--diagnose") {
            print("\n--- payload-form diagnostic (read-only) ---")
            print(await controller.diagnose())
        }
        controller.disconnect()
        exit(0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    // Top-level code is not main-actor isolated, but it does run on the main
    // thread, which is what AppDelegate's isolation actually requires.
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
