import AppKit
import M4Core

/// Runs Check for Updates for the right-click menu and Settings, and shows
/// the result in an alert. One check at a time; the request rules live in
/// `UpdateCheck`.
@MainActor
final class UpdatePrompt: ObservableObject {
    static let shared = UpdatePrompt()

    /// True while a check is waiting on GitHub; the menu item and the
    /// Settings button are disabled meanwhile.
    @Published private(set) var checking = false

    func check() {
        guard !checking else { return }
        checking = true
        let current = Preferences.shortVersion
        Task {
            let outcome = await UpdateCheck.run(appVersion: current)
            checking = false
            show(outcome, current: current)
        }
    }

    private func show(_ outcome: UpdateCheck.Outcome, current: String) {
        let alert = NSAlert()
        switch outcome {
        case .available(let version):
            alert.messageText = "Version \(version) is available"
            alert.informativeText = "You have \(current). The release page has the download and what changed."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "Version \(current) is the latest."
        case .failed:
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Try again later."
        }
        // A menu bar app is not active after its menu closes; without this
        // the alert opens behind the front app.
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, case .available(let version) = outcome {
            NSWorkspace.shared.open(UpdateCheck.releasePage(for: version))
        }
    }
}
