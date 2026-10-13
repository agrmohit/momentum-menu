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
    public var deviceName: String?
    public var batteryPercent: Int?
    public var noiseMode: NoiseMode?
    /// 0 = full ANC ... 100 = full transparency
    public var noiseLevel: Int?
    public var bassBoost: Bool?
    public var bands: [EqBand] = []
    public var firmware: String?
    public var lastError: String?
}

/// Talks to a MOMENTUM 4 over GAIA and keeps a view of its state.
@MainActor
public final class HeadphoneController: ObservableObject {

    @Published public private(set) var state = DeviceState()

    private let transport = RFCOMMTransport()
    private var pending: [UInt16: CheckedContinuation<[UInt8], Error>] = [:]
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

    public func connect() async {
        guard !state.connected else { return }
        do {
            try transport.connect()
            // The channel reports open asynchronously; give it a moment.
            try await Task.sleep(for: .milliseconds(400))
            state.connected = transport.isOpen
            state.deviceName = transport.deviceName
            state.lastError = nil
            if state.connected { await refresh() }
        } catch {
            state.connected = false
            state.lastError = error.localizedDescription
        }
    }

    public func disconnect() {
        transport.disconnect()
        state.connected = false
    }

    // MARK: - Reading

    public func refresh() async {
        guard state.connected else { return }
        do {
            state.batteryPercent = Int(try await request(Cmd.getBattery).first ?? 0)

            let ancOn = (try await request(Cmd.getAncEnabled).first ?? 0) != 0
            let table = try await request(Cmd.getModeTable)
            let adaptive = Self.modeValue(in: table, id: Cmd.modeAdaptive) == 1
            state.noiseMode = ancOn ? (adaptive ? .adaptive : .custom) : .off
            state.noiseLevel = Int(try await request(Cmd.getNoiseLevel).first ?? 0)

            try await refreshEqualiser()

            // Rejected on firmware 2.x; absence is not an error.
            state.bassBoost = (try? await request(Cmd.getBassBoost).first).map { $0 != 0 }

            if let version = try? await request(Cmd.getFirmwareVersion), version.count >= 6 {
                let parts = stride(from: 0, to: 6, by: 2).map { Int(version[$0]) << 8 | Int(version[$0 + 1]) }
                state.firmware = parts.map(String.init).joined(separator: ".")
            }
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    private func refreshEqualiser() async throws {
        let config = try await request(Cmd.getEqConfig)
        let bandCount = Int(config.first ?? 5)
        guard bandCount > 0, bandCount <= 16 else { return }

        // 0x1003 needs *some* payload byte; an empty one is rejected.
        let gains = try await request(Cmd.getAllGains, payload: [0])

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
        do {
            _ = try await request(Cmd.setBandGain, payload: [UInt8(band), Gain.encode(db: db)])
            if let index = state.bands.firstIndex(where: { $0.id == band }) {
                state.bands[index].gainDb = db
            }
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    public func apply(_ preset: EqPreset) async {
        for (index, gain) in preset.gains.enumerated() where index < state.bands.count {
            await setBandGain(band: index, db: gain)
        }
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
            stale.resume(throwing: TransportError.timedOut(command: command))
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[command] = continuation
            do {
                try transport.send(GaiaFrame(command: command, payload: payload))
            } catch {
                pending.removeValue(forKey: command)?.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                self.pending.removeValue(forKey: command)?
                    .resume(throwing: TransportError.timedOut(command: command))
            }
        }
    }

    private func handle(_ frame: GaiaFrame) {
        guard let kind = frame.responseKind else { return }
        switch kind {
        case .notification:
            applyNotification(frame)
        case .success:
            pending.removeValue(forKey: frame.baseCommand)?.resume(returning: frame.payload)
        case .error:
            pending.removeValue(forKey: frame.baseCommand)?
                .resume(throwing: TransportError.deviceRejected(
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
        default:
            break
        }
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
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
        lines.append("Bass:     \(state.bassBoost.map { $0 ? "on" : "off" } ?? "unsupported on this firmware")")
        if state.bands.isEmpty {
            lines.append("EQ:       not readable")
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
