import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            general
            Divider()
            updatesSection
            Divider()
            about
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: - General

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GENERAL").font(.caption2).foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            if let error = preferences.launchAtLoginError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Hide menu bar icon", isOn: $preferences.hideMenuBarIcon)
            if preferences.hideMenuBarIcon {
                Text("The icon is how you reach this app. With it hidden, opening "
                     + "Momentum Menu again brings you straight back to this window.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UPDATES").font(.caption2).foregroundStyle(.secondary)

            Toggle("Check for updates automatically", isOn: $preferences.automaticUpdateChecks)
            Text("Checks GitHub once a day for a newer published release.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Check Now") { Task { await updates.check() } }
                    .controlSize(.small)
                    .disabled(updates.status == .checking)

                if case .updateAvailable = updates.status {
                    Button("Open Releases") {
                        if let url = URL(string: "https://github.com/\(UpdateChecker.repository)/releases") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Text(updates.status.message)
                .font(.caption2)
                .foregroundStyle(isProblem ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let checked = updates.lastChecked {
                Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var isProblem: Bool {
        if case .unavailable = updates.status { return true }
        return false
    }

    // MARK: - About

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ABOUT").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Momentum Menu").font(.callout.weight(.medium))
                Spacer()
                Text("Version \(Preferences.displayVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Unofficial. Not affiliated with Sennheiser or Sonova.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("View on GitHub") {
                if let url = URL(string: "https://github.com/\(UpdateChecker.repository)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}
