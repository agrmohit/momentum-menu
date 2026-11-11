import XCTest
@testable import M4Core

/// What the popover says when Bluetooth itself is off.
///
/// Regression: with Bluetooth off, the popover said "No paired MOMENTUM 4
/// found. Pair the headphones in System Settings first.", over a hint that the
/// headphones "must be paired and switched on". Both sent the user to re-pair
/// headphones that were paired all along.
@MainActor
final class BluetoothOffTests: XCTestCase {

    // MARK: - Which error a connect raises

    private struct DiscoveryRow {
        let name: String
        let poweredOn: Bool
        let hasCandidate: Bool
        let expected: TransportError?
    }

    private static let discoveryRows: [DiscoveryRow] = [
        DiscoveryRow(name: "on, headphones found", poweredOn: true, hasCandidate: true, expected: nil),
        DiscoveryRow(name: "on, nothing paired", poweredOn: true, hasCandidate: false, expected: .headphonesNotFound),
        DiscoveryRow(name: "off, nothing found", poweredOn: false, hasCandidate: false, expected: .bluetoothOff),
        DiscoveryRow(name: "off, cached device still listed", poweredOn: false, hasCandidate: true,
                     expected: .bluetoothOff),
    ]

    func testDiscoveryError() {
        for row in Self.discoveryRows {
            let error = RFCOMMTransport.discoveryError(poweredOn: row.poweredOn, hasCandidate: row.hasCandidate)
            XCTAssertEqual(error?.errorDescription, row.expected?.errorDescription, row.name)
        }
    }

    func testBluetoothOffMessageDoesNotAskToPair() {
        let message = TransportError.bluetoothOff.errorDescription ?? ""
        XCTAssertTrue(message.contains("Bluetooth is off"), message)
        XCTAssertFalse(message.contains("Pair"), message)
    }

    // MARK: - The hint under the message

    private static let turnOnHint = DeviceState.bluetoothOffHint
    private static let pairHint = DeviceState.headphonesAwayHint

    private struct HintRow {
        let name: String
        /// One connect per entry: the error it throws, or nil to succeed.
        let attempts: [TransportError?]
        let hint: String
    }

    private static let hintRows: [HintRow] = [
        HintRow(name: "never connected", attempts: [], hint: pairHint),
        HintRow(name: "Bluetooth off", attempts: [.bluetoothOff], hint: turnOnHint),
        HintRow(name: "Bluetooth off, tried twice", attempts: [.bluetoothOff, .bluetoothOff], hint: turnOnHint),
        HintRow(name: "headphones not paired", attempts: [.headphonesNotFound], hint: pairHint),
        HintRow(name: "headphones away", attempts: [.notConnected], hint: pairHint),
        HintRow(name: "channel would not open", attempts: [.channelOpenFailed(-1)], hint: pairHint),
        HintRow(name: "Bluetooth turned on, headphones away", attempts: [.bluetoothOff, .notConnected],
                hint: pairHint),
        HintRow(name: "Bluetooth turned off after a failed connect", attempts: [.notConnected, .bluetoothOff],
                hint: turnOnHint),
        HintRow(name: "Bluetooth turned on, then connected and dropped", attempts: [.bluetoothOff, nil],
                hint: pairHint),
    ]

    func testHintUnderTheMessage() async {
        for row in Self.hintRows {
            let fake = FakeTransport()
            fake.respond = Reply.device(battery: 50)
            let controller = HeadphoneController(transport: fake)
            for error in row.attempts {
                fake.connectError = error
                await controller.connect()
            }
            if controller.state.connected { fake.drop() }
            XCTAssertEqual(controller.state.disconnectedHint, row.hint, row.name)
        }
    }
}
