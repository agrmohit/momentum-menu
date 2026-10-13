import M4Core
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    @State private var pendingLevel: Double = 50
    @State private var showAdvanced = false

    /// What the sliders display, which is not always what the device holds.
    ///
    /// A Slider repaints at its new value rather than travelling to it, so a
    /// preset would blink into place however it was animated. These are stepped
    /// through the intermediate positions instead, which is what actually moves
    /// the knob.
    @State private var shownGains: [Double] = []
    @State private var tween: Task<Void, Never>?

    private func moveGains(to targets: [Double], animated: Bool) {
        tween?.cancel()
        guard animated, shownGains.count == targets.count, !shownGains.isEmpty else {
            shownGains = targets
            return
        }
        let start = shownGains
        tween = Task { @MainActor in
            let steps = 18                       // ~0.3s at 60fps
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)   // smoothstep, no abrupt start
                shownGains = zip(start, targets).map { $0 + ($1 - $0) * eased }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { shownGains = targets }
        }
    }

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
        .task {
            pendingLevel = Double(state.noiseLevel ?? 50)
            shownGains = state.bands.map(\.gainDb)
        }
        .onChange(of: state.noiseLevel) { _, new in
            if let new { pendingLevel = Double(new) }
        }
        .onChange(of: state.bands.map(\.gainDb)) { _, new in
            // Already there when the change came from dragging a slider.
            guard shownGains != new else { return }
            moveGains(to: new, animated: shownGains.count == new.count)
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
                    Text("Battery \(battery)%" + (state.isCharging == true ? " · Charging" : ""))
                        .font(.caption)
                        .foregroundStyle(state.isCharging == true ? .green
                                         : (battery <= 20 ? .orange : .secondary))
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

            // Hand-rolled rather than Picker(.segmented): that colours the
            // selection with the system accent, which renders gray if the user
            // has picked graphite.
            HStack(spacing: 0) {
                ForEach(NoiseMode.allCases, id: \.self) { mode in
                    let isSelected = (state.noiseMode ?? .off) == mode
                    Button {
                        Task { await controller.setNoiseMode(mode) }
                    } label: {
                        Text(mode.rawValue)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor : Color.clear)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(mode.explanation)
                }
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )

            if state.noiseMode == .custom {
                VStack(alignment: .leading, spacing: 2) {
                    // No `step:`. NSSlider draws a tick per step, so stepping
                    // by 1 over 0...100 covers the track in a hundred of them.
                    // Rounding happens on the way to the device instead.
                    Slider(value: $pendingLevel, in: 0...100) { editing in
                        if !editing {
                            Task { await controller.setNoiseLevel(Int(pendingLevel.rounded())) }
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
                        Text(preset.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)   // share the width evenly
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
                // Deliberately not a DisclosureGroup. That animates its own
                // expansion, so the content height changes on every frame of
                // the animation and the popover resizes to match each one —
                // which reads as the whole box juddering up and down rather
                // than a section opening. A plain button changes the layout
                // exactly once, and the transaction makes sure of it.
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Advanced Audio Settings").font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Always built, merely collapsed. Creating five slider-backed
                // views at click time is what made opening this feel slow;
                // they are cheap to keep and instant to reveal.
                bandSliders
                    .frame(height: showAdvanced ? nil : 0, alignment: .top)
                    .opacity(showAdvanced ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(showAdvanced)
                    .accessibilityHidden(!showAdvanced)
            }
        }
    }

    private var bandSliders: some View {
        // Keyed on the whole curve, so a preset slides every band together.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.bands) { band in
                HStack(spacing: 8) {
                    Text(band.label)
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { shownGain(band) },
                            set: { value in
                                // Track the drag locally; the device is told
                                // once, on release. Writing every 0.1 dB would
                                // flood the control channel.
                                tween?.cancel()
                                if shownGains.indices.contains(band.id) {
                                    shownGains[band.id] = value
                                }
                            }
                        ),
                        in: state.eqMinGainDb...state.eqMaxGainDb,
                        onEditingChanged: { editing in
                            guard !editing else { return }
                            // Snap to the device's own 0.1 dB granularity here
                            // rather than via `step:`, which would draw 120
                            // tick marks across the track.
                            let value = (shownGain(band) * 10).rounded() / 10
                            if shownGains.indices.contains(band.id) {
                                shownGains[band.id] = value
                            }
                            Task { await controller.setBandGain(band: band.id, db: value) }
                        }
                    )
                    // Five stacked rows: the full-size knob dwarfs them.
                    .controlSize(.small)
                    Text(String(format: "%+.1f", shownGain(band)))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func shownGain(_ band: EqBand) -> Double {
        shownGains.indices.contains(band.id) ? shownGains[band.id] : band.gainDb
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
