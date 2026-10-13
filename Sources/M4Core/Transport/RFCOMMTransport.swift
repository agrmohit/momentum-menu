import Foundation
import IOBluetooth

/// Errors surfaced to the UI. Deliberately plain-language: these end up in a
/// menu bar popover, not a log file.
public enum TransportError: LocalizedError {
    case headphonesNotFound
    case notConnected
    case gaiaServiceMissing
    case channelOpenFailed(IOReturn)
    case writeFailed(IOReturn)
    case timedOut(command: UInt16)
    case deviceRejected(command: UInt16, code: UInt8)
    case blockedCommand(reason: String)

    public var errorDescription: String? {
        switch self {
        case .headphonesNotFound:
            return "No paired MOMENTUM 4 found. Pair the headphones in System Settings first."
        case .notConnected:
            return "The headphones are paired but not connected."
        case .gaiaServiceMissing:
            return "The headphones did not advertise their GAIA control service."
        case .channelOpenFailed(let status):
            return "Could not open the control channel (IOReturn \(status))."
        case .writeFailed(let status):
            return "Could not send to the headphones (IOReturn \(status))."
        case .timedOut(let command):
            return String(format: "The headphones did not answer command 0x%04X.", command)
        case .deviceRejected(let command, let code):
            return String(format: "The headphones rejected command 0x%04X (code 0x%02X).", command, code)
        case .blockedCommand(let reason):
            return "Refused to send a known-dangerous command: \(reason)"
        }
    }
}

/// Opens the GAIA RFCOMM channel on a paired MOMENTUM 4 and moves frames
/// across it.
///
/// Bluetooth Classic RFCOMM is macOS-only territory — iOS reserves it for
/// MFi-licensed accessories, which is exactly why this app can exist on the
/// Mac but the equivalent could not be built on iPhone.
final class RFCOMMTransport: NSObject {

    /// The headset's GAIA service. NOT the Apple iAP2 UUID
    /// (00000000-DECA-FADE-DECA-DEAFDECACAFF), which sits alongside it.
    static let gaiaServiceUUID = UUID(uuidString: "A2129FF3-081B-4C45-8AFE-469D9C4842EC")!

    /// Matched against the device name as a sanity check only; the real test
    /// is whether the device advertises GAIA.
    static let deviceNameMarker = "MOMENTUM 4"

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var inbound: [UInt8] = []

    /// Called for every decoded frame, on the main thread.
    var onFrame: ((GaiaFrame) -> Void)?
    /// Called when the channel drops.
    var onDisconnect: (() -> Void)?

    var isOpen: Bool { channel?.isOpen() ?? false }
    var deviceName: String? { device?.name }

    private static func sdpUUID() -> IOBluetoothSDPUUID {
        var raw = gaiaServiceUUID.uuid
        return withUnsafeBytes(of: &raw) { buffer in
            IOBluetoothSDPUUID(bytes: buffer.baseAddress!, length: buffer.count)
        }
    }

    /// Every paired device advertising the GAIA service.
    static func discoverCandidates() -> [IOBluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        let uuid = sdpUUID()
        return paired.filter { $0.getServiceRecord(for: uuid) != nil }
    }

    /// All GAIA service records on a device. The MOMENTUM 4 publishes two
    /// (RFCOMM channels 1 and 2); we try them in the order macOS reports.
    private static func gaiaRecords(on device: IOBluetoothDevice) -> [IOBluetoothSDPServiceRecord] {
        let uuid = sdpUUID()
        var records: [IOBluetoothSDPServiceRecord] = []
        if let all = device.services as? [IOBluetoothSDPServiceRecord] {
            records = all.filter { $0.matchesUUIDArray([uuid]) }
        }
        if records.isEmpty, let single = device.getServiceRecord(for: uuid) {
            records = [single]
        }
        return records
    }

    /// - Parameter allowWake: whether we may bring the Bluetooth link up when
    ///   the headphones are idle. Only ever true for an action the user just
    ///   took. Background refreshes pass false, because `openConnection()`
    ///   does not merely observe — it pulls the headphones onto this Mac, and
    ///   with multipoint that means taking them away from whatever device the
    ///   user just handed them to. An app that reads a battery percentage has
    ///   no business doing that once a minute.
    func connect(allowWake: Bool = false) throws {
        guard let target = Self.discoverCandidates().first else {
            throw TransportError.headphonesNotFound
        }
        device = target

        if !target.isConnected() {
            guard allowWake else { throw TransportError.notConnected }
            let status = target.openConnection()
            guard status == kIOReturnSuccess, target.isConnected() else {
                throw TransportError.notConnected
            }
        }

        let records = Self.gaiaRecords(on: target)
        guard !records.isEmpty else { throw TransportError.gaiaServiceMissing }

        var lastStatus: IOReturn = kIOReturnError
        for record in records {
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }

            var opened: IOBluetoothRFCOMMChannel?
            let status = target.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            if status == kIOReturnSuccess, let opened {
                channel = opened
                return
            }
            lastStatus = status
        }
        throw TransportError.channelOpenFailed(lastStatus)
    }

    func disconnect() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        // Deliberately NOT device.closeConnection(): that tears down the whole
        // baseband link and cuts the user's audio. We only own the control
        // channel, so that is all we close.
        device = nil
        inbound.removeAll()
    }

    /// Drops the entire Bluetooth link, not just the control channel.
    ///
    /// The M4 holds two multipoint links at once, and that ceiling is in its
    /// own firmware — nothing a host can send raises it. So the only way to
    /// free a slot for a third device is for one of the current two to let go,
    /// which is what this does from the Mac's side.
    ///
    /// Note this is the same `closeConnection()` that `disconnect()` must
    /// never call: there it would cut the user's audio as a side effect of
    /// tidying up. Here severing the link is the entire point.
    func releaseLink() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        inbound.removeAll()
        device?.closeConnection()
        device = nil
    }

    func send(_ frame: GaiaFrame) throws {
        if let reason = CommandSafety.rejectionReason(for: frame.command) {
            throw TransportError.blockedCommand(reason: reason)
        }
        guard let channel, channel.isOpen() else { throw TransportError.notConnected }

        var bytes = frame.encoded()
        let status = bytes.withUnsafeMutableBytes { raw -> IOReturn in
            channel.writeSync(raw.baseAddress!, length: UInt16(raw.count))
        }
        guard status == kIOReturnSuccess else { throw TransportError.writeFailed(status) }
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        guard dataLength > 0 else { return }
        let chunk = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        inbound.append(contentsOf: chunk)

        // A single read can carry several frames, or half of one.
        while let frame = GaiaFrame.decode(consuming: &inbound) {
            onFrame?(frame)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        inbound.removeAll()
        onDisconnect?()
    }
}
