import Foundation
@testable import M4Core

/// Stands in for the RFCOMM link so the controller can be tested without
/// Bluetooth.
///
/// Replies come from `respond` and arrive one main-actor hop after the send,
/// as they would from the real channel: never inside `send` itself.
final class FakeTransport: GaiaTransport {
    var onFrame: ((GaiaFrame) -> Void)?
    var onDisconnect: (() -> Void)?
    var isOpen = false
    var deviceName: String? = "MOMENTUM 4"

    private(set) var sent: [GaiaFrame] = []
    /// Frames the "device" sends back for one sent frame. Empty means silence.
    var respond: (GaiaFrame) -> [GaiaFrame] = { _ in [] }
    /// How long the "device" takes to answer. Zero answers on the next hop.
    var replyDelay: Duration = .zero
    /// Runs inside `send` after the frame is recorded; throwing makes `send`
    /// throw. Models a callback that fires while a write is still under way.
    var duringSend: ((GaiaFrame) throws -> Void)?

    func connect(allowWake: Bool) async throws { isOpen = true }

    func send(_ frame: GaiaFrame) throws {
        guard isOpen else { throw TransportError.notConnected }
        sent.append(frame)
        try duringSend?(frame)
        let replies = respond(frame)
        let delay = replyDelay
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            for reply in replies { self.onFrame?(reply) }
        }
    }

    func disconnect() { isOpen = false }
    func releaseLink() { isOpen = false }

    /// The channel closing under us, as `rfcommChannelClosed` reports it.
    func drop() {
        isOpen = false
        onDisconnect?()
    }

    /// Delivers a frame the device volunteers, such as a notification.
    func push(_ frame: GaiaFrame) { onFrame?(frame) }
}

/// A MOMENTUM 4's settings, for tests that compare the menu with the device.
///
/// Reads are answered with the value at the moment they are sent, and writes
/// take effect when sent, as on the real device.
final class FakeHeadset {
    var anc: UInt8 = 1
    /// `[1, anti-wind, 2, comfort, 3, adaptive]`, the only shape seen on the wire.
    var modeTable: [UInt8] = [1, 0, 2, 0, 3, 0]
    var level: UInt8 = 40
    var bass: UInt8 = 0
    var bands: [UInt8] = [0, 0, 0, 0, 0]
    /// False models firmware that rejects a single `[id, value]` mode write.
    var acceptsModePair = true
    /// Replaces the mode-table read reply, to model a misread.
    var modeTableReply: [UInt8]?
    /// How long a mode-table read takes to answer.
    var modeTableDelay: Duration = .zero
    /// The level any mode-table write leaves behind, as FW 3.37.3 does with 0.
    /// Nil leaves the level alone.
    var levelAfterModeWrite: UInt8?
    /// True models firmware that rejects a whole-table write.
    var rejectsFullTable = false
    /// Every mode-table write, as sent.
    private(set) var modeWrites: [[UInt8]] = []
    /// Device settings by getter id, as the device stores them (touch is
    /// inverted: 0 = enabled). A getter missing here answers with no payload.
    var settings: [UInt16: UInt8] = [
        Cmd.getTouchControls: 0, Cmd.getOnHead: 1, Cmd.getSmartPause: 1,
        Cmd.getAutoAnswer: 0, Cmd.getComfortCall: 0,
    ]
    /// Setting ids, getter or setter, that the device rejects.
    var rejects: Set<UInt16> = []
    /// What `0x0800` answers: AAC.
    var codec: UInt8 = 1
    /// Paired devices by index. This Mac sits at `ownIndex`.
    var paired: [(name: String, connected: Bool)] = [("MacBook", true), ("iPhone", false)]
    var ownIndex: UInt8 = 0
    var maxConnections: UInt8 = 2
    /// Replace the own-index and limit replies, to model a misread.
    var ownIndexReply: [UInt8]?
    var maxConnectionsReply: [UInt8]?
    /// Replaces the count reply, to model a misread.
    var pairedCountReply: [UInt8]?
    /// Replaces the entry reply for an index, to model a misread.
    var pairedEntryReplies: [Int: [UInt8]] = [:]
    /// How long an entry read takes to answer, by index; immediate otherwise.
    var pairedEntryDelays: [Int: Duration] = [:]
    /// Replaces every status reply, to model a misread.
    var statusReply: [UInt8]?
    /// Status polls a connect takes before the device shows connected. Nil
    /// never connects, as when the phone has forgotten the pairing.
    var pollsToConnect: Int? = 0
    /// Sends the 0x1484 pushes captured around a connect: `[i, 1]` when it
    /// comes up, `[i, 0]` twice when it never will.
    var pushesDuringConnect = false
    /// Every index a connect was sent for.
    private(set) var connects: [Int] = []
    /// Firmware as `0x1201` answers it; nil leaves it unanswered.
    var firmware: [Int]?
    /// The link change under way: the state it ends in, after so many polls.
    private var pendingConnect: (index: Int, pollsLeft: Int?, connects: Bool)?

    var mode: NoiseMode { anc == 0 ? .off : (modeTable[5] == 1 ? .adaptive : .custom) }
    var curve: [Double] { bands.map(Gain.decode) }

    /// Answers one frame. Mode-table reads with a delay arrive through `push`.
    func respond(_ frame: GaiaFrame, push: @escaping (GaiaFrame) -> Void) -> [GaiaFrame] {
        let value = frame.payload.first ?? 0
        if rejects.contains(frame.command) { return [Reply.rejected(frame.command)] }
        if let stored = settings[frame.command] { return [Reply.ok(frame.command, [stored])] }
        if settings[frame.command + 1] != nil {
            settings[frame.command + 1] = value
            return [Reply.ok(frame.command)]
        }
        switch frame.command {
        case Cmd.getAncEnabled: return [Reply.ok(frame.command, [anc])]
        case Cmd.setAncEnabled: anc = value
        case Cmd.getModeTable:
            let reply = Reply.ok(frame.command, modeTableReply ?? modeTable)
            guard modeTableDelay > .zero else { return [reply] }
            let delay = modeTableDelay
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                push(reply)
            }
            return []
        case Cmd.setModeTable:
            modeWrites.append(frame.payload)
            if frame.payload.count == 2 {
                guard acceptsModePair else { return [Reply.rejected(frame.command)] }
                if let index = modeTable.indices.first(where: { $0 % 2 == 0 && modeTable[$0] == value }) {
                    modeTable[index + 1] = frame.payload[1]
                }
            } else {
                guard !rejectsFullTable else { return [Reply.rejected(frame.command)] }
                modeTable = frame.payload
            }
            if let reset = levelAfterModeWrite { level = reset }
        case Cmd.getNoiseLevel: return [Reply.ok(frame.command, [level])]
        case Cmd.setNoiseLevel: level = value
        case Cmd.getBassBoost: return [Reply.ok(frame.command, [bass])]
        case Cmd.setBassBoost: bass = value
        case Cmd.getAllGains: return [Reply.ok(frame.command, bands)]
        case Cmd.getCodec: return [Reply.ok(frame.command, [codec])]
        case Cmd.setBandGain: bands[Int(value)] = frame.payload[1]
        case Cmd.getPairedDeviceCount:
            return [Reply.ok(frame.command, pairedCountReply ?? [0, UInt8(paired.count)])]
        case Cmd.getOwnDeviceIndex: return [Reply.ok(frame.command, ownIndexReply ?? [ownIndex])]
        case Cmd.getMaxConnections: return [Reply.ok(frame.command, maxConnectionsReply ?? [maxConnections])]
        case Cmd.getPairedDevice:
            let index = Int(value)
            let reply: GaiaFrame
            if let canned = pairedEntryReplies[index] {
                reply = Reply.ok(frame.command, canned)
            } else if index < paired.count {
                let entry = paired[index]
                // Priority equals the index in every capture; offset here so
                // a parser reading the wrong byte fails.
                reply = Reply.ok(frame.command,
                                 [value, value &+ 7, entry.connected ? 1 : 0] + Array(entry.name.utf8) + [0])
            } else {
                reply = Reply.rejected(frame.command, code: GaiaError.indexOutOfRange)
            }
            guard let delay = pairedEntryDelays[index] else { return [reply] }
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                push(reply)
            }
            return []
        case Cmd.getFirmwareVersion:
            guard let firmware else { return Reply.device(battery: 50)(frame) }
            return [Reply.ok(frame.command, firmware.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })]
        case Cmd.disconnectPairedDevice:
            guard Int(value) < paired.count else { return [Reply.rejected(frame.command)] }
            pendingConnect = (Int(value), pollsToConnect, false)
        case Cmd.connectPairedDevice:
            connects.append(Int(value))
            guard Int(value) < paired.count else { return [Reply.rejected(frame.command)] }
            pendingConnect = (Int(value), pollsToConnect, true)
            if pushesDuringConnect, pollsToConnect == nil {
                let failed = Reply.notification(Cmd.getPairedDeviceStatus, [value, 0])
                Task { @MainActor in push(failed); push(failed) }
            }
        case Cmd.getPairedDeviceStatus:
            let index = Int(value)
            guard index < paired.count else { return [Reply.rejected(frame.command, code: GaiaError.indexOutOfRange)] }
            if let pending = pendingConnect, pending.index == index, let left = pending.pollsLeft {
                if left == 0 {
                    paired[index].connected = pending.connects
                    pendingConnect = nil
                    if pushesDuringConnect {
                        let up = Reply.notification(Cmd.getPairedDeviceStatus, [value, pending.connects ? 1 : 0])
                        Task { @MainActor in push(up) }
                    }
                } else {
                    pendingConnect = (index, left - 1, pending.connects)
                }
            }
            return [Reply.ok(frame.command, statusReply ?? [value, paired[index].connected ? 1 : 0])]
        default: return Reply.device(battery: 50)(frame)
        }
        return [Reply.ok(frame.command)]
    }
}

/// Waits for every task, but gives up after `limit` and returns nil.
///
/// A caller whose continuation is lost never resumes; without a limit that
/// shows up as a hung test rather than a failure. Not a task group: a group
/// waits for all its children, including the stuck one. The loser is simply
/// abandoned.
@MainActor
func results<T>(of tasks: [Task<T, Never>], within limit: Duration) async -> [T]? {
    await withCheckedContinuation { (finish: CheckedContinuation<[T]?, Never>) in
        var settled = false
        Task { @MainActor in
            var values: [T] = []
            for task in tasks { values.append(await task.value) }
            guard !settled else { return }
            settled = true
            finish.resume(returning: values)
        }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            guard !settled else { return }
            settled = true
            finish.resume(returning: nil)
        }
    }
}

/// Builders for frames as the device sends them back.
enum Reply {
    static func ok(_ command: UInt16, _ payload: [UInt8] = []) -> GaiaFrame {
        GaiaFrame(command: command | 0x0100, payload: payload)
    }

    static func rejected(_ command: UInt16, code: UInt8 = 0x05) -> GaiaFrame {
        GaiaFrame(command: command | 0x0180, payload: [code])
    }

    static func notification(_ command: UInt16, _ payload: [UInt8]) -> GaiaFrame {
        GaiaFrame(command: command | 0x0080, payload: payload)
    }

    /// A MOMENTUM 4 on firmware 3.x with a five-band equaliser. Commands it
    /// has no canned answer for are acknowledged with an empty payload.
    static func device(battery: UInt8) -> (GaiaFrame) -> [GaiaFrame] {
        { frame in
            switch frame.command {
            case Cmd.getBattery:
                return [ok(frame.command, [battery])]
            case Cmd.getEqConfig:
                return [ok(frame.command, [5, Gain.encode(db: -6), Gain.encode(db: 6)])]
            case Cmd.getAllGains:
                return [ok(frame.command, [0, 0, 0, 0, 0])]
            case Cmd.getBandFrequency:
                return [ok(frame.command, [frame.payload.first ?? 0, 0x03, 0xE8])]
            default:
                return [ok(frame.command)]
            }
        }
    }
}
