import Foundation
import M4Core
import ServiceManagement

/// User preferences, backed by UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let showBatteryPercentage = "showBatteryPercentage"
        static let appIcon = "appIcon"
        static let deviceKinds = "deviceKinds"
        static let demoDeviceNames = "demoDeviceNames"
    }

    private let defaults = UserDefaults.standard
    private var isApplyingLoginItem = false

    /// Set by AppDelegate so the status item can follow the preference.
    var onMenuBarIconVisibilityChanged: ((Bool) -> Void)?
    /// Set by AppDelegate to redraw the status item.
    var onBatteryPercentageVisibilityChanged: (() -> Void)?

    /// Why registering the login item failed, if it did. Ad-hoc signed apps
    /// are sometimes refused, and the user deserves the reason rather than a
    /// toggle that silently springs back.
    @Published var launchAtLoginError: String?

    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }

    @Published var hideMenuBarIcon: Bool {
        didSet {
            defaults.set(hideMenuBarIcon, forKey: Key.hideMenuBarIcon)
            onMenuBarIconVisibilityChanged?(!hideMenuBarIcon)
        }
    }

    /// Off by default: the battery bar already shows the level.
    @Published var showBatteryPercentage: Bool {
        didSet {
            defaults.set(showBatteryPercentage, forKey: Key.showBatteryPercentage)
            onBatteryPercentageVisibilityChanged?()
        }
    }

    /// Why the app icon could not be changed, if it could not.
    @Published var appIconError: String?

    @Published var appIcon: AppIcon {
        didSet {
            defaults.set(appIcon.rawValue, forKey: Key.appIcon)
            applyAppIcon()
        }
    }

    /// Device types chosen in Settings, by paired-device name: the only
    /// identity the headphones report. Missing means guess from the name.
    @Published var deviceKinds: [String: DeviceKind] {
        didSet { defaults.set(deviceKinds.mapValues(\.rawValue), forKey: Key.deviceKinds) }
    }

    func kind(of name: String) -> DeviceKind {
        deviceKinds[name] ?? .guess(from: name)
    }

    /// Stock names in place of real ones, for screenshots. Set with
    /// `defaults write com.agrmohit.momentummenu demoDeviceNames -bool YES` and
    /// read at launch; no Settings row, so it is not left on by accident.
    let demoDeviceNames: Bool

    private static let demoNames = ["iPhone", "iPad", "Office PC", "Pixel 9", "ThinkPad", "Galaxy Tab"]

    /// The name to show for a paired device. With demo names on, this Mac
    /// is "MacBook Pro" and the others take stock names in list order.
    func displayName(_ name: String, among devices: [PairedDevice]?) -> String {
        demoDeviceNames ? Self.demoName(for: name, among: devices ?? []) : name
    }

    static func demoName(for name: String, among devices: [PairedDevice]) -> String {
        if devices.first(where: { $0.name == name })?.isThisMac == true { return "MacBook Pro" }
        let others = devices.filter { !$0.isThisMac }.map(\.name)
        guard let position = others.firstIndex(of: name) else { return "Paired device" }
        return demoNames[position % demoNames.count]
    }

    /// The icon to show: in demo mode, the stock name's, so a chosen kind
    /// cannot hint at the real device.
    func displayKind(_ name: String, among devices: [PairedDevice]?) -> DeviceKind {
        demoDeviceNames ? .guess(from: displayName(name, among: devices)) : kind(of: name)
    }

    /// `text` with every real device name replaced, for errors that quote one.
    func masked(_ text: String, among devices: [PairedDevice]?) -> String {
        guard demoDeviceNames else { return text }
        return (devices ?? []).reduce(text) { $0.replacingOccurrences(of: $1.name, with: displayName($1.name, among: devices)) }
    }

    /// Puts a chosen custom icon back after a reinstall, which replaces the
    /// bundle and the icon with it. The bundled icon needs nothing.
    func reapplyAppIcon() {
        if appIcon != .starfield { applyAppIcon() }
    }

    private func applyAppIcon() {
        do {
            try appIcon.apply()
            appIconError = nil
        } catch {
            appIconError = error.localizedDescription
        }
    }

    private init() {
        // The login item is the system's state, not ours: it can be revoked in
        // System Settings > General > Login Items without telling us. Read it
        // rather than trusting what we last wrote.
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hideMenuBarIcon = defaults.bool(forKey: Key.hideMenuBarIcon)
        showBatteryPercentage = defaults.bool(forKey: Key.showBatteryPercentage)
        appIcon = defaults.string(forKey: Key.appIcon).flatMap(AppIcon.init(rawValue:)) ?? .starfield
        let stored = defaults.dictionary(forKey: Key.deviceKinds) as? [String: String] ?? [:]
        deviceKinds = stored.compactMapValues(DeviceKind.init(rawValue:))
        demoDeviceNames = defaults.bool(forKey: Key.demoDeviceNames)
    }

    private func applyLaunchAtLogin() {
        guard !isApplyingLoginItem else { return }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            // Snap the toggle back to what the system actually thinks, without
            // re-entering this method.
            isApplyingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isApplyingLoginItem = false
        }
    }

    static let repository = URL(string: "https://github.com/agrmohit/momentum-menu")!

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    static var displayVersion: String {
        shortVersion == build ? shortVersion : "\(shortVersion) (\(build))"
    }
}
