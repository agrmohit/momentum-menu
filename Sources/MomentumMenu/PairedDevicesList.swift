import M4Core
import SwiftUI

/// The headphones' paired devices, opened from the line under the battery.
/// Each one not yet connected gets a Connect button while a slot is free.
struct PairedDevicesList: View {
    @ObservedObject var controller: HeadphoneController
    let devices: [PairedDevice]
    @ObservedObject private var preferences = Preferences.shared

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { offset, device in
                if offset > 0 { Divider() }
                row(device)
            }
            if state.connectionSlotsFull, devices.contains(where: { !$0.isConnected }) {
                Divider()
                Text("\(state.maxConnections ?? 2) of \(state.maxConnections ?? 2) devices connected. "
                     + (state.canDisconnectOthers
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

    private func row(_ device: PairedDevice) -> some View {
        HStack(spacing: 10) {
            let name = preferences.displayName(device.name, among: devices)
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
                // Other devices can only be let go on firmware that keeps
                // their pairing; this Mac can always hand over.
                let canDisconnect = device.isThisMac || state.canDisconnectOthers
                StatusPill(label: device.isThisMac ? "This Mac" : "Connected",
                           device: name,
                           canDisconnect: canDisconnect && state.pairedAction == nil) {
                    Task { await controller.disconnect(device) }
                }
                .help(canDisconnect ? "Disconnect" : "This firmware can't disconnect it from here")
            } else {
                let canConnect = !state.connectionSlotsFull && state.pairedAction == nil
                Button("Connect") {
                    Task { await controller.connect(to: device) }
                }
                .buttonStyle(PillStyle(colour: canConnect ? .blue : .secondary))
                .disabled(!canConnect)
                .accessibilityLabel("Connect \(name)")
            }
        }
        .padding(.vertical, 6)
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
