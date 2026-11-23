import AppKit
import XCTest
@testable import MomentumMenu

/// The right-click menu enables only what can run now. `menu.update()` is
/// what AppKit calls before showing it, so auto-enabling would override
/// these flags here as it does on screen.
@MainActor
final class ContextMenuTests: XCTestCase {

    func testItemsAreEnabledOnlyWhenTheyCanRun() {
        let rows: [(String, Bool, [String: Bool])] = [
            ("connected", true, ["Settings…": true, "Refresh": true, "Disconnect": true]),
            ("disconnected", false, ["Settings…": true, "Refresh": false, "Disconnect": false]),
        ]
        for (name, connected, enabled) in rows {
            let menu = AppDelegate.contextMenu(target: NSObject(), connected: connected)
            menu.update()
            for (title, isEnabled) in enabled {
                XCTAssertEqual(menu.item(withTitle: title)?.isEnabled, isEnabled, "\(name): \(title)")
            }
        }
    }
}
