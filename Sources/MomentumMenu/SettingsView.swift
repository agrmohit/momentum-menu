import SwiftUI

/// The Settings window, laid out as a System Settings pane: a grouped form
/// whose rows carry a coloured symbol badge.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: $preferences.launchAtLogin) {
                    Label { Text("Launch at Login") } icon: { Badge("power", .gray) }
                }
                if let error = preferences.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle(isOn: $preferences.showBatteryPercentage) {
                    Label { Text("Battery Percentage in Menu Bar") } icon: { Badge("battery.75percent", .green) }
                }
                Toggle(isOn: $preferences.hideMenuBarIcon) {
                    Label {
                        Text("Hide Menu Bar Icon")
                        // The icon is the only way in; reopening the app leads here.
                        if preferences.hideMenuBarIcon {
                            Text("Open MomentumMenu again to come back here.")
                        }
                    } icon: { Badge("menubar.rectangle", .blue) }
                }
            }

            Section("About") {
                LabeledContent {
                    Text("Version \(Preferences.displayVersion)")
                        .textSelection(.enabled)
                } label: {
                    Label {
                        Text("MomentumMenu")
                        Text("Unofficial. Not affiliated with Sennheiser or Sonova.")
                    } icon: { Badge("headphones.over.ear", .indigo) }
                }
                Link(destination: Preferences.repository) {
                    Label { Text("github.com/agrmohit/momentum-menu") } icon: { Badge("link", .gray) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A white SF Symbol on a coloured rounded square, as System Settings marks
/// its rows.
private struct Badge: View {
    let symbol: String
    let colour: Color

    init(_ symbol: String, _ colour: Color) {
        self.symbol = symbol
        self.colour = colour
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(colour.gradient, in: .rect(cornerRadius: 5))
    }
}
