import Foundation

/// A single GAIA frame.
///
/// Wire format (Qualcomm GAIA), checked against 763 captured MOMENTUM 4 and
/// MOMENTUM 5 frames in the community M4C project:
///
///     FF | 03 | 00 | length(u8) | vendor(u16 BE) | command(u16 BE) | payload
///      ^    ^    ^
///      |    |    `- flags: bit 0 appends a checksum, bit 1 a 16-bit length.
///      |    |       Always 0 from this device, and never set by this app.
///      |    `- protocol version
///      `- start of frame
///
/// Payloads above 254 bytes need a different header, so they are never sent.
/// The largest any capture shows is 25 bytes.
///
/// Known-good vectors (see GaiaFrameTests):
///     get battery      -> FF 03 00 00 04 95 06 03
///     battery = 42%    <- FF 03 00 01 04 95 07 03 2A
///     set ANC on       -> FF 03 00 01 04 95 1A 04 01
///     set ANC ack      <- FF 03 00 00 04 95 1B 04
struct GaiaFrame: Equatable {
    static let start: UInt8 = 0xFF
    static let version: UInt8 = 0x03
    static let noFlags: UInt8 = 0x00
    static let vendorSennheiser: UInt16 = 0x0495
    static let headerLength = 8
    static let maxPayload = 254

    var vendor: UInt16 = GaiaFrame.vendorSennheiser
    var command: UInt16
    var payload: [UInt8]

    init(command: UInt16, payload: [UInt8] = [], vendor: UInt16 = GaiaFrame.vendorSennheiser) {
        self.command = command
        self.payload = payload
        self.vendor = vendor
    }

    func encoded() -> [UInt8] {
        // CommandSafety allows no payload anywhere near this; a longer one
        // would go out with a truncated length and corrupt the stream.
        assert(payload.count <= GaiaFrame.maxPayload, "GAIA payload too long for a one-byte length")
        var out = [UInt8]()
        out.reserveCapacity(GaiaFrame.headerLength + payload.count)
        out.append(GaiaFrame.start)
        out.append(GaiaFrame.version)
        out.append(GaiaFrame.noFlags)
        out.append(UInt8(truncatingIfNeeded: payload.count))
        out.append(UInt8(truncatingIfNeeded: vendor >> 8))
        out.append(UInt8(truncatingIfNeeded: vendor))
        out.append(UInt8(truncatingIfNeeded: command >> 8))
        out.append(UInt8(truncatingIfNeeded: command))
        out.append(contentsOf: payload)
        return out
    }

    /// Pulls one frame off the front of `buffer`, consuming its bytes.
    ///
    /// Returns nil when the buffer does not yet hold a complete frame. If the
    /// buffer does not begin at a frame boundary it resynchronises to the next
    /// start byte rather than throwing the stream away.
    static func decode(consuming buffer: inout [UInt8]) -> GaiaFrame? {
        while true {
            guard let startIndex = buffer.firstIndex(of: GaiaFrame.start) else {
                buffer.removeAll(keepingCapacity: true)
                return nil
            }
            if startIndex > 0 { buffer.removeFirst(startIndex) }
            guard buffer.count >= headerLength else { return nil }

            // A stray 0xFF is not a frame start. Trusting its length field
            // would park every later frame behind bytes that never come.
            guard hasPlausibleHeader(buffer) else {
                buffer.removeFirst()
                continue
            }

            let length = Int(buffer[3])
            let total = headerLength + length
            guard buffer.count >= total else { return nil }

            let vendor = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
            let command = UInt16(buffer[6]) << 8 | UInt16(buffer[7])
            let payload = Array(buffer[headerLength..<total])
            buffer.removeFirst(total)
            return GaiaFrame(command: command, payload: payload, vendor: vendor)
        }
    }

    /// True when the header at the front of `bytes` has the fixed fields every
    /// frame from this device carries. A frame with flags set would carry a
    /// checksum or a longer length that this decoder does not read.
    private static func hasPlausibleHeader(_ bytes: [UInt8]) -> Bool {
        let vendor = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        return bytes[1] == version && bytes[2] == noFlags && vendor == vendorSennheiser
    }
}

/// How the device answered. The three forms are distinguished by two bits laid
/// over the command id that was sent.
enum GaiaResponseKind {
    case success        // command | 0x0100
    case error          // command | 0x0180
    case notification   // command | 0x0080

    init?(responseCommand: UInt16) {
        switch responseCommand & 0x0180 {
        case 0x0100: self = .success
        case 0x0180: self = .error
        case 0x0080: self = .notification
        default: return nil   // no status bits: not a response
        }
    }
}

extension GaiaFrame {
    /// The request id this frame is answering, with the status bits stripped.
    var baseCommand: UInt16 { command & ~0x0180 }
    var responseKind: GaiaResponseKind? { GaiaResponseKind(responseCommand: command) }

    /// Error payloads seen in practice: 0x05 malformed/wrong length, 0x83 index
    /// out of range.
    var errorCode: UInt8? { responseKind == .error ? payload.first : nil }
}
