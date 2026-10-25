import M4Core
import SwiftUI

/// The popover: a battery header over Control Center-style modules.
struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    /// Opens the Settings window, which AppDelegate owns.
    let openSettings: () -> Void
    @State private var showBands = false
    @State private var showDevices = false

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(spacing: 10) {
            BatteryHeader(state: state, devicesShown: showDevices, refresh: {
                Task { await controller.refresh() }
            }, toggleDevices: {
                // No animation, as in HeadphoneSettingsRow: the popover
                // resizes on every frame of one.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showDevices.toggle() }
                if showDevices { Task { await controller.refreshPairedDevices() } }
            })

            if state.connected {
                if showDevices, let devices = state.pairedDevices {
                    PairedDevicesList(controller: controller, devices: devices)
                }

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
                    Text(Preferences.shared.masked(error, among: state.pairedDevices))
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
            .accessibilityLabel("Settings")
            Button {
                controller.releaseHeadphones()
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("Disconnect")
            .help("Disconnect from this Mac, freeing one of the headphones' two connection slots "
                  + "for another device. They stay paired, and this app won't reconnect until you ask.")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// The headphones inside a battery ring, with name, charge, stream and the
/// other connected devices.
private struct BatteryHeader: View {
    let state: DeviceState
    let devicesShown: Bool
    let refresh: () -> Void
    let toggleDevices: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onCable: Bool { state.connected && state.isCharging == true }
    /// Charging and not yet full: the only state that animates.
    private var breathing: Bool { onCable && !state.isFullyCharged && !reduceMotion }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            batteryRing

            VStack(alignment: .leading, spacing: 3) {
                // The headphones' own name can be personal too.
                Text(Preferences.shared.demoDeviceNames ? "MOMENTUM 4" : state.deviceName ?? "MOMENTUM 4")
                    .font(.headline)
                    .padding(.trailing, 34)   // clear of the Refresh button
                if let battery = state.batteryPercent, state.connected {
                    let number = Text("\(battery)").font(.system(size: 26, weight: .semibold, design: .rounded))
                    let unit = Text("%").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(number)\(unit)")
                        .monospacedDigit()
                } else {
                    Text(state.connected ? "Battery unknown" : "Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if state.connected, state.chargeLabel != nil || state.codecName != nil {
                    HStack(spacing: 6) {
                        if let charge = state.chargeLabel {
                            Text("\(Image(systemName: "bolt.fill")) \(charge)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.18), in: .capsule)
                        }
                        if let codec = state.codecName {
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
                                        .lineLimit(1)
                                }
                            }
                            .help("What the headphones are playing, from whichever device")
                        }
                    }
                }
                if state.connected, let summary = state.pairedSummary {
                    devicesLine(Preferences.shared.masked(summary, among: state.pairedDevices))
                }
            }

            Spacer(minLength: 0)
        }
        // An overlay, so the charging pill and codec line can run under it.
        .overlay(alignment: .topTrailing) {
            if state.connected {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Refresh")
            }
        }
    }

    /// "Also on iPhone", opening the paired-device list below the header.
    private func devicesLine(_ summary: String) -> some View {
        Button(action: toggleDevices) {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer.and.iphone")
                Text(summary).lineLimit(1).truncationMode(.tail)
                if state.pairedAction != nil { ProgressView().controlSize(.mini) }
                Image(systemName: devicesShown ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Devices paired with the headphones")
        .accessibilityLabel("Paired devices: \(summary)")
        .accessibilityHint(devicesShown ? "Hides the list" : "Shows the list")
    }

    /// Red at 20% and under, as the iPhone's battery shows it.
    private var ringColour: Color {
        guard state.connected else { return .secondary }
        if state.isCharging == true { return .green }
        return (state.batteryPercent ?? 100) <= 20 ? .red : .green
    }

    /// The ring, breathing while it charges.
    ///
    /// One clock value drives both the bolt and the halo, so they glow in
    /// step. It is computed per frame rather than animated: a
    /// `phaseAnimator`'s animation also caught the popover's first layout, and
    /// the ring flew in from the corner each time the popover opened.
    @ViewBuilder
    private var batteryRing: some View {
        if breathing {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                // 0...1 and back, once every 3 s.
                ring(glow: (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.5) + 1) / 2)
            }
        } else {
            ring(glow: onCable ? 0.7 : nil)
        }
    }

    /// `glow`: 0 dim ... 1 bright; nil for no glow at all (on battery).
    private func ring(glow: Double?) -> some View {
        let bright = glow ?? 0
        return Group {
            if state.connected, (state.batteryPercent ?? 0) >= 100 {
                // At 100% the Gauge still draws its arc's end cap, a notch at
                // 12 o'clock. A plain circle of the same size has no seam.
                ZStack {
                    Circle().strokeBorder(ringColour, lineWidth: FullRing.lineWidth)
                    ringLabel(bright: bright)
                }
                .frame(width: FullRing.diameter, height: FullRing.diameter)
            } else {
                Gauge(value: Double(state.batteryPercent ?? 0), in: 0...100) {
                    Text("Battery")
                } currentValueLabel: {
                    ringLabel(bright: bright)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(ringColour)
            }
        }
        .scaleEffect(1.3)
        .frame(width: 70, height: 70)
        .shadow(color: .green.opacity(glow == nil ? 0 : 0.15 + 0.25 * bright), radius: 2 + 3 * bright)
    }

    @ViewBuilder
    private func ringLabel(bright: Double) -> some View {
        if onCable {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .opacity(0.75 + 0.25 * bright)
                .scaleEffect(0.96 + 0.04 * bright)
                .shadow(color: .green.opacity(0.4 * bright), radius: 2 * bright)
        } else {
            Image(systemName: "headphones.over.ear")
                .font(.system(size: 14, weight: .medium))
        }
    }

    /// The `.accessoryCircularCapacity` Gauge's ring, in points before the
    /// 1.3x scale; measured from a render on macOS 26.
    private enum FullRing {
        static let diameter: CGFloat = 58.5
        static let lineWidth: CGFloat = 6.2
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
                Text("Disconnected").font(.callout).foregroundStyle(.secondary)
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
