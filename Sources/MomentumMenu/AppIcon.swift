import AppKit

/// The app icons Settings offers. Starfield is the bundle's own icon; the
/// others are set on the bundle at runtime, as Finder's Get Info does.
///
/// macOS has no alternate-icon API, so a custom icon is NSWorkspace.setIcon:
/// an `Icon\r` file and a Finder attribute on the bundle. The code signature
/// still verifies, though `codesign --strict` objects to the attribute.
/// Clearing the icon removes both. Resources/AppIcon/render.sh draws the icons.
enum AppIcon: String, CaseIterable, Identifiable {
    case starfield = "G1"
    case sleepy = "Y1c"
    case ghost = "P3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starfield: return "Starfield"
        case .sleepy: return "Sleepy"
        case .ghost: return "Ghost"
        }
    }

    /// The icon as build.sh bundles it; nil when running outside the bundle,
    /// as from Xcode.
    var image: NSImage? {
        let name = self == .starfield ? "AppIcon" : "AppIcon-\(rawValue)"
        return Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// Shows this icon for the app in Finder, Spotlight and Login Items.
    func apply() throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw AppIconError.notBundled }
        // nil drops the custom icon, which brings back the bundled one.
        var icon: NSImage?
        if self != .starfield {
            guard let image else { throw AppIconError.missing(title) }
            icon = image
        }
        guard NSWorkspace.shared.setIcon(icon, forFile: bundle.path, options: []) else {
            throw AppIconError.refused(bundle.path)
        }
    }
}

enum AppIconError: LocalizedError {
    case notBundled
    case missing(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notBundled: return "The icon can only be changed in the built app, not when run from Xcode."
        case .missing(let title): return "The \(title) icon is missing from the app. Rebuild it with build.sh."
        case .refused(let path): return "macOS would not change the icon of \(path)."
        }
    }
}
