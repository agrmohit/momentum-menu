import Foundation
import ServiceManagement

/// User preferences, backed by UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let showBatteryPercentage = "showBatteryPercentage"
        static let appIcon = "appIcon"
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

    /// This fork; upstream is andr3-santos/momentum-menu.
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
