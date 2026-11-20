import M4Core
import SwiftUI

/// The headphones' paired devices, opened from the line under the battery.
/// Each one not yet connected gets a Connect button while a slot is free.
/// Right-click offers Forget, confirmed in the row: an alert would take
/// focus and close the popover.
struct PairedDevicesList: View {
    @ObservedObject var controller: HeadphoneController
    let devices: [PairedDevice]
    @ObservedObject private var preferences = Preferences.shared
    /// Awaiting a yes. Compared whole, so a re-read that changes it closes it.
    @State private var confirmingForget: PairedDevice?

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { offset, device in
                if offset > 0 { Divider() }
                let name = preferences.displayName(device.name, among: devices)
                if confirmingForget == device {
                    forgetConfirmation(device, name: name)
                } else {
                    row(device, name: name)
                }
            }
            if state.connectionSlotsFull, devices.contains(where: { !$0.isConnected }) {
                Divider()
                Text("\(state.maxConnections ?? 2) of \(state.maxConnections ?? 2) devices connected. "
                     + (state.canChangePairings
                        ? "Disconnect one to connect another."
                        : "Disconnect one on that device to connect another."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
        }
        .tile(padding: 11)
    }

    private func row(_ device: PairedDevice, name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: preferences.displayKind(device.name, among: devices).symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name.isEmpty ? "Unnamed device" : name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if state.pairedAction?.deviceName == device.name {
                ProgressView().controlSize(.small)
            } else if device.isConnected {
                StatusPill(label: device.isThisMac ? "This Mac" : "Connected",
                           device: name,
                           canDisconnect: state.canDisconnect(device)) {
                    Task { await controller.disconnect(device) }
                }
                // This Mac can always hand over; others need the tested firmware.
                .help(device.isThisMac || state.canChangePairings
                      ? "Disconnect" : "This firmware can't disconnect it from here")
            } else {
                let canConnect = state.canConnect(device)
                Button("Connect") {
                    Task { await controller.connect(to: device) }
                }
                .buttonStyle(PillStyle(colour: canConnect ? .blue : .secondary))
                .disabled(!canConnect)
                .accessibilityLabel("Connect \(name)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .contextMenu { menu(device, name: name) }
    }

    /// The row's pill action, then Forget.
    @ViewBuilder
    private func menu(_ device: PairedDevice, name: String) -> some View {
        if device.isConnected {
            Button("Disconnect") { Task { await controller.disconnect(device) } }
                .disabled(!state.canDisconnect(device))
        } else {
            Button("Connect") { Task { await controller.connect(to: device) } }
                .disabled(!state.canConnect(device))
        }
        Divider()
        Button("Forget \u{201C}\(name)\u{201D}\u{2026}", role: .destructive) { confirmingForget = device }
            .disabled(!state.canForget(device))
    }

    /// Replaces the row until answered. Forget closes it at once, so the
    /// row's spinner shows while the controller works.
    private func forgetConfirmation(_ device: PairedDevice, name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Forget \u{201C}\(name)\u{201D}?")
                .font(.callout.weight(.semibold))
            Text("The headphones will no longer know it. To use them on \(name) again, pair from scratch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { confirmingForget = nil }
                    .buttonStyle(PillStyle(colour: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Forget") {
                    confirmingForget = nil
                    Task {
                        if await controller.forget(device) { preferences.forgetKind(of: device.name) }
                    }
                }
                .buttonStyle(PillStyle(colour: .red))
                .disabled(!state.canForget(device))
                .accessibilityLabel("Forget \(name)")
            }
            .padding(.top, 6)
        }
        .padding(8)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, -6)
        .padding(.vertical, 4)
    }
}

/// "Connected" in a green pill that turns into a red "Disconnect" under
/// the pointer. Keyboard and VoiceOver users get it as a Disconnect button.
private struct StatusPill: View {
    let label: String
    let device: String
    let canDisconnect: Bool
    let disconnect: () -> Void
    @State private var hovering = false

    private var armed: Bool { hovering && canDisconnect }

    var body: some View {
        Button(action: disconnect) {
            // Both words laid out, one shown, so the pill keeps its width.
            ZStack {
                Text(label).opacity(armed ? 0 : 1)
                Text("Disconnect").opacity(armed ? 1 : 0)
            }
        }
        .buttonStyle(PillStyle(colour: armed ? .red : .green))
        .disabled(!canDisconnect)
        .onHover { hovering = $0 }
        .accessibilityLabel(canDisconnect ? "Disconnect \(device)" : "\(device), \(label)")
    }
}

/// Coloured text on a capsule of the same colour, as the charging pill is
/// drawn. Its own style rather than `.plain` or `.bordered`, which both
/// dimmed the label in the popover.
private struct PillStyle: ButtonStyle {
    let colour: Color

    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, colour: colour, pressed: configuration.isPressed)
    }

    /// A view, so it can read whether the button is enabled: a ButtonStyle
    /// cannot. Disabled pills fade.
    private struct Pill: View {
        let label: Configuration.Label
        let colour: Color
        let pressed: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .font(.caption.weight(.semibold))
                .foregroundStyle(colour)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(colour.opacity(pressed ? 0.4 : 0.25), in: .capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// What a paired device is, for its icon. The headphones report only a
/// name, so this is guessed from it unless chosen in Settings.
enum DeviceKind: String, CaseIterable, Identifiable {
    case phone, tablet, laptop, desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: return "Phone"
        case .tablet: return "Tablet"
        case .laptop: return "Laptop"
        case .desktop: return "Desktop"
        }
    }

    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        }
    }

    static func guess(from name: String) -> DeviceKind {
        let name = name.lowercased()
        // Tablets first: "Galaxy Tab" would otherwise read as a phone.
        if ["ipad", "tablet", "galaxy tab"].contains(where: name.contains) { return .tablet }
        if ["iphone", "phone", "pixel", "galaxy", "oneplus"].contains(where: name.contains) { return .phone }
        if name.contains("imac") { return .desktop }
        if ["mac", "book", "laptop", "thinkpad"].contains(where: name.contains) { return .laptop }
        return .desktop
    }
}
