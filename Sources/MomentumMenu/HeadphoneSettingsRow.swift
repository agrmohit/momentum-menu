import M4Core
import SwiftUI

/// The rarely changed settings, folded into one row with a summary.
///
/// A button and a plain conditional rather than a DisclosureGroup: that
/// animates its own expansion, and the popover resizes on every frame of it,
/// which reads as the whole box juddering.
struct HeadphoneSettingsRow: View {
    @ObservedObject var controller: HeadphoneController
    @State private var isExpanded = false

    private var state: DeviceState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                    Text("Headphone")
                    Spacer()
                    if !isExpanded {
                        Text("Touch · Pause · Calls")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(DeviceSetting.allCases, id: \.self) { setting in
                        if let on = state.settings[setting] {
                            Divider()
                            settingToggle(setting, on: on)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .tile(padding: 11)
    }

    private func settingToggle(_ setting: DeviceSetting, on: Bool) -> some View {
        // Smart Pause and auto-answer act on the on-head sensor.
        let gated = setting.needsOnHead && state.settings[.onHeadDetection] == false
        // Label left, switch right, as System Settings rows are. A bare
        // Toggle outside a Form centres its label beside the switch.
        return HStack(spacing: 10) {
            Image(systemName: setting.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(setting.label)
            Spacer()
            Toggle(setting.label, isOn: Binding(
                get: { on },
                set: { value in Task { await controller.set(setting, on: value) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 7)
        .disabled(gated)
        .help(gated ? "Needs on-head detection" : setting.explanation)
    }
}

extension DeviceSetting {
    var symbol: String {
        switch self {
        case .touchControls: return "hand.tap"
        case .onHeadDetection: return "headphones.over.ear"
        case .smartPause: return "pause.circle"
        case .autoAnswer: return "phone.arrow.down.left"
        case .comfortCalls: return "phone.bubble"
        }
    }
}
