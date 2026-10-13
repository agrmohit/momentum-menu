import Combine
import Foundation

/// The app's three-way noise control, matching what Smart Control shows.
/// On the wire this is two separate settings.
public enum NoiseMode: String, CaseIterable, Sendable {
    case off = "Off"
    case adaptive = "Adaptive"
    case custom = "Custom"

    public var explanation: String {
        switch self {
        case .off: return "Noise control disabled"
        case .adaptive: return "Headphones choose the level"
        case .custom: return "You choose the level"
        }
    }
}

public struct EqBand: Identifiable, Sendable {
    public let id: Int
    public let frequencyHz: Int
    public var gainDb: Double

    public var label: String {
        frequencyHz >= 1000
            ? String(format: "%.1fk", Double(frequencyHz) / 1000).replacingOccurrences(of: ".0k", with: "k")
            : "\(frequencyHz)"
    }
}

public struct EqPreset: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let gains: [Double]
    /// True only for curves confirmed against Smart Control's own values.
    public let verified: Bool

    /// Confirmed: Smart Control's Pop preset reads 0/20/25/15/-20 on the wire.
    public static let pop = EqPreset(name: "Pop", gains: [0, 2.0, 2.5, 1.5, -2.0], verified: true)
    public static let flat = EqPreset(name: "Flat", gains: [0, 0, 0, 0, 0], verified: true)

    /// Curves of our own, not Sennheiser's. Labelled as such in the UI.
    public static let bassLift = EqPreset(name: "Bass lift", gains: [4.0, 2.0, 0, 0, 0], verified: false)
    public static let voice = EqPreset(name: "Voice", gains: [-2.0, 0, 2.0, 2.5, 0], verified: false)
    public static let treble = EqPreset(name: "Treble", gains: [0, 0, 0, 2.0, 3.0], verified: false)

    public static let all: [EqPreset] = [.flat, .pop, .bassLift, .voice, .treble]
}

public struct DeviceState: Sendable {
    public var connected = false
    /// A connection attempt is in flight. Distinct from `connected == false`,
    /// which on its own cannot tell "no headphones here" from "working on it"
    /// — and opening the control channel can take several seconds.
    public var isConnecting = false
    public var deviceName: String?
    public var batteryPercent: Int?
    public var noiseMode: NoiseMode?
    /// nil means unknown rather than "not charging": the device only announces
    /// this when the cable changes, and offers no way to ask.
    public var isCharging: Bool?
    /// 0 = full ANC ... 100 = full transparency
    public var noiseLevel: Int?
    public var bassBoost: Bool?
    public var bands: [EqBand] = []
    public var equaliserSupported = false
    /// Gain limits as the device reports them in 0x1000, not as we assume.
    /// A MOMENTUM 4 on 3.38.3 allows ±6.0 dB, well inside what the int8
    /// encoding could carry.
    public var eqMinGainDb: Double = -6
    public var eqMaxGainDb: Double = 6
    public var firmware: String?
    /// Major version, so features can be gated on it. The parametric equaliser
    /// and bass boost exist only from firmware 3.x.
    public var firmwareMajor: Int?
    /// Set when the user asked to hand the headphones over to another device.
    /// Stops the app's background poll from quietly grabbing them back.
    public var releasedByUser = false
    public var lastError: String?

    /// True when the device is running firmware old enough to lack the
    /// equaliser entirely.
    public var needsFirmwareUpdateForEq: Bool {
        guard let major = firmwareMajor else { return false }
        return major < 3
    }
}

/// Read-only view of what macOS knows about paired Bluetooth devices.
public enum BluetoothDiagnostics {
    public static func inventory() -> String { RFCOMMTransport.inventory() }

    /// Channels 1 and 2 are where GAIA has been seen; 14 is the other
    /// RFCOMM service this device advertises. Hands-Free (10) is left alone.
    public static func probeChannels() async -> String {
        await RFCOMMTransport().probeChannels([1, 2, 14])
    }
}

/// Talks to a MOMENTUM 4 over GAIA and keeps a view of its state.
@MainActor
public final class HeadphoneController: ObservableObject {

    @Published public private(set) var state = DeviceState()

    private let transport = RFCOMMTransport()
    /// In-flight requests by command id, each tagged with a sequence number.
    ///
    /// The tag matters: a timeout fires on a timer that is not cancelled when
    /// the reply arrives, so without it a finished request's timer would later
    /// find a *different* request under the same command id and fail it. That
    /// is what made applying an equaliser preset — five 0x1001 writes in a row
    /// — flash "the headphones did not answer".
    private var pending: [UInt16: (sequence: UInt64, continuation: CheckedContinuation<[UInt8], Error>)] = [:]
    private var nextSequence: UInt64 = 0
    private var modeWriteFormat: ModeWriteFormat = .unknown

    public init() {
        transport.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame) }
        }
        transport.onDisconnect = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.failAllPending(TransportError.notConnected)
                self.state.connected = false
            }
        }
    }

    // MARK: - Connection

    /// - Parameter userInitiated: true when the user asked for this. Background
    ///   polling passes false, so that after a deliberate hand-off the app does
    ///   not reconnect a second later and take the slot straight back.
    public func connect(userInitiated: Bool = false) async {
        if state.releasedByUser {
            guard userInitiated else { return }
            state.releasedByUser = false
        }
        // Also guards against overlapping attempts: the poll timer and the
        // popover can both ask at once, and two opens racing on one channel
        // is nobody's idea of a good time.
        guard !state.connected, !state.isConnecting else { return }
        state.isConnecting = true
        defer { state.isConnecting = false }

        do {
            // Only a deliberate action may wake the headphones onto this Mac.
            // This now returns once the channel has actually opened, rather
            // than once the request was accepted.
            try await transport.connect(allowWake: userInitiated)
            state.connected = transport.isOpen
            state.deviceName = transport.deviceName
            state.lastError = nil
            if state.connected { await refresh() }
        } catch {
            state.connected = false
            state.lastError = error.localizedDescription
        }
    }

    /// Closes the control channel only. The headphones stay connected to this
    /// Mac and audio is unaffected. Used when the app quits.
    public func disconnect() {
        transport.disconnect()
        state.connected = false
    }

    /// Hands the headphones over: drops the Mac's Bluetooth link entirely so
    /// one of the two multipoint slots is freed for another device.
    ///
    /// The app will not reconnect on its own afterwards — reclaiming the slot
    /// it was just asked to give up would defeat the purpose. Use
    /// `connect(userInitiated: true)` to take it back.
    public func releaseHeadphones() {
        failAllPending(TransportError.notConnected)
        transport.releaseLink()
        state.connected = false
        state.releasedByUser = true
        state.batteryPercent = nil
        state.lastError = nil
    }

    // MARK: - Reading

    /// Reads each property independently.
    ///
    /// These deliberately do not share a do/catch. An earlier version ran them
    /// as one throwing sequence, and on firmware 2.x the equaliser's rejection
    /// aborted the rest — firmware version and bass boost were never asked for
    /// at all, and the app reported them as unknown when the device would have
    /// answered both. One unsupported feature must not hide the others.
    public func refresh() async {
        guard state.connected else { return }

        state.batteryPercent = (try? await request(Cmd.getBattery).first).map { Int($0) }

        if let anc = try? await request(Cmd.getAncEnabled).first {
            let table = try? await request(Cmd.getModeTable)
            let adaptive = table.flatMap { Self.modeValue(in: $0, id: Cmd.modeAdaptive) } == 1
            state.noiseMode = anc != 0 ? (adaptive ? .adaptive : .custom) : .off
        }
        state.noiseLevel = (try? await request(Cmd.getNoiseLevel).first).map { Int($0) }

        if let version = try? await request(Cmd.getFirmwareVersion), version.count >= 6 {
            let parts = stride(from: 0, to: 6, by: 2).map { Int(version[$0]) << 8 | Int(version[$0 + 1]) }
            state.firmware = parts.map(String.init).joined(separator: ".")
            state.firmwareMajor = parts.first
        }

        await refreshEqualiser()

        // Bass boost arrived with firmware 3.x and is rejected outright on 2.x,
        // so a failure here means "not on this firmware", not "broken".
        state.bassBoost = (try? await request(Cmd.getBassBoost).first).map { $0 != 0 }

        state.lastError = nil
    }

    private func refreshEqualiser() async {
        // The parametric equaliser is a firmware 3.x feature. On 2.x these ids
        // are rejected, which is a fact about the device rather than an error
        // worth showing the user as one.
        guard let config = try? await request(Cmd.getEqConfig),
              let gains = try? await request(Cmd.getAllGains, payload: [0]) else {
            state.bands = []
            state.equaliserSupported = false
            return
        }

        let bandCount = Int(config.first ?? 5)
        guard bandCount > 0, bandCount <= 16 else {
            state.bands = []
            state.equaliserSupported = false
            return
        }

        // [bands, min i8, max i8, ...] — the device states its own range.
        if config.count >= 3 {
            let minimum = Gain.decode(config[1])
            let maximum = Gain.decode(config[2])
            if minimum < maximum {
                state.eqMinGainDb = minimum
                state.eqMaxGainDb = maximum
            }
        }

        var bands: [EqBand] = []
        for index in 0..<bandCount {
            var hz = 0
            if let reply = try? await request(Cmd.getBandFrequency, payload: [UInt8(index)]), reply.count >= 3 {
                hz = Int(reply[1]) << 8 | Int(reply[2])
            }
            let gain = index < gains.count ? Gain.decode(gains[index]) : 0
            bands.append(EqBand(id: index, frequencyHz: hz, gainDb: gain))
        }
        state.bands = bands
        state.equaliserSupported = true
    }

    // MARK: - Writing

    public func setNoiseMode(_ mode: NoiseMode) async {
        do {
            switch mode {
            case .off:
                _ = try await request(Cmd.setAncEnabled, payload: [0])
            case .adaptive:
                _ = try await request(Cmd.setAncEnabled, payload: [1])
                try await writeMode(id: Cmd.modeAdaptive, value: 1)
            case .custom:
                _ = try await request(Cmd.setAncEnabled, payload: [1])
                try await writeMode(id: Cmd.modeAdaptive, value: 0)
            }
            state.noiseMode = mode
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    public func setNoiseLevel(_ level: Int) async {
        let clamped = UInt8(max(0, min(100, level)))
        do {
            _ = try await request(Cmd.setNoiseLevel, payload: [clamped])
            state.noiseLevel = Int(clamped)
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    public func setBandGain(band: Int, db: Double) async {
        // Respect the device's own limits rather than the encoding's.
        let clamped = max(state.eqMinGainDb, min(state.eqMaxGainDb, db))
        do {
            _ = try await request(Cmd.setBandGain, payload: [UInt8(band), Gain.encode(db: clamped)])
            if let index = state.bands.firstIndex(where: { $0.id == band }) {
                state.bands[index].gainDb = clamped
            }
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    /// Applies a whole curve.
    ///
    /// The device takes one band per command, so the writes are sequential —
    /// but the displayed curve is updated in one go first. Updating it as each
    /// write lands made the sliders step across the popover one at a time,
    /// which looks like five separate changes rather than one preset.
    public func apply(_ preset: EqPreset) async {
        let targets = preset.gains.prefix(state.bands.count).map {
            max(state.eqMinGainDb, min(state.eqMaxGainDb, $0))
        }

        for (index, gain) in targets.enumerated() {
            state.bands[index].gainDb = gain
        }

        for (index, gain) in targets.enumerated() {
            do {
                _ = try await request(Cmd.setBandGain,
                                      payload: [UInt8(index), Gain.encode(db: gain)])
            } catch {
                // The shown curve is now a promise we failed to keep, so take
                // the device's word for it rather than leaving a lie on screen.
                state.lastError = error.localizedDescription
                await refreshEqualiser()
                return
            }
        }
        state.lastError = nil
    }

    public func setBassBoost(_ enabled: Bool) async {
        do {
            _ = try await request(Cmd.setBassBoost, payload: [enabled ? 1 : 0])
            state.bassBoost = enabled
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    /// Writes one entry of the 0x1A01 mode table.
    ///
    /// The two reference implementations disagree about what this command
    /// accepts: one sends a bare [id, value] pair, the other says the device
    /// rejects partial writes and needs the whole table back. We try the short
    /// form once, and on a rejection fall back to read-modify-write and
    /// remember that for the rest of the session.
    private func writeMode(id: UInt8, value: UInt8) async throws {
        if modeWriteFormat != .fullTable {
            do {
                _ = try await request(Cmd.setModeTable, payload: [id, value])
                modeWriteFormat = .singlePair
                return
            } catch let error as TransportError {
                guard case .deviceRejected = error else { throw error }
                modeWriteFormat = .fullTable
            }
        }

        var table = try await request(Cmd.getModeTable)
        guard table.count >= 2, table.count % 2 == 0 else { return }
        var index = 0
        while index + 1 < table.count {
            if table[index] == id { table[index + 1] = value }
            index += 2
        }
        _ = try await request(Cmd.setModeTable, payload: table)
    }

    private static func modeValue(in table: [UInt8], id: UInt8) -> UInt8? {
        var index = 0
        while index + 1 < table.count {
            if table[index] == id { return table[index + 1] }
            index += 2
        }
        return nil
    }

    // MARK: - Request plumbing

    @discardableResult
    func request(_ command: UInt16, payload: [UInt8] = [], timeout: Duration = .seconds(2)) async throws -> [UInt8] {
        if let reason = CommandSafety.rejectionReason(for: command) {
            throw TransportError.blockedCommand(reason: reason)
        }
        if let stale = pending.removeValue(forKey: command) {
            stale.continuation.resume(throwing: TransportError.timedOut(command: command))
        }

        nextSequence += 1
        let sequence = nextSequence

        return try await withCheckedThrowingContinuation { continuation in
            pending[command] = (sequence, continuation)
            do {
                try transport.send(GaiaFrame(command: command, payload: payload))
            } catch {
                pending.removeValue(forKey: command)?.continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self,
                      let waiting = self.pending[command],
                      waiting.sequence == sequence else { return }   // not ours any more
                self.pending.removeValue(forKey: command)
                waiting.continuation.resume(throwing: TransportError.timedOut(command: command))
            }
        }
    }

    private func handle(_ frame: GaiaFrame) {
        guard let kind = frame.responseKind else { return }
        switch kind {
        case .notification:
            applyNotification(frame)
        case .success:
            pending.removeValue(forKey: frame.baseCommand)?
                .continuation.resume(returning: frame.payload)
        case .error:
            pending.removeValue(forKey: frame.baseCommand)?
                .continuation.resume(throwing: TransportError.deviceRejected(
                    command: frame.baseCommand,
                    code: frame.payload.first ?? 0))
        }
    }

    /// The device volunteers some state changes; keep the menu honest when the
    /// phone app or the headset's own buttons change something.
    private func applyNotification(_ frame: GaiaFrame) {
        switch frame.baseCommand {
        case Cmd.getBattery:
            if let value = frame.payload.first { state.batteryPercent = Int(value) }
        case Cmd.getNoiseLevel:
            if let value = frame.payload.first { state.noiseLevel = Int(value) }
        case Cmd.getAncEnabled:
            if let value = frame.payload.first, value == 0 { state.noiseMode = .off }
        case Cmd.chargingNotification:
            if let value = frame.payload.first {
                state.isCharging = value != 0
                // Charge moves while plugged in, so stop showing a stale figure.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.state.connected else { return }
                    self.state.batteryPercent =
                        (try? await self.request(Cmd.getBattery).first).map { Int($0) }
                }
            }
        default:
            break
        }
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting { entry.continuation.resume(throwing: error) }
    }

    // MARK: - Diagnostics

    /// Read-only probe of a handful of ids with both payload forms.
    ///
    /// Several getters on this device reject an empty payload with 0x05 and
    /// answer the same id happily when given one dummy byte. The error form is
    /// indistinguishable from "unsupported", so the only way to tell them
    /// apart is to ask twice. Sends no writes.
    public func diagnose() async -> String {
        let probes: [(UInt16, String)] = [
            (Cmd.getEqConfig, "0x1000 EQ config"),
            (Cmd.getAllGains, "0x1003 EQ gains"),
            (Cmd.getBandGain, "0x1002 band 0 gain"),
            (Cmd.getBandFrequency, "0x100B band 0 freq"),
            (Cmd.getBassBoost, "0x1009 bass boost"),
            (Cmd.getFirmwareVersion, "0x1201 firmware"),
            (Cmd.getTouchControls, "0x1607 touch"),
        ]

        var lines: [String] = []
        for (command, label) in probes {
            var results: [String] = []
            for payload in [[], [UInt8(0)]] {
                let form = payload.isEmpty ? "empty" : "[00] "
                do {
                    let reply = try await request(command, payload: payload)
                    let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    results.append("\(form) -> \(hex.isEmpty ? "(no payload)" : hex)")
                } catch let error as TransportError {
                    if case .deviceRejected(_, let code) = error {
                        results.append(String(format: "\(form) -> rejected 0x%02X", code))
                    } else {
                        results.append("\(form) -> \(error.localizedDescription)")
                    }
                } catch {
                    results.append("\(form) -> \(error.localizedDescription)")
                }
            }
            lines.append("\(label.padding(toLength: 22, withPad: " ", startingAt: 0))  \(results.joined(separator: "   |   "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Read-only sweep of everything we know how to ask for, for `--probe`.
    public func probeReport() async -> String {
        var lines: [String] = []
        lines.append("Device:   \(state.deviceName ?? "unknown")")
        lines.append("Firmware: \(state.firmware ?? "unknown")")
        lines.append("Battery:  \(state.batteryPercent.map { "\($0)%" } ?? "unknown")")
        lines.append("Noise:    \(state.noiseMode?.rawValue ?? "unknown") at level \(state.noiseLevel.map(String.init) ?? "?")")
        lines.append("Bass:     \(state.bassBoost.map { $0 ? "on" : "off" } ?? "not on this firmware (needs 3.x)")")
        if state.bands.isEmpty {
            lines.append("EQ:       " + (state.needsFirmwareUpdateForEq
                                         ? "not on this firmware (added in 3.x)"
                                         : "not available"))
        } else {
            let curve = state.bands.map { "\($0.label)Hz \(String(format: "%+.1f", $0.gainDb))dB" }
            lines.append("EQ:       " + curve.joined(separator: "  "))
        }
        if let touch = try? await request(Cmd.getTouchControls).first {
            // Inverted on this device: 0 means enabled.
            lines.append("Touch:    \(touch == 0 ? "enabled" : "disabled")")
        }
        if let error = state.lastError { lines.append("Last error: \(error)") }
        return lines.joined(separator: "\n")
    }
}
