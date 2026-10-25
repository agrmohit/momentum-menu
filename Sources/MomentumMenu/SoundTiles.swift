import M4Core
import SwiftUI

/// The Equaliser tile: a menu of presets, checked when the device holds one,
/// with the per-band sliders one item away.
struct EqualiserTile: View {
    @ObservedObject var controller: HeadphoneController
    @Binding var showBands: Bool

    private var state: DeviceState { controller.state }
    private var active: EqPreset? { EqPreset.matching(state.bands.map(\.gainDb)) }

    /// A preset by name; nil while the device holds a hand-made curve, so no
    /// row is checked.
    private var selection: Binding<String?> {
        Binding(
            get: { active?.name },
            set: { name in
                guard let preset = EqPreset.all.first(where: { $0.name == name }) else { return }
                Task { await controller.apply(preset) }
            }
        )
    }

    var body: some View {
        Menu {
            Picker("Sennheiser", selection: selection) {
                ForEach(EqPreset.sennheiser) { Text($0.name).tag(Optional($0.name)) }
            }
            .pickerStyle(.inline)
            Picker("Our Own", selection: selection) {
                ForEach(EqPreset.own) { Text($0.name).tag(Optional($0.name)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button(showBands ? "Hide Custom Bands" : "Custom Bands…") { showBands.toggle() }
        } label: {
            SoundTileLabel(symbol: "waveform", colour: .pink, isOn: true,
                           title: state.equaliserSupported ? (active?.name ?? "Custom") : "Unavailable",
                           subtitle: state.needsFirmwareUpdateForEq ? "Needs firmware 3" : "Equaliser",
                           showsMenuIndicator: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!state.equaliserSupported)
    }
}

/// Bass Boost, tapped on and off. Hidden on firmware 2.x, which has none.
struct BassBoostTile: View {
    @ObservedObject var controller: HeadphoneController
    let isOn: Bool

    var body: some View {
        Button {
            Task { await controller.setBassBoost(!isOn) }
        } label: {
            SoundTileLabel(symbol: "hifispeaker", colour: .orange, isOn: isOn,
                           title: "Bass Boost", subtitle: isOn ? "On" : "Off",
                           showsMenuIndicator: false)
        }
        .buttonStyle(.plain)
    }
}

/// Icon on top, title and state below, as Control Center lays out a module.
private struct SoundTileLabel: View {
    let symbol: String
    let colour: Color
    let isOn: Bool
    let title: String
    let subtitle: String
    let showsMenuIndicator: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                TintedSymbol(name: symbol, colour: colour, isOn: isOn)
                Spacer()
                if showsMenuIndicator {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tile()
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
    }
}

/// The five band sliders, opened from the Equaliser menu. Each writes once,
/// on release: writing every 0.1 dB would flood the control channel.
struct EqualiserBands: View {
    @ObservedObject var controller: HeadphoneController
    /// What the sliders show while dragged, and until the device has the value.
    @State private var dragged: [Int: Double] = [:]
    /// Bands being dragged with the pointer.
    @State private var editing: Set<Int> = []
    /// A pending write for a keyboard or VoiceOver change, by band.
    @State private var keyWrites: [Int: Task<Void, Never>] = [:]

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.bands) { band in
                HStack(spacing: 8) {
                    Text(band.label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Slider(value: gain(band), in: state.eqMinGainDb...state.eqMaxGainDb, neutralValue: 0) {
                        Text("\(band.label) Hz")
                    } ticks: {
                        SliderTick(0)
                    } onEditingChanged: { isEditing in
                        if isEditing {
                            editing.insert(band.id)
                        } else {
                            editing.remove(band.id)
                            write(band)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .sensoryFeedback(.alignment, trigger: dragged[band.id]) { _, new in new == 0 }
                    Text(String(format: "%+.1f", dragged[band.id] ?? band.gainDb))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                }
            }
        }
        .tile()
    }

    private func gain(_ band: EqBand) -> Binding<Double> {
        snapping(Binding(
            get: { dragged[band.id] ?? band.gainDb },
            set: { value in
                dragged[band.id] = value
                // Keyboard and VoiceOver steps may arrive without editing
                // callbacks, so they are written once they settle.
                guard !editing.contains(band.id) else { return }
                keyWrites[band.id]?.cancel()
                keyWrites[band.id] = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    write(band)
                }
            }
        ), to: 0, within: 0.3)
    }

    /// Sends the shown value, and keeps showing it until the device has it,
    /// so the thumb does not jump back for a round trip.
    private func write(_ band: EqBand) {
        keyWrites[band.id]?.cancel()
        keyWrites[band.id] = nil
        // The device works in 0.1 dB steps.
        let db = ((dragged[band.id] ?? band.gainDb) * 10).rounded() / 10
        dragged[band.id] = db
        Task {
            await controller.setBandGain(band: band.id, db: db)
            // A newer drag of this band owns the value now.
            if dragged[band.id] == db, !editing.contains(band.id) { dragged[band.id] = nil }
        }
    }
}
