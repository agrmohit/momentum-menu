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
    case unexpectedReply(command: UInt16)

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
        case .unexpectedReply(let command):
            return String(format: "The headphones answered command 0x%04X in an unexpected form; nothing was changed.",
                          command)
        }
    }
}

/// Opens the GAIA RFCOMM channel on a paired MOMENTUM 4 and moves frames
/// across it.
///
/// Bluetooth Classic RFCOMM is macOS-only territory — iOS reserves it for
/// MFi-licensed accessories, which is exactly why this app can exist on the
/// Mac but the equivalent could not be built on iPhone.
///
/// Main-actor isolated because IOBluetooth calls the delegate on the main run
/// loop. The pending continuations are set by `connect` and cleared by those
/// callbacks or a timeout, so all three must run on the same thread.
@MainActor
final class RFCOMMTransport: NSObject {

    /// The headset's GAIA service. NOT the Apple iAP2 UUID
    /// (00000000-DECA-FADE-DECA-DEAFDECACAFF), which sits alongside it.
    nonisolated static let gaiaServiceUUID = UUID(uuidString: "A2129FF3-081B-4C45-8AFE-469D9C4842EC")!

    /// Matched against the device name as a sanity check only; the real test
    /// is whether the device advertises GAIA.
    static let deviceNameMarker = "MOMENTUM 4"

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var inbound: [UInt8] = []
    /// Resumed by rfcommChannelOpenComplete, or by the timeout, whichever
    /// comes first. Cleared before resuming so it can only fire once.
    private var openContinuation: CheckedContinuation<IOReturn, Never>?
    private var sdpContinuation: CheckedContinuation<Void, Never>?
    private var lastOpenStatus: IOReturn = kIOReturnError
    /// Set by `disconnect` and `releaseLink`; a connect still trying channels
    /// stops at the next one.
    private var stopped = false
    /// Numbers each open or SDP wait; see `awaitOpenComplete`.
    private var waits = 0
    /// Which RFCOMM channel the control session actually ended up on.
    private(set) var openedChannelID: BluetoothRFCOMMChannelID?

    /// Called for every decoded frame, on the main thread.
    var onFrame: ((GaiaFrame) -> Void)?
    /// Called when the channel drops.
    var onDisconnect: (() -> Void)?

    var isOpen: Bool { channel?.isOpen() ?? false }
    var deviceName: String? { device?.name }

    private nonisolated static func sdpUUID() -> IOBluetoothSDPUUID {
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
    func connect(allowWake: Bool = false) async throws {
        guard let target = Self.discoverCandidates().first else {
            throw TransportError.headphonesNotFound
        }
        device = target
        stopped = false

        if !target.isConnected() {
            guard allowWake else { throw TransportError.notConnected }
            let status = target.openConnection()
            guard status == kIOReturnSuccess, target.isConnected() else {
                throw TransportError.notConnected
            }
        }

        // First pass uses whatever macOS has cached, which is the fast path.
        if try await openGaiaChannel(on: target) { return }

        // Failing that, the cache may predate a firmware update: if the
        // headphones moved their GAIA service to a different RFCOMM channel,
        // we would be opening one that no longer exists and waiting forever
        // for a completion that never comes. Ask the device directly and retry.
        guard !stopped else { throw TransportError.notConnected }
        await refreshServiceRecords(on: target)
        if try await openGaiaChannel(on: target) { return }

        throw TransportError.channelOpenFailed(lastOpenStatus)
    }

    /// Re-queries the device's SDP records rather than trusting the cache.
    private func refreshServiceRecords(on device: IOBluetoothDevice) async {
        waits += 1
        let wait = waits
        await withCheckedContinuation { continuation in
            sdpContinuation = continuation
            if device.performSDPQuery(self) != kIOReturnSuccess {
                sdpContinuation = nil
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.waits == wait, let pending = self.sdpContinuation else { return }
                self.sdpContinuation = nil
                pending.resume()
            }
        }
    }

    /// Channels GAIA has been seen on, tried after whatever SDP advertises.
    private static let fallbackChannels: [BluetoothRFCOMMChannelID] = [1, 2]

    /// Tries each candidate channel until one opens *and* answers GAIA.
    ///
    /// SDP is a hint here, not ground truth. A firmware update moved this
    /// device's GAIA endpoint from channel 2 to channel 1 while leaving the
    /// record pointing at 2, so trusting the advertised number alone meant
    /// hanging forever on a channel nothing was listening to. Other channels
    /// open happily without speaking GAIA, so opening is not proof either —
    /// hence the handshake.
    private func openGaiaChannel(on target: IOBluetoothDevice) async throws -> Bool {
        var candidates: [BluetoothRFCOMMChannelID] = []
        for record in Self.gaiaRecords(on: target) {
            var channelID: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                candidates.append(channelID)
            }
        }
        for fallback in Self.fallbackChannels where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        guard !candidates.isEmpty else { throw TransportError.gaiaServiceMissing }

        for channelID in candidates {
            // A release or quit while an earlier candidate was opening: stop,
            // or the next open would bring the link back up.
            guard !stopped else { throw TransportError.notConnected }
            var opened: IOBluetoothRFCOMMChannel?
            let status = target.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            guard status == kIOReturnSuccess, let opened else {
                lastOpenStatus = status
                continue
            }
            channel = opened

            // openRFCOMMChannelAsync returning success only means the request
            // was accepted; whether it opened arrives later via
            // rfcommChannelOpenComplete. Sleeping a fixed interval and checking
            // isOpen() instead is a race the old firmware happened to win.
            let result = await awaitOpenComplete(timeoutSeconds: 8)
            if result == kIOReturnSuccess, opened.isOpen(), await speaksGaia() {
                openedChannelID = channelID
                return true
            }

            lastOpenStatus = result == kIOReturnSuccess ? kIOReturnNotFound : result
            opened.setDelegate(nil)
            opened.close()
            channel = nil
        }
        return false
    }

    /// Asks for the battery level and waits for a well-formed GAIA answer.
    /// Harmless, and the cheapest proof that this channel is the control one.
    private func speaksGaia() async -> Bool {
        let saved = onFrame
        defer { onFrame = saved }

        return await withCheckedContinuation { continuation in
            var settled = false
            onFrame = { frame in
                guard !settled, frame.baseCommand == Cmd.getBattery,
                      frame.responseKind != nil else { return }
                settled = true
                continuation.resume(returning: true)
            }
            do {
                try send(GaiaFrame(command: Cmd.getBattery))
            } catch {
                settled = true
                continuation.resume(returning: false)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard !settled else { return }
                settled = true
                continuation.resume(returning: false)
            }
        }
    }

    private func awaitOpenComplete(timeoutSeconds: Double) async -> IOReturn {
        // Timers are never cancelled, so each wait is numbered: an earlier
        // channel's timer must not end a later channel's wait.
        waits += 1
        let wait = waits
        return await withCheckedContinuation { continuation in
            openContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let self, self.waits == wait, let pending = self.openContinuation else { return }
                self.openContinuation = nil
                pending.resume(returning: kIOReturnTimeout)
            }
        }
    }

    func disconnect() {
        stopped = true
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        // Deliberately NOT device.closeConnection(): that tears down the whole
        // baseband link and cuts the user's audio. We only own the control
        // channel, so that is all we close.
        device = nil
        inbound.removeAll()
    }

    /// Dumps what macOS currently knows about every paired device, so a
    /// failure to find the headphones can be told apart from a failure to open
    /// their control channel. Read-only, and opens nothing, so any thread.
    nonisolated static func inventory() -> String {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return "macOS returned no paired-device list at all."
        }
        let uuid = sdpUUID()
        var lines = ["Paired devices: \(paired.count)"]
        for device in paired {
            lines.append("• \(device.name ?? "(unnamed)")  [\(device.addressString ?? "?")]  "
                         + "connected=\(device.isConnected())")
            guard let records = device.services as? [IOBluetoothSDPServiceRecord], !records.isEmpty else {
                lines.append("      no SDP records cached")
                continue
            }
            for record in records {
                var channel: BluetoothRFCOMMChannelID = 0
                let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
                let isGaia = record.matchesUUIDArray([uuid])
                lines.append("      - \(record.getServiceName() ?? "(unnamed service)")"
                             + (hasChannel ? "  rfcomm=\(channel)" : "")
                             + (isGaia ? "   <<< GAIA >>>" : ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Tries to open specific RFCOMM channels and reports what happened to
    /// each, to tell "the service moved" apart from "the device refuses us".
    ///
    /// Deliberately does not touch channel 10: that is Hands-Free, and opening
    /// it could disturb call audio. Sends no GAIA commands — it opens the
    /// channel, waits for the completion, and closes it again.
    func probeChannels(_ channels: [BluetoothRFCOMMChannelID]) async -> String {
        guard let target = Self.discoverCandidates().first else {
            return "No paired device advertising GAIA."
        }
        guard target.isConnected() else { return "\(target.name ?? "device") is not connected." }

        var lines = ["Channel open attempts on \(target.name ?? "device"):"]
        for id in channels {
            var opened: IOBluetoothRFCOMMChannel?
            let request = target.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
            guard request == kIOReturnSuccess, let opened else {
                lines.append("  channel \(id): request refused (IOReturn \(request))")
                continue
            }
            let result = await awaitOpenComplete(timeoutSeconds: 6)
            let verdict: String
            switch result {
            case kIOReturnSuccess where opened.isOpen(): verdict = "OPENED"
            case kIOReturnSuccess: verdict = "completed but not open"
            case kIOReturnTimeout: verdict = "no completion within 6s"
            default: verdict = "failed (IOReturn \(result))"
            }
            lines.append("  channel \(id): \(verdict)")
            opened.setDelegate(nil)
            opened.close()
        }
        channel = nil
        return lines.joined(separator: "\n")
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
        stopped = true
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        inbound.removeAll()
        device?.closeConnection()
        device = nil
    }

    func send(_ frame: GaiaFrame) throws {
        if let reason = CommandSafety.rejectionReason(for: frame.command, payload: frame.payload,
                                                      vendor: frame.vendor) {
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

// `@preconcurrency`: the delegate protocol predates actors. IOBluetooth calls
// it on the main thread, and the runtime traps if that ever changes.
extension RFCOMMTransport: @preconcurrency IOBluetoothRFCOMMChannelDelegate {

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

    /// Target callback for performSDPQuery.
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let pending = sdpContinuation else { return }
        sdpContinuation = nil
        pending.resume()
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let pending = openContinuation else { return }
        openContinuation = nil
        pending.resume(returning: error)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        inbound.removeAll()
        onDisconnect?()
    }
}
