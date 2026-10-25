import M4Core
import SwiftUI

/// The popover: a battery header over Control Center-style modules.
struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    /// Opens the Settings window, which AppDelegate owns.
    let openSettings: () -> Void
    @State private var showBands = false

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(spacing: 10) {
            BatteryHeader(state: state) {
                Task { await controller.refresh() }
            }

            if state.connected {
                NoiseControlModule(controller: controller)

                HStack(spacing: 10) {
                    EqualiserTile(controller: controller, showBands: $showBands)
                    if let bass = state.bassBoost {
                        BassBoostTile(controller: controller, isOn: bass)
                    }
                }

                if showBands, !state.bands.isEmpty {
                    EqualiserBands(controller: controller)
                }

                if !state.settings.isEmpty {
                    HeadphoneSettingsRow(controller: controller)
                }

                if let error = state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer
            } else {
                DisconnectedPanel(controller: controller)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let firmware = state.firmware {
                Text("Firmware \(firmware)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                controller.releaseHeadphones()
            } label: {
                Image(systemName: "power")
            }
            .help("Disconnect from this Mac, freeing one of the headphones' two connection slots "
                  + "for another device. They stay paired, and this app won't reconnect until you ask.")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// The headphones inside a battery ring, with name, charge and stream.
private struct BatteryHeader: View {
    let state: DeviceState
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Gauge(value: Double(state.batteryPercent ?? 0), in: 0...100) {
                Text("Battery")
            } currentValueLabel: {
                Image(systemName: "headphones.over.ear")
                    .font(.system(size: 14, weight: .medium))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(ringColour)
            .scaleEffect(1.3)
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.deviceName ?? "MOMENTUM 4")
                    .font(.headline)
                if let battery = state.batteryPercent, state.connected {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        let number = Text("\(battery)").font(.system(size: 26, weight: .semibold, design: .rounded))
                        let unit = Text("%").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(number)\(unit)")
                            .monospacedDigit()
                        if let charge = state.chargeLabel {
                            Text(charge)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    Text(state.connected ? "Battery unknown" : "Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if state.connected, let codec = state.codecName {
                    HStack(spacing: 6) {
                        Text(codec)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: .capsule)
                        if let rate = state.sampleRateLabel {
                            Text(rate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("What the headphones are playing, from whichever device")
                }
            }

            Spacer(minLength: 0)

            if state.connected {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Refresh")
            }
        }
    }

    /// Deliberately not red when low: red reads as a fault, and a low battery
    /// is a normal state. Orange draws the eye without implying breakage.
    private var ringColour: Color {
        guard state.connected else { return .secondary }
        if state.isCharging == true { return .green }
        return (state.batteryPercent ?? 100) <= 20 ? .orange : .green
    }
}

/// Shown while connecting, after a hand-off, or when the headphones are away.
private struct DisconnectedPanel: View {
    @ObservedObject var controller: HeadphoneController

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
                Text("Opening the control channel. This can take a few seconds, "
                     + "especially just after the headphones wake up.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.releasedByUser {
                Text("Handed over").font(.callout).foregroundStyle(.secondary)
                Text("This Mac has let go of the headphones, so another device "
                     + "can use that slot. They'll stay released until you reconnect.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.lastError ?? "Not connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The headphones must be paired and switched on.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button(state.releasedByUser ? "Reconnect" : "Try Again") {
                    Task { await controller.connect(userInitiated: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isConnecting)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.bordered)
            }
        }
        .tile()
    }
}
