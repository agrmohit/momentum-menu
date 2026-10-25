import XCTest
@testable import M4Core
@testable import MomentumMenu

/// The icon a paired device gets from its name when none is chosen in
/// Settings. A guess: names the list misses fall back to a desktop.
final class DeviceKindTests: XCTestCase {

    private static let rows: [(name: String, kind: DeviceKind)] = [
        ("Name's iPhone", .phone),
        ("IPHONE 16", .phone),
        ("Pixel 9 Pro", .phone),
        ("Galaxy S25", .phone),
        ("OnePlus 12", .phone),
        ("Work phone", .phone),
        ("iPad Air", .tablet),
        ("Galaxy Tab S9", .tablet),
        ("Fire tablet", .tablet),
        ("MacBook Pro", .laptop),
        ("Mac mini", .laptop),
        ("Surface Book", .laptop),
        ("Dell laptop", .laptop),
        ("ThinkPad X1", .laptop),
        ("iMac", .desktop),
        ("Office PC", .desktop),
        ("", .desktop),
    ]

    func testTheGuessFollowsTheName() {
        for row in Self.rows {
            XCTAssertEqual(DeviceKind.guess(from: row.name), row.kind, row.name)
        }
    }
}

/// Stock names for screenshots: no real device name may show through.
@MainActor
final class DemoNameTests: XCTestCase {

    private static let devices = [
        PairedDevice(index: 0, name: "Name's S25", isConnected: true, isThisMac: false),
        PairedDevice(index: 1, name: "Name's MacBook", isConnected: true, isThisMac: true),
        PairedDevice(index: 2, name: "Home iPad", isConnected: false, isThisMac: false),
        PairedDevice(index: 3, name: "Desk PC", isConnected: false, isThisMac: false),
    ]

    func testEachDeviceGetsAStockName() {
        let rows: [(String, String)] = [
            ("Name's MacBook", "MacBook Pro"),
            ("Name's S25", "iPhone"),
            ("Home iPad", "iPad"),
            ("Desk PC", "Office PC"),
            ("Saved in Settings, not paired now", "Paired device"),
        ]
        for (real, shown) in rows {
            XCTAssertEqual(Preferences.demoName(for: real, among: Self.devices), shown, real)
        }
    }

    func testStockNamesWrapPastTheList() {
        let many = (0..<8).map { PairedDevice(index: $0, name: "Real \($0)", isConnected: false, isThisMac: false) }
        XCTAssertEqual(Preferences.demoName(for: "Real 6", among: many), "iPhone")
        XCTAssertEqual(Preferences.demoName(for: "Real 7", among: many), "iPad")
    }
}
