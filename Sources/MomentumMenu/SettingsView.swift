import M4Core
import SwiftUI

/// The Settings window, laid out as a System Settings pane: a grouped form
/// whose rows carry a coloured symbol badge.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: HeadphoneController

    /// The headphones' devices in their order, then any named earlier that
    /// are not in the list now, so a choice can still be undone.
    private var deviceNames: [String] {
        let paired = (controller.state.pairedDevices ?? []).map(\.name).filter { !$0.isEmpty }
        let saved = preferences.deviceKinds.keys.filter { !paired.contains($0) }.sorted()
        var seen = Set<String>()
        return (paired + saved).filter { seen.insert($0).inserted }
    }

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
                            Text("Open Momentum Menu again to come back here.")
                        }
                    } icon: { Badge("menubar.rectangle", .blue) }
                }
                LabeledContent {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(AppIcon.allCases) { icon in
                            IconChoice(icon: icon, isSelected: preferences.appIcon == icon) {
                                preferences.appIcon = icon
                            }
                        }
                    }
                } label: {
                    Label {
                        Text("App Icon")
                        Text("Shown in Finder, Spotlight and Login Items.")
                    } icon: { Badge("app.badge", .purple) }
                }
                if let error = preferences.appIconError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if deviceNames.isEmpty {
                    Text("Connect the headphones to list the devices paired with them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(deviceNames, id: \.self) { name in
                    let devices = controller.state.pairedDevices
                    let shown = preferences.displayName(name, among: devices)
                    Picker(selection: kindBinding(for: name)) {
                        Text("Automatic (\(DeviceKind.guess(from: shown).title))").tag(DeviceKind?.none)
                        Divider()
                        ForEach(DeviceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(DeviceKind?.some(kind))
                        }
                    } label: {
                        Label { Text(shown) } icon: {
                            Badge(preferences.displayKind(name, among: devices).symbol, .blue)
                        }
                    }
                }
            } header: {
                Text("Paired Devices")
            } footer: {
                Text("Icons are guessed from each device's name. Choose one where the guess is wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent {
                    Text("Version \(Preferences.displayVersion)")
                        .textSelection(.enabled)
                } label: {
                    Label {
                        Text("Momentum Menu")
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

    /// Automatic (nil) removes the stored choice.
    private func kindBinding(for name: String) -> Binding<DeviceKind?> {
        Binding(get: { preferences.deviceKinds[name] },
                set: { preferences.deviceKinds[name] = $0 })
    }
}

/// One icon to pick, as System Settings > Appearance shows its icon styles:
/// the icon, a ring when chosen, and its name underneath.
private struct IconChoice: View {
    let icon: AppIcon
    let isSelected: Bool
    let choose: () -> Void

    /// The canvas the icon is drawn on. The visible squircle is 824/1024 of
    /// it, as on Apple's icon grid, and its corner radius 185/824 of that.
    private let canvas: CGFloat = 60
    private var tile: CGFloat { canvas * 824 / 1024 }
    private var corner: CGFloat { tile * 185 / 824 }

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                artwork
                    .frame(width: canvas, height: canvas)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .frame(width: tile + 9, height: tile + 9)
                        }
                    }
                Text(icon.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(icon.title) icon")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var artwork: some View {
        let squircle = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if let image = icon.image {
            if icon == .starfield {
                // The bundled icon is a full-bleed square that macOS rounds
                // itself; the others carry their own squircle.
                Image(nsImage: image)
                    .resizable()
                    .frame(width: tile, height: tile)
                    .clipShape(squircle)
            } else {
                Image(nsImage: image).resizable()
            }
        } else {
            // Run outside the bundle, as from Xcode: no icons to show.
            squircle.fill(.quaternary).frame(width: tile, height: tile)
        }
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
