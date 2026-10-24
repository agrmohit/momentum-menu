import XCTest
@testable import M4Core

/// Which frames may leave the Mac at all.
///
/// Regression: safety was a deny-list. Community catalogues name factory reset
/// (0x0040), firmware upgrade (0x0200), pairing deletes (0x1405, 0x1406) and
/// MMI reset (0x1604), none of which it blocked.
final class AllowListTests: XCTestCase {

    private struct Row {
        let name: String
        let command: UInt16
        let payload: [UInt8]
        let allowed: Bool
    }

    private static let rows: [Row] = [
        // Reads the app makes, in both payload forms --diagnose uses.
        Row(name: "battery read", command: Cmd.getBattery, payload: [], allowed: true),
        Row(name: "all gains read with its dummy byte", command: Cmd.getAllGains, payload: [0], allowed: true),
        Row(name: "band frequency read", command: Cmd.getBandFrequency, payload: [4], allowed: true),
        Row(name: "touch controls read", command: Cmd.getTouchControls, payload: [], allowed: true),
        Row(name: "a read with two bytes", command: Cmd.getBattery, payload: [0, 0], allowed: false),
        // Writes the app makes, at their limits.
        Row(name: "ANC off", command: Cmd.setAncEnabled, payload: [0], allowed: true),
        Row(name: "ANC on", command: Cmd.setAncEnabled, payload: [1], allowed: true),
        Row(name: "ANC with an unknown value", command: Cmd.setAncEnabled, payload: [2], allowed: false),
        Row(name: "ANC with no value", command: Cmd.setAncEnabled, payload: [], allowed: false),
        Row(name: "noise level 0", command: Cmd.setNoiseLevel, payload: [0], allowed: true),
        Row(name: "noise level 100", command: Cmd.setNoiseLevel, payload: [100], allowed: true),
        Row(name: "noise level 101", command: Cmd.setNoiseLevel, payload: [101], allowed: false),
        Row(name: "band gain, last band", command: Cmd.setBandGain, payload: [15, 0x3C], allowed: true),
        Row(name: "band gain, band 16", command: Cmd.setBandGain, payload: [16, 0], allowed: false),
        Row(name: "band gain without the gain", command: Cmd.setBandGain, payload: [2], allowed: false),
        Row(name: "bass on", command: Cmd.setBassBoost, payload: [1], allowed: true),
        Row(name: "bass with an unknown value", command: Cmd.setBassBoost, payload: [7], allowed: false),
        Row(name: "adaptive pair", command: Cmd.setModeTable, payload: [3, 1], allowed: true),
        Row(name: "full mode table", command: Cmd.setModeTable, payload: [1, 2, 2, 0, 3, 1], allowed: true),
        Row(name: "mode table cut short", command: Cmd.setModeTable, payload: [1, 0, 2, 0], allowed: false),
        Row(name: "mode table with ids out of order", command: Cmd.setModeTable,
            payload: [3, 1, 1, 0, 2, 0], allowed: false),
        Row(name: "pair for a mode the app never writes", command: Cmd.setModeTable, payload: [1, 2], allowed: false),
        Row(name: "subscribe to battery", command: Cmd.registerNotification, payload: [3], allowed: true),
        Row(name: "subscribe to an unknown feature", command: Cmd.registerNotification, payload: [20], allowed: false),
        // Documented elsewhere as dangerous; never sent by the app.
        Row(name: "factory reset", command: 0x0040, payload: [], allowed: false),
        Row(name: "firmware upgrade enable", command: 0x0200, payload: [], allowed: false),
        Row(name: "delete a paired device", command: 0x1405, payload: [0], allowed: false),
        Row(name: "delete the pairing list", command: 0x1406, payload: [], allowed: false),
        Row(name: "reset button mapping", command: 0x1604, payload: [], allowed: false),
        Row(name: "link-killing id from the sweeps", command: 0x0607, payload: [], allowed: false),
        Row(name: "charger getter in the power group", command: 0x0602, payload: [], allowed: false),
        Row(name: "a getter with its type bits set", command: Cmd.getBattery | 0x0080, payload: [], allowed: false),
    ]

    func testOnlyListedCommandsAndPayloadsPass() {
        for row in Self.rows {
            let reason = CommandSafety.rejectionReason(for: row.command, payload: row.payload)
            XCTAssertEqual(reason == nil, row.allowed, "\(row.name): \(reason ?? "allowed")")
        }
    }

    private struct WireRow {
        let name: String
        let command: UInt16
        let payload: [UInt8]
        let reachesWire: Bool
    }

    private static let wireRows: [WireRow] = [
        WireRow(name: "allowed write", command: Cmd.setNoiseLevel, payload: [100], reachesWire: true),
        WireRow(name: "allowed read", command: Cmd.getBattery, payload: [], reachesWire: true),
        WireRow(name: "out-of-range write", command: Cmd.setNoiseLevel, payload: [101], reachesWire: false),
        WireRow(name: "factory reset", command: 0x0040, payload: [], reachesWire: false),
        WireRow(name: "malformed mode table", command: Cmd.setModeTable, payload: [1, 0], reachesWire: false),
    ]

    /// The controller refuses before anything is sent, so a refused frame
    /// never reaches even a transport that would accept it.
    @MainActor
    func testRefusedFramesNeverReachTheTransport() async {
        for row in Self.wireRows {
            let fake = FakeTransport()
            fake.isOpen = true
            fake.respond = { [Reply.ok($0.command)] }
            let controller = HeadphoneController(transport: fake)
            _ = try? await controller.request(row.command, payload: row.payload, timeout: .milliseconds(200))
            XCTAssertEqual(!fake.sent.isEmpty, row.reachesWire, row.name)
        }
    }
}
