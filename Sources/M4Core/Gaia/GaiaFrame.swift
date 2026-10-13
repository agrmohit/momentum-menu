import Foundation

/// A single GAIA frame.
///
/// Wire format, confirmed against two independent implementations and against
/// captured traffic from a MOMENTUM 4 on firmware 3.38.3:
///
///     FF 03 | length(u16 BE) | vendor(u16 BE) | command(u16 BE) | payload
///      ^  ^
///      |  `- protocol version / flags, always 0x03 on this device
///      `- start of frame
///
/// Known-good vectors (see GaiaFrameTests):
///     get battery      -> FF 03 00 00 04 95 06 03
///     battery = 42%    <- FF 03 00 01 04 95 07 03 2A
///     set ANC on       -> FF 03 00 01 04 95 1A 04 01
///     set ANC ack      <- FF 03 00 00 04 95 1B 04
struct GaiaFrame: Equatable {
    static let start: UInt8 = 0xFF
    static let flags: UInt8 = 0x03
    static let vendorSennheiser: UInt16 = 0x0495
    static let headerLength = 8

    var vendor: UInt16 = GaiaFrame.vendorSennheiser
    var command: UInt16
    var payload: [UInt8]

    init(command: UInt16, payload: [UInt8] = [], vendor: UInt16 = GaiaFrame.vendorSennheiser) {
        self.command = command
        self.payload = payload
        self.vendor = vendor
    }

    func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(GaiaFrame.headerLength + payload.count)
        out.append(GaiaFrame.start)
        out.append(GaiaFrame.flags)
        out.append(UInt8(truncatingIfNeeded: payload.count >> 8))
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

            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            let total = headerLength + length
            guard buffer.count >= total else { return nil }

            let vendor = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
            let command = UInt16(buffer[6]) << 8 | UInt16(buffer[7])
            let payload = Array(buffer[headerLength..<total])
            buffer.removeFirst(total)
            return GaiaFrame(command: command, payload: payload, vendor: vendor)
        }
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
