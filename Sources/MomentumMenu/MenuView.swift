import M4Core
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    @State private var pendingLevel: Double = 50
    @State private var showAdvanced = false

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if state.connected {
                Divider()
                noiseControl
                Divider()
                equaliser
                Divider()
                footer
            } else {
                disconnected
            }
        }
        .padding(14)
        .frame(width: 300)
        .task { pendingLevel = Double(state.noiseLevel ?? 50) }
        .onChange(of: state.noiseLevel) { _, new in
            if let new { pendingLevel = Double(new) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "headphones")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.deviceName ?? "MOMENTUM 4")
                    .font(.headline)
                if let battery = state.batteryPercent {
                    // Deliberately not red: red reads as a fault, and a low
                    // battery is a normal state, not a malfunction. Orange
                    // draws the eye without implying something is broken, and
                    // red stays reserved for actual errors.
                    Text("Battery \(battery)%")
                        .font(.caption)
                        .foregroundStyle(battery <= 20 ? .orange : .secondary)
                } else if state.connected {
                    Text("Battery unknown").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await controller.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var disconnected: some View {
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
                Button(state.releasedByUser ? "Reconnect" : "Try again") {
                    Task { await controller.connect(userInitiated: true) }
                }
                .disabled(state.isConnecting)
                Spacer()
                Button("Exit App") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    // MARK: - Noise control

    private var noiseControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOISE CONTROL").font(.caption2).foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { state.noiseMode ?? .off },
                set: { mode in Task { await controller.setNoiseMode(mode) } }
            )) {
                ForEach(NoiseMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if state.noiseMode == .custom {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $pendingLevel, in: 0...100, step: 1) { editing in
                        if !editing {
                            Task { await controller.setNoiseLevel(Int(pendingLevel)) }
                        }
                    }
                    HStack {
                        Text("Noise cancelling").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Transparency").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if let mode = state.noiseMode {
                Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Equaliser

    private var equaliser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EQUALISER").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let bass = state.bassBoost {
                    Toggle("Bass", isOn: Binding(
                        get: { bass },
                        set: { on in Task { await controller.setBassBoost(on) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            HStack(spacing: 4) {
                ForEach(state.equaliserSupported ? EqPreset.all : []) { preset in
                    Button {
                        Task { await controller.apply(preset) }
                    } label: {
                        Text(preset.name).font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(preset.verified
                          ? "Matches Sennheiser's own \(preset.name) curve"
                          : "Our own curve, not one of Sennheiser's presets")
                }
            }

            if state.bands.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if state.needsFirmwareUpdateForEq {
                        Text("Needs firmware 3.x")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("The equaliser and bass boost were added in firmware 3. "
                             + "You're on \(state.firmware ?? "2.x"). Update in Sennheiser's "
                             + "iPhone app — this app won't write firmware.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Equaliser not available on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                // Per-band parametric gains are not what most people want from
                // a menu bar: the presets are. Tucked away, but one click deep
                // rather than absent.
                DisclosureGroup(isExpanded: $showAdvanced) {
                    bandSliders.padding(.top, 6)
                } label: {
                    Text("Advanced Audio Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)
            }
        }
    }

    private var bandSliders: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.bands) { band in
                HStack(spacing: 8) {
                    Text(band.label)
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { band.gainDb },
                            set: { value in
                                Task { await controller.setBandGain(band: band.id, db: value) }
                            }
                        ),
                        in: state.eqMinGainDb...state.eqMaxGainDb, step: 0.5
                    )
                    Text(String(format: "%+.1f", band.gainDb))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let firmware = state.firmware {
                Text("Firmware \(firmware)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Disconnect") { controller.releaseHeadphones() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Disconnect from this Mac, freeing one of the headphones' "
                      + "two connection slots for another device. They stay paired, "
                      + "and this app won't reconnect until you ask it to.")
            Button("Exit App") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .overlay(alignment: .top) {
            if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -16)
            }
        }
    }
}
