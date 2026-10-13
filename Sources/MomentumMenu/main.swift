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
