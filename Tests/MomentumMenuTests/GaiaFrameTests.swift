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

/// Draining a byte stream: which frames come out, and what stays buffered.
///
/// The stray-0xFF rows are the regression cases. A bare 0xFF used to be
/// trusted as a frame start, and its bogus length parked every later frame
/// behind bytes that never arrive.
final class GaiaStreamTests: XCTestCase {

    private static let battery42: [UInt8] = [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A]
    private static let ancAck: [UInt8] = [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x1B, 0x04]

    private struct Row {
        let name: String
        let input: [UInt8]
        let frames: [GaiaFrame]
        let remainder: [UInt8]
    }

    private static let batteryFrame = GaiaFrame(command: 0x0703, payload: [42])
    private static let ackFrame = GaiaFrame(command: 0x1B04)

    private static let rows: [Row] = [
        Row(name: "one valid frame",
            input: battery42, frames: [batteryFrame], remainder: []),
        Row(name: "two frames in one read",
            input: ancAck + battery42, frames: [ackFrame, batteryFrame], remainder: []),
        Row(name: "payload containing 0xFF",
            input: [0xFF, 0x03, 0x00, 0x02, 0x04, 0x95, 0x07, 0x03, 0xFF, 0x2A],
            frames: [GaiaFrame(command: 0x0703, payload: [0xFF, 0x2A])], remainder: []),
        Row(name: "a lone 0xFF before a frame",
            input: [0xFF] + battery42, frames: [batteryFrame], remainder: []),
        Row(name: "garbage without 0xFF before a frame",
            input: [0xAA, 0xBB] + battery42, frames: [batteryFrame], remainder: []),
        Row(name: "stray FF 03 FF FF before a frame",
            input: [0xFF, 0x03, 0xFF, 0xFF] + battery42, frames: [batteryFrame], remainder: []),
        Row(name: "iAP2 header before a frame",
            input: [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10] + battery42, frames: [batteryFrame], remainder: []),
        Row(name: "truncated frame head before a frame",
            input: [0xFF, 0x03, 0x00] + battery42, frames: [batteryFrame], remainder: []),
        Row(name: "header with only the flags byte wrong before a frame",
            input: [0xFF, 0x04, 0x00, 0x00, 0x04, 0x95, 0x07, 0x03] + battery42,
            frames: [batteryFrame], remainder: []),
        // Byte 2 is GAIA's flags byte: bit 0 appends a checksum, bit 1 a
        // 16-bit length. The MOMENTUM 4 never sets either.
        Row(name: "header with the checksum flag before a frame",
            input: [0xFF, 0x03, 0x01, 0x00, 0x04, 0x95, 0x07, 0x03] + battery42,
            frames: [batteryFrame], remainder: []),
        Row(name: "header with the long-length flag before a frame",
            input: [0xFF, 0x03, 0x02, 0x00, 0x04, 0x95, 0x07, 0x03] + battery42,
            frames: [batteryFrame], remainder: []),
        Row(name: "a frame with the largest one-byte length",
            input: [0xFF, 0x03, 0x00, 0xFF, 0x04, 0x95, 0x07, 0x03] + Array(repeating: 7, count: 255),
            frames: [GaiaFrame(command: 0x0703, payload: Array(repeating: 7, count: 255))], remainder: []),
        Row(name: "header with a foreign vendor before a frame",
            input: [0xFF, 0x03, 0x00, 0x00, 0x12, 0x34, 0x00, 0x00] + battery42,
            frames: [batteryFrame], remainder: []),
        Row(name: "incomplete frame stays buffered",
            input: Array(battery42.dropLast()), frames: [], remainder: Array(battery42.dropLast())),
        Row(name: "incomplete header stays buffered",
            input: [0xFF, 0x03], frames: [], remainder: [0xFF, 0x03]),
        Row(name: "frame then a lone 0xFF",
            input: battery42 + [0xFF], frames: [batteryFrame], remainder: [0xFF]),
        Row(name: "only garbage",
            input: [0x01, 0x02, 0x03], frames: [], remainder: []),
        Row(name: "empty buffer",
            input: [], frames: [], remainder: []),
    ]

    private static func drain(_ input: [UInt8]) -> (frames: [GaiaFrame], remainder: [UInt8]) {
        var buffer = input
        var frames: [GaiaFrame] = []
        while let frame = GaiaFrame.decode(consuming: &buffer) { frames.append(frame) }
        return (frames, buffer)
    }

    func testDrainYieldsExactlyTheRealFrames() {
        for row in Self.rows {
            XCTAssertEqual(Self.drain(row.input).frames, row.frames, row.name)
        }
    }

    func testDrainKeepsOnlyAPossibleFrameStart() {
        for row in Self.rows {
            XCTAssertEqual(Self.drain(row.input).remainder, row.remainder, row.name)
        }
    }

    /// Payload sizes `encoded()` may produce. Above 254 GAIA switches to a
    /// different header, which this app never sends; the largest payload any
    /// capture shows is 25 bytes.
    private static let roundTripSizes = [0, 1, 6, 25, 254]

    func testEncodedFramesDecode() {
        for size in Self.roundTripSizes {
            let frame = GaiaFrame(command: 0x1A00, payload: Array(repeating: 0xAB, count: size))
            var buffer = frame.encoded()
            XCTAssertEqual(GaiaFrame.decode(consuming: &buffer), frame, "\(size)-byte payload")
        }
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
