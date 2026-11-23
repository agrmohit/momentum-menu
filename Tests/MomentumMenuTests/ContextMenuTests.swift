import AppKit
import XCTest
@testable import MomentumMenu

/// The right-click menu enables only what can run now. `menu.update()` is
/// what AppKit calls before showing it, so auto-enabling would override
/// these flags here as it does on screen.
@MainActor
final class ContextMenuTests: XCTestCase {

    private struct Row {
        let name: String
        let connected: Bool
        let checking: Bool
        let enabled: [String: Bool]
        let updateTitle: String
    }

    private static let rows: [Row] = [
        Row(name: "connected, idle", connected: true, checking: false,
            enabled: ["Settings…": true, "Check for Updates…": true, "Refresh": true, "Disconnect": true],
            updateTitle: "Check for Updates…"),
        Row(name: "disconnected, idle", connected: false, checking: false,
            enabled: ["Settings…": true, "Check for Updates…": true, "Refresh": false, "Disconnect": false],
            updateTitle: "Check for Updates…"),
        Row(name: "connected, checking", connected: true, checking: true,
            enabled: ["Settings…": true, "Checking for Updates…": false, "Refresh": true, "Disconnect": true],
            updateTitle: "Checking for Updates…"),
        Row(name: "disconnected, checking", connected: false, checking: true,
            enabled: ["Settings…": true, "Checking for Updates…": false, "Refresh": false, "Disconnect": false],
            updateTitle: "Checking for Updates…"),
    ]

    func testItemsAreEnabledOnlyWhenTheyCanRun() {
        for row in Self.rows {
            let menu = AppDelegate.contextMenu(target: NSObject(), connected: row.connected,
                                               checkingForUpdates: row.checking)
            menu.update()
            for (title, enabled) in row.enabled {
                XCTAssertEqual(menu.item(withTitle: title)?.isEnabled, enabled, "\(row.name): \(title)")
            }
        }
    }

    func testTheUpdateItemSitsUnderSettings() {
        for row in Self.rows {
            let menu = AppDelegate.contextMenu(target: NSObject(), connected: row.connected,
                                               checkingForUpdates: row.checking)
            XCTAssertEqual(menu.items.prefix(2).map(\.title), ["Settings…", row.updateTitle], row.name)
        }
    }
}
