import M4Core
import SwiftUI

/// Noise mode as three round buttons, then the level and anti-wind, which the
/// device honours only in Custom.
struct NoiseControlModule: View {
    @ObservedObject var controller: HeadphoneController
    @State private var pendingLevel: Double = 50

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(NoiseMode.allCases, id: \.self) { mode in
                    modeButton(mode)
                        .frame(maxWidth: .infinity)
                }
            }

            // Level and anti-wind only take effect in Custom. Hidden rather than
            // disabled elsewhere: a dimmed slider did not read as unavailable.
            if state.noiseMode == .custom {
                customControls
            } else if let mode = state.noiseMode {
                Text(mode == .off ? "Noise control is off." : "The headphones set the level for your surroundings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .tile()
        .task { pendingLevel = Double(state.noiseLevel ?? 50) }
        .onChange(of: state.noiseLevel) { _, new in
            if let new { pendingLevel = Double(new) }
        }
    }

    @ViewBuilder
    private var customControls: some View {
        Slider(value: snapping($pendingLevel, to: 50, within: 3), in: 0...100, neutralValue: 50) {
            Text("Noise level")
        } minimumValueLabel: {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.secondary)
                .help("Noise cancelling")
        } maximumValueLabel: {
            Image(systemName: "ear")
                .foregroundStyle(.secondary)
                .help("Transparency")
        } ticks: {
            SliderTick(50)
        } onEditingChanged: { editing in
            guard !editing else { return }
            Task { await controller.setNoiseLevel(Int(pendingLevel.rounded())) }
        }
        .labelsHidden()
        .sensoryFeedback(.alignment, trigger: pendingLevel) { _, new in new == 50 }

        if let antiWind = state.antiWind {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .foregroundStyle(.secondary)
                    .help("Anti-wind")
                Picker("Anti-wind", selection: Binding(
                    get: { antiWind },
                    set: { setting in
                        guard setting != antiWind else { return }
                        Task { await controller.setAntiWind(setting) }
                    }
                )) {
                    ForEach(AntiWind.shown, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .buttonSizing(.flexible)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func modeButton(_ mode: NoiseMode) -> some View {
        let isSelected = state.noiseMode == mode
        return VStack(spacing: 6) {
            // The same tinted wash as the tile icons. A bordered button's own
            // tint all but vanished on the popover's glass.
            Button {
                Task { await controller.setNoiseMode(mode) }
            } label: {
                TintedSymbol(name: mode.symbol, colour: .accentColor, isOn: isSelected, size: 46)
            }
            .buttonStyle(.plain)
            .contentShape(.circle)
            .help(mode.explanation)

            Text(mode.rawValue)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}

extension NoiseMode {
    var symbol: String {
        switch self {
        case .off: return "circle.slash"
        case .adaptive: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }
}
