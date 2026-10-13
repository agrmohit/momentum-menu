import XCTest
@testable import M4Core

/// Vectors taken from captured MOMENTUM 4 traffic (firmware 3.38.3) as
/// recorded by momentumctl's codec tests.
final class GaiaFrameTests: XCTestCase {

    func testEncodeGetBattery() {
        let frame = GaiaFrame(command: Cmd.getBattery)
        XCTAssertEqual(frame.encoded(), [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x06, 0x03])
    }

    func testEncodeSetAncOn() {
        let frame = GaiaFrame(command: Cmd.setAncEnabled, payload: [0x01])
        XCTAssertEqual(frame.encoded(), [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x1A, 0x04, 0x01])
    }

    func testDecodeBatteryResponse() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A]
        let frame = GaiaFrame.decode(consuming: &buffer)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.payload, [42])
        XCTAssertEqual(frame?.baseCommand, Cmd.getBattery)
        XCTAssertEqual(frame?.responseKind, .success)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDecodeSetAck() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x1B, 0x04]
        let frame = GaiaFrame.decode(consuming: &buffer)
        XCTAssertEqual(frame?.baseCommand, Cmd.setAncEnabled)
        XCTAssertEqual(frame?.responseKind, .success)
    }

    /// request | 0x0180 is the error form, and carries a reason byte.
    func testDecodeErrorForm() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x1B, 0x83, 0x05]
        let frame = GaiaFrame.decode(consuming: &buffer)
        XCTAssertEqual(frame?.responseKind, .error)
        XCTAssertEqual(frame?.baseCommand, 0x1A03)
        XCTAssertEqual(frame?.errorCode, GaiaError.malformedOrWrongLength)
    }

    /// request | 0x0080 is an unsolicited push, not an answer to anything.
    func testDecodeNotificationForm() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x06, 0x82, 0x01]
        let frame = GaiaFrame.decode(consuming: &buffer)
        XCTAssertEqual(frame?.responseKind, .notification)
        XCTAssertEqual(frame?.baseCommand, 0x0602)
    }

    func testPartialFrameIsNotConsumed() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x04, 0x04, 0x95, 0x07, 0x03, 0x2A]
        XCTAssertNil(GaiaFrame.decode(consuming: &buffer))
        XCTAssertEqual(buffer.count, 9, "an incomplete frame must stay buffered")
    }

    func testTwoFramesInOneRead() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x1B, 0x04,
                               0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A]
        let first = GaiaFrame.decode(consuming: &buffer)
        let second = GaiaFrame.decode(consuming: &buffer)
        XCTAssertEqual(first?.baseCommand, Cmd.setAncEnabled)
        XCTAssertEqual(second?.payload, [42])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testResyncsAfterGarbage() {
        var buffer: [UInt8] = [0xAA, 0xBB, 0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A]
        XCTAssertEqual(GaiaFrame.decode(consuming: &buffer)?.payload, [42])
    }

    func testRoundTrip() {
        let original = GaiaFrame(command: 0x1A00, payload: [1, 2, 3, 0, 3, 1])
        var buffer = original.encoded()
        XCTAssertEqual(GaiaFrame.decode(consuming: &buffer), original)
    }
}

final class CommandSafetyTests: XCTestCase {

    /// The id that took headphones offline in two separate sweeps.
    func testOfflineCommandIsBlocked() {
        XCTAssertFalse(CommandSafety.isSafe(0x0607))
        XCTAssertFalse(CommandSafety.isSafe(0x0613))
        XCTAssertFalse(CommandSafety.isSafe(0x0685))
    }

    /// The id that erased a phone's pairing.
    func testPairingEraserIsBlocked() {
        XCTAssertFalse(CommandSafety.isSafe(0x1403))
        for id: UInt16 in [0x0801, 0x0805, 0x0817] {
            XCTAssertFalse(CommandSafety.isSafe(id))
        }
    }

    /// Whole power group blocked apart from battery.
    func testPowerGroupBlockedExceptBattery() {
        XCTAssertTrue(CommandSafety.isSafe(Cmd.getBattery))
        XCTAssertFalse(CommandSafety.isSafe(0x0600))
        XCTAssertFalse(CommandSafety.isSafe(0x0601))
        XCTAssertFalse(CommandSafety.isSafe(0x06FF))
    }

    func testCommandsWeActuallyUseAreAllowed() {
        for id in [Cmd.getAncEnabled, Cmd.setAncEnabled, Cmd.getNoiseLevel, Cmd.setNoiseLevel,
                   Cmd.getModeTable, Cmd.setModeTable, Cmd.getEqConfig, Cmd.setBandGain,
                   Cmd.getBandGain, Cmd.getAllGains, Cmd.getBandFrequency, Cmd.setBassBoost,
                   Cmd.getBassBoost, Cmd.getFirmwareVersion, Cmd.getTouchControls] {
            XCTAssertTrue(CommandSafety.isSafe(id), String(format: "0x%04X should be allowed", id))
        }
    }

    func testRejectionReasonExplainsItself() {
        XCTAssertNotNil(CommandSafety.rejectionReason(for: 0x0607))
        XCTAssertNil(CommandSafety.rejectionReason(for: Cmd.getBattery))
    }
}

final class GainTests: XCTestCase {

    /// Smart Control's Pop preset reads 0/20/25/15/-20 on the wire and
    /// 0/2.0/2.5/1.5/-2.0 dB in the UI.
    func testPopPresetMatchesObservedWireValues() {
        let db = [0.0, 2.0, 2.5, 1.5, -2.0]
        let wire = db.map { Gain.encode(db: $0) }
        XCTAssertEqual(wire, [0, 20, 25, 15, UInt8(bitPattern: -20)])
        XCTAssertEqual(wire.map { Gain.decode($0) }, db)
    }

    func testGainClampsToInt8Range() {
        XCTAssertEqual(Gain.encode(db: 99), Gain.encode(db: Gain.maxDb))
        XCTAssertEqual(Gain.encode(db: -99), Gain.encode(db: Gain.minDb))
    }

    func testNegativeGainsRoundTrip() {
        for db in stride(from: -12.8, through: 12.7, by: 0.1) {
            let rounded = (db * 10).rounded() / 10
            XCTAssertEqual(Gain.decode(Gain.encode(db: rounded)), rounded, accuracy: 0.001)
        }
    }
}
