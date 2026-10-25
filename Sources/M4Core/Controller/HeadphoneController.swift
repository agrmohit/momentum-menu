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

/// Byte 1 of the mode table. Three states, so "on" is not one of them:
/// writing 1 for on would silently replace Auto with Max.
public enum AntiWind: UInt8, Sendable {
    case off = 0
    case max = 1
    case auto = 2

    /// In the order Smart Control shows them.
    public static let shown: [AntiWind] = [.off, .auto, .max]

    public var label: String {
        switch self {
        case .off: return "Off"
        case .max: return "Max"
        case .auto: return "Auto"
        }
    }
}

/// An on/off setting stored on the headphones. The device never announces a
/// change to one, so it is read on refresh and when the popover opens.
public enum DeviceSetting: CaseIterable, Sendable {
    case touchControls
    case onHeadDetection
    case smartPause
    case autoAnswer
    case comfortCalls

    var getter: UInt16 {
        switch self {
        case .touchControls: return Cmd.getTouchControls
        case .onHeadDetection: return Cmd.getOnHead
        case .smartPause: return Cmd.getSmartPause
        case .autoAnswer: return Cmd.getAutoAnswer
        case .comfortCalls: return Cmd.getComfortCall
        }
    }

    var setter: UInt16 {
        switch self {
        case .touchControls: return Cmd.setTouchControls
        case .onHeadDetection: return Cmd.setOnHead
        case .smartPause: return Cmd.setSmartPause
        case .autoAnswer: return Cmd.setAutoAnswer
        case .comfortCalls: return Cmd.setComfortCall
        }
    }

    /// Touch controls store 0 for enabled.
    var isInverted: Bool { self == .touchControls }

    /// Needs on-head detection to do anything.
    public var needsOnHead: Bool { self == .smartPause || self == .autoAnswer }

    public var label: String {
        switch self {
        case .touchControls: return "Touch controls"
        case .onHeadDetection: return "On-head detection"
        case .smartPause: return "Smart Pause"
        case .autoAnswer: return "Auto-answer calls"
        case .comfortCalls: return "Comfort Calls"
        }
    }

    public var explanation: String {
        switch self {
        case .touchControls: return "The touch pad on the right ear cup"
        case .onHeadDetection: return "Senses when the headphones are put on or taken off"
        case .smartPause: return "Pauses playback when the headphones are taken off"
        case .autoAnswer: return "Answers a call when the headphones are put on"
        case .comfortCalls: return "A more natural sound during calls"
        }
    }
}

/// Smart Control's `Sound_CodecUsed` names, by value (`m4.json`).
enum AudioCodec {
    static let names = ["SBC", "AAC", "aptX", "aptX LL", "MP3", "aptX HD",
                        "FastStream", "LHDC", "aptX Adaptive", "aptX Lossless", "LC3"]
    static let none: UInt8 = 0xFF
}

public struct EqBand: Identifiable, Sendable {
    public let id: Int
    public let frequencyHz: Int
    public var gainDb: Double

    /// Smart Control's label for the first five bands, the real centre after.
    /// The device's own centres read 90, 325, 1500, 6500 and 6500 Hz, so two
    /// sliders would share a label.
    public var label: String {
        if id < Self.smartControlLabels.count { return Self.smartControlLabels[id] }
        return frequencyHz >= 1000
            ? String(format: "%.1fk", Double(frequencyHz) / 1000).replacingOccurrences(of: ".0k", with: "k")
            : "\(frequencyHz)"
    }

    private static let smartControlLabels = ["63", "250", "1k", "4k", "8k"]
}

public struct EqPreset: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let gains: [Double]
    /// True only for curves confirmed against Smart Control's own values.
    public let verified: Bool

    /// Smart Control's presets, as transcribed from the app in
    /// omarchy-momentum4's `presets.json`. The device stores only the active
    /// curve; the app ticks a preset whose exact curve is written.
    public static let sennheiser: [EqPreset] = [
        EqPreset(name: "Neutral", gains: [0, 0, 0, 0, 0], verified: true),
        EqPreset(name: "Rock", gains: [0, 2, 2.5, 1.5, -2], verified: true),
        EqPreset(name: "Pop", gains: [0, -2.5, 0, 2.5, 0], verified: true),
        EqPreset(name: "Dance", gains: [3.5, 2, -1.5, 1.5, 3], verified: true),
        EqPreset(name: "Hip-Hop", gains: [3, 1.5, -1.5, 0, -1.5], verified: true),
        EqPreset(name: "Classical", gains: [-2, -1.5, 0, 3.5, 4], verified: true),
        EqPreset(name: "Movie", gains: [0, 0, 2, 2, -2], verified: true),
        EqPreset(name: "Jazz", gains: [-3.2, 0, 2.2, 2.2, 0], verified: true),
    ]

    /// Curves of our own, not Sennheiser's. Labelled as such in the UI.
    public static let own: [EqPreset] = [
        EqPreset(name: "Bass lift", gains: [4.0, 2.0, 0, 0, 0], verified: false),
        EqPreset(name: "Voice", gains: [-2.0, 0, 2.0, 2.5, 0], verified: false),
        EqPreset(name: "Treble", gains: [0, 0, 0, 2.0, 3.0], verified: false),
    ]

    public static let all: [EqPreset] = sennheiser + own

    /// The preset whose curve the device holds, compared in the device's
    /// 0.1 dB steps. Nil for a hand-made curve.
    public static func matching(_ gains: [Double]) -> EqPreset? {
        let tenths = { (curve: [Double]) in curve.map { Int(($0 * 10).rounded()) } }
        return all.first { tenths($0.gains) == tenths(gains) }
    }
}

/// One entry in the headphones' list of paired devices.
public struct PairedDevice: Identifiable, Equatable, Sendable {
    /// Position in the headphones' list. Not stable: the list can reorder
    /// when a device reconnects.
    public let index: Int
    public let name: String
    public let isConnected: Bool
    /// The device this app talks through.
    public let isThisMac: Bool

    public var id: Int { index }
}

/// A change to one paired device, by the name the user clicked.
public enum PairedAction: Equatable, Sendable {
    case connecting(String)
    case disconnecting(String)

    public var deviceName: String {
        switch self {
        case .connecting(let name), .disconnecting(let name): return name
        }
    }
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
    public var antiWind: AntiWind?
    /// nil means unknown rather than "not charging": the device only announces
    /// this when the cable changes, and offers no way to ask.
    public var isCharging: Bool?
    /// 0 = full ANC ... 100 = full transparency
    public var noiseLevel: Int?
    /// The playing stream's codec, raw; see `AudioCodec`.
    public var codec: UInt8?
    /// Hz; 0 when the stream has stopped.
    public var sampleRateHz: Int?
    public var bassBoost: Bool?
    /// True means on (touch controls: enabled). Missing means unknown, or
    /// not on this firmware.
    public var settings: [DeviceSetting: Bool] = [:]
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
    /// [major, minor, patch], e.g. [3, 38, 3].
    public var firmwareVersion: [Int]?
    /// Set when the user asked to hand the headphones over to another device.
    /// Stops the app's background poll from quietly grabbing them back.
    public var releasedByUser = false
    public var lastError: String?
    /// Nil until read, or when the last read failed.
    public var pairedDevices: [PairedDevice]?
    /// How many devices can be connected at once; 2 on a MOMENTUM 4.
    public var maxConnections: Int?
    /// The connect or disconnect under way, if any. One at a time.
    public var pairedAction: PairedAction?

    /// Plugged in and full. Worth distinguishing: "Charging" at 100% reads as
    /// something still being done.
    public var isFullyCharged: Bool {
        isCharging == true && (batteryPercent ?? 0) >= 100
    }

    /// "Charging", "Charged", or nothing at all when running on battery.
    public var chargeLabel: String? {
        guard isCharging == true else { return nil }
        return isFullyCharged ? "Charged" : "Charging"
    }

    /// "AAC · 44.1 kHz", or nil when nothing is playing or the codec is unknown.
    public var streamLabel: String? {
        guard let name = codecName else { return nil }
        guard let rate = sampleRateLabel else { return name }
        return "\(name) · \(rate)"
    }

    /// "AAC", or nil when nothing is playing or the codec is unknown.
    public var codecName: String? {
        guard let codec, codec != AudioCodec.none else { return nil }
        return Int(codec) < AudioCodec.names.count ? AudioCodec.names[Int(codec)] : "Codec \(codec)"
    }

    /// "44.1 kHz", or nil while no stream is running.
    public var sampleRateLabel: String? {
        guard codecName != nil, let rate = sampleRateHz, rate > 0 else { return nil }
        return String(format: "%g kHz", Double(rate) / 1000)
    }

    /// "Also on iPhone", "Only this Mac" or "Connecting iPad"; nil while the
    /// list is unknown.
    public var pairedSummary: String? {
        switch pairedAction {
        case .connecting(let name): return "Connecting \(name)"
        case .disconnecting(let name): return "Disconnecting \(name)"
        case nil: break
        }
        guard let devices = pairedDevices else { return nil }
        let others = devices.filter { $0.isConnected && !$0.isThisMac }.map(\.name)
        return others.isEmpty ? "Only this Mac" : "Also on \(others.joined(separator: ", "))"
    }

    /// Every slot is in use, so connecting another device would need one
    /// disconnected first, which the app cannot do. False while unknown.
    public var connectionSlotsFull: Bool {
        guard let devices = pairedDevices, let max = maxConnections else { return false }
        return devices.filter(\.isConnected).count >= max
    }

    /// 0x1403 only disconnects from FW 3.38.3 (momentum4-control captures);
    /// on 2.13.42 it erased a pairing, and nothing between was tested.
    public var canDisconnectOthers: Bool {
        guard let version = firmwareVersion else { return false }
        return !version.lexicographicallyPrecedes(Self.firstSafeDisconnectFirmware)
    }

    static let firstSafeDisconnectFirmware = [3, 38, 3]

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
    @MainActor
    public static func probeChannels() async -> String {
        await RFCOMMTransport().probeChannels([1, 2, 14])
    }
}

/// Talks to a MOMENTUM 4 over GAIA and keeps a view of its state.
@MainActor
public final class HeadphoneController: ObservableObject {

    @Published public private(set) var state = DeviceState()

    /// Every frame the device sends, for diagnostics. Set before connecting.
    public var frameLogger: ((String) -> Void)?

    private let transport: GaiaTransport
    /// Requests awaiting their reply, at most one per command id, each tagged
    /// with a sequence number.
    ///
    /// One per command because a GAIA reply names only the command, not the
    /// request. Two requests in flight for the same command cannot be told
    /// apart, and the second would take the first one's answer. Different
    /// commands can overlap, so a click never waits behind an unrelated read.
    ///
    /// The tag matters too: a timeout fires on a timer that is not cancelled
    /// when the reply arrives, so without it a finished request's timer would
    /// later find a *different* request and fail it.
    private var inFlight: [UInt16: (sequence: UInt64, continuation: CheckedContinuation<[UInt8], Error>)] = [:]
    private var nextSequence: UInt64 = 0
    /// The last request queued for each command. Each waits for the one before it.
    private var lastRequest: [UInt16: Task<Void, Never>] = [:]
    private var modeWriteFormat: ModeWriteFormat = .unknown
    /// The last mode-table edit queued. Each waits for the one before it,
    /// because an edit reads the table and writes it back: two at once would
    /// each write back the other's stale entry.
    private var lastModeTableEdit: Task<Void, Never>?
    /// Presets still being written. While any are, equaliser pushes are
    /// ignored: they are the device echoing a partially applied curve, which is
    /// not worth showing anyone. A count, not a flag, because presets can
    /// overlap and the first to finish must not unmute the echoes of the rest.
    private var presetsBeingApplied = 0
    /// User changes to noise mode, level or bass that have finished.
    ///
    /// User changes finished so far, per field they can change.
    ///
    /// `refresh()` keeps a reading only if no change to that field finished
    /// since its read went out. Otherwise the device may have answered before
    /// the user's write landed, and the stale answer would overwrite the
    /// user's choice. A change that finishes later sets its own state last, so
    /// it wins without help. Other fields' readings are kept.
    private var changesFinished: [Field: Int] = [:]

    private enum Field: Hashable {
        /// The noise mode and anti-wind: both come from the mode table.
        case noiseMode
        case noiseLevel
        case bassBoost
        case setting(DeviceSetting)
    }

    private func finished(_ fields: Field...) {
        for field in fields { changesFinished[field, default: 0] += 1 }
    }
    /// Noise-mode clicks so far. Each click keeps its number to tell whether a
    /// newer one has started since.
    private var noiseModeClicks = 0
    /// Equaliser edits (presets and slider moves) so far, and which edit last
    /// claimed each band. The latest edit of a band is the only one that
    /// writes it or shows it.
    private var equaliserEdits = 0
    private var bandOwner: [Int: Int] = [:]
    /// Band writes sent and not yet answered. A gains read sent while any is
    /// out may answer with the curve from before them.
    private var bandWritesInFlight = 0
    /// Paired-device list reads started so far. Only the newest is shown: an
    /// older one can finish later when the list shrank meanwhile.
    private var pairedListReads = 0
    /// How often a connect asks whether the device is up, and for how long.
    /// Captures show it up 2.9 s after the connect.
    var peerPollInterval: Duration = .milliseconds(300)
    var peerConnectTimeout: Duration = .seconds(8)

    public convenience init() {
        self.init(transport: RFCOMMTransport())
    }

    init(transport: GaiaTransport) {
        self.transport = transport
        transport.onFrame = { [weak self] frame in
            MainActor.assumeIsolated {
                self?.log(frame)
                self?.handle(frame)
            }
        }
        transport.onDisconnect = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.links += 1
                self.failAllPending(TransportError.notConnected)
                self.markDisconnected()
            }
        }
    }

    /// Bumped whenever the link ends: a release, a quit or a drop. A connect
    /// that sees it change across an await has been overtaken and stops.
    private var links = 0

    /// The device's adaptive mode-table entry (1 Adaptive, 0 Custom) as last
    /// read, pushed or written; nil when unknown. The ANC flag says only on or
    /// off, so this is what tells Adaptive from Custom when ANC comes on.
    private var knownAdaptive: UInt8?

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
        let link = links

        do {
            // Only a deliberate action may wake the headphones onto this Mac.
            // This now returns once the channel has actually opened, rather
            // than once the request was accepted.
            try await transport.connect(allowWake: userInitiated)
            guard link == links else { return abandon() }
            guard transport.isOpen else { return }
            state.deviceName = transport.deviceName
            state.lastError = nil
            // Subscribing below is the first write. Other Sennheiser models
            // share the GAIA service but not this command map. Not connected
            // until then: the popover shows its controls once connected.
            let isMomentum4 = await isMomentum4()
            guard link == links else { return abandon() }
            guard isMomentum4 else {
                transport.disconnect()
                state.lastError = "These headphones are not a MOMENTUM 4, so the app leaves them alone."
                return
            }
            state.connected = true
            await registerForNotifications()
            await refresh()
            // Connected and shown by now; the list is extra and need not
            // keep the menu-bar icon pulsing.
            state.isConnecting = false
            await refreshPairedDevices()
        } catch {
            guard link == links else { return abandon() }
            state.connected = false
            state.lastError = error.localizedDescription
        }
    }

    /// Ends a connect the user or the link overtook. The transport may have
    /// opened a channel anyway, so close it again; a release lets go of the
    /// whole link once more.
    private func abandon() {
        if state.releasedByUser { transport.releaseLink() } else { transport.disconnect() }
        state.connected = false
    }

    /// Closes the control channel only. The headphones stay connected to this
    /// Mac and audio is unaffected. Used when the app quits.
    public func disconnect() {
        links += 1
        // The transport closes without its disconnect callback, so nothing
        // else would release a caller still waiting on a reply.
        failAllPending(TransportError.notConnected)
        transport.disconnect()
        markDisconnected()
    }

    /// The battery and charge readings belong to the link that just closed.
    /// The popover shows the battery whenever it is set, so keeping them would
    /// present a stale figure as live.
    private func markDisconnected() {
        state.connected = false
        state.batteryPercent = nil
        state.isCharging = nil
        state.codec = nil
        state.sampleRateHz = nil
        state.pairedDevices = nil
        state.maxConnections = nil
        // The phone may change the mode while this Mac is away.
        knownAdaptive = nil
    }

    /// Hands the headphones over: drops the Mac's Bluetooth link entirely so
    /// one of the two multipoint slots is freed for another device.
    ///
    /// The app will not reconnect on its own afterwards — reclaiming the slot
    /// it was just asked to give up would defeat the purpose. Use
    /// `connect(userInitiated: true)` to take it back.
    public func releaseHeadphones() {
        links += 1
        failAllPending(TransportError.notConnected)
        transport.releaseLink()
        markDisconnected()
        state.releasedByUser = true
        state.lastError = nil
    }

    /// True when the connected device is a MOMENTUM 4: its model id's first
    /// word is "M4AEBT". Only when it does not answer the model id, as older
    /// firmware may not, does the device name decide.
    private func isMomentum4() async -> Bool {
        if let reply = try? await request(Cmd.getModelId), !reply.isEmpty {
            let model = String(decoding: reply.prefix { $0 != 0 }, as: UTF8.self)
            return model.split(separator: " ").first == Substring(Cmd.momentum4ModelPrefix)
        }
        return transport.deviceName?.contains(RFCOMMTransport.deviceNameMarker) == true
    }

    // MARK: - Reading

    /// Subscribes to the features whose pushes we act on.
    ///
    /// The device sends nothing to a client that has not asked. That is why
    /// charging appeared undetectable: it is announced, but only to
    /// subscribers, and we were not one. Battery (3) carries the charging
    /// push, audio (4) the codec and sample rate, device management (10)
    /// paired devices connecting; the rest keep the menu honest when the
    /// phone app or the headset's own controls change something.
    ///
    /// Failures are ignored: an unsupported feature is not a reason to refuse
    /// to connect.
    private func registerForNotifications() async {
        for feature in [Cmd.Feature.battery, Cmd.Feature.audio, Cmd.Feature.anc,
                        Cmd.Feature.userEq, Cmd.Feature.transparency, Cmd.Feature.deviceManagement] {
            _ = try? await request(Cmd.registerNotification,
                                   payload: [feature],
                                   timeout: .seconds(1))
        }
    }

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
        if let codec = try? await request(Cmd.getCodec).first { state.codec = codec }

        var mark = changesFinished[.noiseMode]
        if let anc = try? await request(Cmd.getAncEnabled).first {
            let table = try? await request(Cmd.getModeTable)
            let adaptive = table.flatMap { Self.modeValue(in: $0, id: Cmd.modeAdaptive) } == 1
            if changesFinished[.noiseMode] == mark {
                knownAdaptive = table.flatMap { Self.modeValue(in: $0, id: Cmd.modeAdaptive) }
                state.noiseMode = anc != 0 ? (adaptive ? .adaptive : .custom) : .off
                state.antiWind = table.flatMap(Self.antiWind(in:))
            }
        }
        mark = changesFinished[.noiseLevel]
        let level = (try? await request(Cmd.getNoiseLevel).first).map { Int($0) }
        if changesFinished[.noiseLevel] == mark { state.noiseLevel = level }

        if let version = try? await request(Cmd.getFirmwareVersion), version.count >= 6 {
            let parts = stride(from: 0, to: 6, by: 2).map { Int(version[$0]) << 8 | Int(version[$0 + 1]) }
            state.firmware = parts.map(String.init).joined(separator: ".")
            state.firmwareMajor = parts.first
            state.firmwareVersion = parts
        }

        await refreshEqualiser()

        // Bass boost arrived with firmware 3.x and is rejected outright on 2.x,
        // so a failure here means "not on this firmware", not "broken".
        mark = changesFinished[.bassBoost]
        let bass = (try? await request(Cmd.getBassBoost).first).map { $0 != 0 }
        if changesFinished[.bassBoost] == mark { state.bassBoost = bass }

        await refreshSettings()

        state.lastError = nil
    }

    /// Reads the device settings, which the headphones never announce.
    public func refreshSettings() async {
        guard state.connected else { return }
        for setting in DeviceSetting.allCases {
            let mark = changesFinished[.setting(setting)]
            let raw = try? await request(setting.getter).first
            guard changesFinished[.setting(setting)] == mark else { continue }
            state.settings[setting] = raw.map { setting.isInverted ? $0 == 0 : $0 != 0 }
        }
    }

    private func refreshEqualiser() async {
        // The parametric equaliser is a firmware 3.x feature. On 2.x these ids
        // are rejected, which is a fact about the device rather than an error
        // worth showing the user as one.
        // The gains read is stale if a band write was still out when it was
        // sent, or an edit started after. The screen already shows that edit.
        let mark = equaliserEdits
        guard let config = try? await request(Cmd.getEqConfig) else {
            state.bands = []
            state.equaliserSupported = false
            return
        }
        let writesWereOut = bandWritesInFlight > 0
        guard let gains = try? await request(Cmd.getAllGains, payload: [0]) else {
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
        if writesWereOut || equaliserEdits != mark, state.bands.count == bands.count {
            for index in bands.indices { bands[index].gainDb = state.bands[index].gainDb }
        }
        state.bands = bands
        state.equaliserSupported = true
    }

    // MARK: - Writing

    /// A mode is two writes. When a newer click arrives in between, this one
    /// stops: its second write, or its state update, would undo the newer one.
    public func setNoiseMode(_ mode: NoiseMode) async {
        // A mode-table write can reset the level too (see rereadNoiseLevel).
        defer { finished(.noiseMode, .noiseLevel) }
        noiseModeClicks += 1
        let click = noiseModeClicks
        do {
            _ = try await request(Cmd.setAncEnabled, payload: [mode == .off ? 0 : 1])
            guard click == noiseModeClicks else { return }
            if mode != .off {
                try await writeMode(id: Cmd.modeAdaptive, value: mode == .adaptive ? 1 : 0)
                guard click == noiseModeClicks else { return }
            }
            state.noiseMode = mode
            state.lastError = nil
        } catch {
            guard click == noiseModeClicks else { return }
            state.lastError = error.localizedDescription
        }
    }

    public func setAntiWind(_ setting: AntiWind) async {
        defer { finished(.noiseMode, .noiseLevel) }
        do {
            try await writeMode(id: Cmd.modeAntiWind, value: setting.rawValue)
            state.antiWind = setting
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    public func setNoiseLevel(_ level: Int) async {
        let clamped = UInt8(max(0, min(100, level)))
        defer { finished(.noiseLevel) }
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
        equaliserEdits += 1
        let edit = equaliserEdits
        bandOwner[band] = edit
        do {
            try await writeBand(band, db: clamped)
            // A preset clicked meanwhile has already shown its own value here.
            if bandOwner[band] == edit, let index = state.bands.firstIndex(where: { $0.id == band }) {
                state.bands[index].gainDb = clamped
            }
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    private func writeBand(_ band: Int, db: Double) async throws {
        bandWritesInFlight += 1
        defer { bandWritesInFlight -= 1 }
        _ = try await request(Cmd.setBandGain, payload: [UInt8(band), Gain.encode(db: db)])
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

        // Show the new curve at once and let the device catch up: five
        // sequential writes take long enough that waiting for them makes the
        // button feel broken.
        //
        // This is only safe because the count suppresses equaliser pushes while
        // the writes run. Without it the device's echo of each half-applied
        // curve drags the not-yet-written sliders back, five times over.
        presetsBeingApplied += 1
        defer { presetsBeingApplied -= 1 }

        equaliserEdits += 1
        let edit = equaliserEdits
        for (index, gain) in targets.enumerated() {
            state.bands[index].gainDb = gain
            bandOwner[index] = edit
        }

        for (index, gain) in targets.enumerated() {
            // A newer preset or slider move owns this band now. Writing ours
            // would land after theirs and leave the device on an older choice.
            guard bandOwner[index] == edit else { continue }
            do {
                try await writeBand(index, db: gain)
            } catch {
                // The curve on screen is now a promise we failed to keep, so
                // take the device's word for it instead.
                state.lastError = error.localizedDescription
                await refreshEqualiser()
                return
            }
        }
        state.lastError = nil
    }

    public func set(_ setting: DeviceSetting, on: Bool) async {
        defer { finished(.setting(setting)) }
        let raw: UInt8 = on != setting.isInverted ? 1 : 0
        do {
            _ = try await request(setting.setter, payload: [raw])
            state.settings[setting] = on
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    public func setBassBoost(_ enabled: Bool) async {
        defer { finished(.bassBoost) }
        do {
            _ = try await request(Cmd.setBassBoost, payload: [enabled ? 1 : 0])
            state.bassBoost = enabled
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    /// Writes one entry of the 0x1A01 mode table, after any edit already queued.
    private func writeMode(id: UInt8, value: UInt8) async throws {
        let previous = lastModeTableEdit
        let edit = Task { () throws in
            await previous?.value
            try await patchModeTable(id: id, value: value)
        }
        lastModeTableEdit = Task { _ = try? await edit.value }
        try await edit.value
    }

    /// The two reference implementations disagree about what 0x1A00 accepts:
    /// one sends a bare [id, value] pair, the other says the device rejects
    /// partial writes and needs the whole table back. For the adaptive entry
    /// we try the short form once, and on a rejection fall back to
    /// read-modify-write and remember that for the rest of the session. Every
    /// other entry is only ever written as the whole table.
    private func patchModeTable(id: UInt8, value: UInt8) async throws {
        // Every write has a side effect (see rereadNoiseLevel), so skip a no-op.
        if id == Cmd.modeAdaptive, knownAdaptive == value { return }
        if id == Cmd.modeAdaptive, modeWriteFormat != .fullTable {
            do {
                _ = try await request(Cmd.setModeTable, payload: [id, value])
                knownAdaptive = value
                modeWriteFormat = .singlePair
                await rereadNoiseLevel()
                return
            } catch let error as TransportError {
                guard case .deviceRejected = error else { throw error }
                modeWriteFormat = .fullTable
            }
        }

        // The table is written straight back, so a misread here would reset the
        // other modes. Replies take 17-40 ms in captures; other tools wait 5 s.
        var table = try await request(Cmd.getModeTable, timeout: .seconds(5))
        guard Cmd.isFullModeTable(table) else {
            throw TransportError.unexpectedReply(command: Cmd.getModeTable)
        }
        knownAdaptive = Self.modeValue(in: table, id: Cmd.modeAdaptive)
        guard Self.modeValue(in: table, id: id) != value else { return }
        var index = 0
        while index + 1 < table.count {
            if table[index] == id { table[index + 1] = value }
            index += 2
        }
        _ = try await request(Cmd.setModeTable, payload: table)
        knownAdaptive = Self.modeValue(in: table, id: Cmd.modeAdaptive)
        await rereadNoiseLevel()
    }

    /// Any mode-table write, even an unchanged one, set the level to 0 on
    /// FW 3.37.3 (M4C captures). Reads it back so the slider shows the truth.
    private func rereadNoiseLevel() async {
        let mark = changesFinished[.noiseLevel]
        let level = try? await request(Cmd.getNoiseLevel).first
        if let level, changesFinished[.noiseLevel] == mark { state.noiseLevel = Int(level) }
    }

    /// Nil unless the table has the one shape seen on the wire and a known value.
    private static func antiWind(in table: [UInt8]) -> AntiWind? {
        guard Cmd.isFullModeTable(table) else { return nil }
        return AntiWind(rawValue: table[1])
    }

    private static func modeValue(in table: [UInt8], id: UInt8) -> UInt8? {
        var index = 0
        while index + 1 < table.count {
            if table[index] == id { return table[index + 1] }
            index += 2
        }
        return nil
    }

    // MARK: - Paired devices

    /// Reads the headphones' paired devices into the state. Not part of
    /// `refresh()`: the list is read on connect, on request, and on a push.
    public func refreshPairedDevices() async {
        guard state.connected else { return }
        _ = await loadPairedDevices()
    }

    /// Reads the list and shows it unless a newer read started meanwhile or
    /// the link changed. Returns what was read either way; nil on a failure.
    private func loadPairedDevices() async -> (devices: [PairedDevice], max: Int?)? {
        pairedListReads += 1
        let read = pairedListReads
        let link = links
        let list = await readPairedDevices()
        if read == pairedListReads, link == links {
            state.pairedDevices = list?.devices
            state.maxConnections = list?.max
        }
        return list
    }

    /// Count, own index and limit, then one entry per index. Any entry that
    /// fails fails the whole list: a list with a gap would shift names.
    private func readPairedDevices() async -> (devices: [PairedDevice], max: Int?)? {
        guard let countReply = try? await request(Cmd.getPairedDeviceCount), countReply.count == 2 else {
            return nil
        }
        let count = min(Int(countReply[0]) << 8 | Int(countReply[1]), Cmd.maxPairedDevices)
        let own = Self.singleByte(try? await request(Cmd.getOwnDeviceIndex))
        let max = Self.singleByte(try? await request(Cmd.getMaxConnections))

        var entries: [(name: String, connected: Bool)] = []
        for index in 0..<count {
            guard let reply = try? await request(Cmd.getPairedDevice, payload: [UInt8(index)]),
                  let entry = Self.pairedEntry(reply, index: index) else { return nil }
            entries.append(entry)
        }
        // Trusted only on a connected slot, since this Mac is connected.
        // omarchy-momentum4 reads 0x1407 as a restart flag; a wrong guess
        // here must not label a phone as this Mac.
        let thisMac = own.flatMap { $0 < entries.count && entries[$0].connected ? $0 : nil }
        let devices = entries.enumerated().map {
            PairedDevice(index: $0.offset, name: $0.element.name,
                         isConnected: $0.element.connected, isThisMac: $0.offset == thisMac)
        }
        return (devices, max)
    }

    /// The one byte 0x1407 and 0x1409 answer; nil for any other length.
    private static func singleByte(_ reply: [UInt8]?) -> Int? {
        guard let reply, reply.count == 1 else { return nil }
        return Int(reply[0])
    }

    /// `[index, priority, connected, name..., 00]`; nil unless the index
    /// echoes. An empty OK is how an action answers, so it is no entry.
    static func pairedEntry(_ reply: [UInt8], index: Int) -> (name: String, connected: Bool)? {
        guard reply.count >= 3, Int(reply[0]) == index else { return nil }
        let name = String(decoding: reply.dropFirst(3).prefix { $0 != 0 }, as: UTF8.self)
        return (name, reply[2] != 0)
    }

    /// Connects a paired device alongside this Mac.
    ///
    /// Refused when every slot is taken; see `change(_:connect:)` for the
    /// checks both directions share.
    public func connect(to device: PairedDevice) async {
        await change(device, connect: true)
    }

    /// Disconnects a paired device. For this Mac that is a hand-over, as
    /// the power button does; others take 0x1403, on FW 3.38.3 and newer
    /// only: 2.13.42 erased a pairing with it. `request` enforces that, and
    /// the menu offers no Disconnect below it.
    public func disconnect(_ device: PairedDevice) async {
        if device.isThisMac {
            guard state.pairedAction == nil else { return }
            releaseHeadphones()
            return
        }
        await change(device, connect: false)
    }

    /// Connects or disconnects one paired device by index.
    ///
    /// Refuses before sending when the list moved since the user saw it
    /// (indexes can reorder on reconnect), when the name is ambiguous, or
    /// when this Mac cannot be identified: its own slot must never be the
    /// target. The device acknowledges before the link changes, so the
    /// status is polled until the deadline, and a fresh list decides.
    private func change(_ device: PairedDevice, connect: Bool) async {
        guard state.connected, state.pairedAction == nil else { return }
        state.pairedAction = connect ? .connecting(device.name) : .disconnecting(device.name)
        defer { state.pairedAction = nil }
        state.lastError = nil
        let link = links

        guard let before = await loadPairedDevices() else {
            guard link == links else { return }
            state.lastError = "Couldn't read the headphones' paired devices."
            return
        }
        guard let target = before.devices.first(where: { $0.index == device.index }),
              target.name == device.name else {
            state.lastError = "The paired devices changed. Check the list and try again."
            return
        }
        if target.isThisMac || target.isConnected == connect { return }
        // Index and name are all the device reports. Two entries with one
        // name could swap places unseen, and the outcome is judged by name.
        guard before.devices.filter({ $0.name == device.name }).count == 1 else {
            state.lastError = "Two paired devices are called \(device.name), so the app can't tell them apart."
            return
        }
        guard before.devices.contains(where: \.isThisMac) else {
            state.lastError = "Couldn't tell which paired device is this Mac, so nothing was changed."
            return
        }
        if connect {
            let connectedCount = before.devices.filter(\.isConnected).count
            guard let max = before.max else {
                state.lastError = "Couldn't tell how many devices the headphones can connect at once."
                return
            }
            guard connectedCount < max else {
                state.lastError = "\(connectedCount) of \(max) devices are connected. Disconnect one first."
                return
            }
        }

        do {
            try await request(connect ? Cmd.connectPairedDevice : Cmd.disconnectPairedDevice,
                              payload: [UInt8(device.index)])
        } catch {
            guard link == links else { return }
            state.lastError = error.localizedDescription
            return
        }
        // A poll that times out or is refused only means "not there yet".
        let deadline = ContinuousClock.now + peerConnectTimeout
        while ContinuousClock.now < deadline, link == links {
            let status = try? await request(Cmd.getPairedDeviceStatus, payload: [UInt8(device.index)])
            if let status, status.count == 2, Int(status[0]) == device.index, (status[1] != 0) == connect { break }
            try? await Task.sleep(for: peerPollInterval)
        }
        guard link == links else { return }

        // By name: the index may have moved when the link changed.
        let after = await loadPairedDevices()
        guard link == links else { return }
        let done = after?.devices.contains { $0.name == device.name && $0.isConnected == connect } == true
        if done {
            state.lastError = nil
        } else if connect {
            state.lastError = "\(device.name) did not connect. "
                + "It may be off, out of range, or have forgotten the headphones."
        } else {
            state.lastError = "\(device.name) is still connected."
        }
    }

    // MARK: - Request plumbing

    @discardableResult
    func request(_ command: UInt16, payload: [UInt8] = [], timeout: Duration = .seconds(2)) async throws -> [UInt8] {
        if let reason = CommandSafety.rejectionReason(for: command, payload: payload) {
            throw TransportError.blockedCommand(reason: reason)
        }
        // CommandSafety cannot see the firmware; every send passes here.
        if command == Cmd.disconnectPairedDevice, !state.canDisconnectOthers {
            throw TransportError.blockedCommand(
                reason: "0x1403 needs firmware 3.38.3 or newer; on 2.13.42 it erased a pairing")
        }

        let previous = lastRequest[command]
        let turn = Task { () throws -> [UInt8] in
            await previous?.value
            return try await exchange(command, payload: payload, timeout: timeout)
        }
        lastRequest[command] = Task { _ = try? await turn.value }
        return try await turn.value
    }

    /// Sends one frame and waits for its reply. Only `request` calls this, so
    /// at most one exchange per command is ever in flight.
    private func exchange(_ command: UInt16, payload: [UInt8], timeout: Duration) async throws -> [UInt8] {
        // Overwriting a waiting request would leave its caller suspended forever.
        assert(inFlight[command] == nil, "request() must finish one exchange before starting the next")
        nextSequence += 1
        let sequence = nextSequence

        return try await withCheckedThrowingContinuation { continuation in
            inFlight[command] = (sequence, continuation)
            do {
                try transport.send(GaiaFrame(command: command, payload: payload))
            } catch {
                // A reply or a disconnect delivered during `send` may already
                // have resumed this caller. Resuming twice traps.
                if inFlight[command]?.sequence == sequence {
                    inFlight[command] = nil
                    continuation.resume(throwing: error)
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self,
                      let waiting = self.inFlight[command],
                      waiting.sequence == sequence else { return }   // not ours any more
                self.inFlight[command] = nil
                waiting.continuation.resume(throwing: TransportError.timedOut(command: command))
            }
        }
    }

    private func log(_ frame: GaiaFrame) {
        guard let frameLogger else { return }
        let kind: String
        switch frame.responseKind {
        case .success: kind = "ok      "
        case .error: kind = "error   "
        case .notification: kind = "NOTIFY  "
        case nil: kind = "unsolicited"
        }
        let hex = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        frameLogger(String(format: "0x%04X  %@  base=0x%04X  [%@]",
                           frame.command, kind, frame.baseCommand, hex))
    }

    private func handle(_ frame: GaiaFrame) {
        guard let kind = frame.responseKind else { return }
        switch kind {
        case .notification:
            applyNotification(frame)
        case .success, .error:
            // With nothing waiting on this command, it is a late answer to a
            // request that timed out, so it is dropped. A late reply while the
            // next request for the same command waits cannot be told apart, and
            // is taken as that request's answer.
            guard let waiting = inFlight.removeValue(forKey: frame.baseCommand) else { return }
            if kind == .success {
                waiting.continuation.resume(returning: frame.payload)
            } else {
                waiting.continuation.resume(throwing: TransportError.deviceRejected(
                    command: frame.baseCommand,
                    code: frame.payload.first ?? 0))
            }
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
            // Arrives alongside the mode-table push, in either order, so each
            // settles the mode from what the other last said.
            guard let value = frame.payload.first else { break }
            if value == 0 {
                state.noiseMode = .off
            } else if state.noiseMode == .off || state.noiseMode == nil, let adaptive = knownAdaptive {
                state.noiseMode = adaptive == 1 ? .adaptive : .custom
            }
        case Cmd.getModeTable:
            if let adaptive = Self.modeValue(in: frame.payload, id: Cmd.modeAdaptive) {
                knownAdaptive = adaptive
                if state.noiseMode != .off { state.noiseMode = adaptive == 1 ? .adaptive : .custom }
            }
            if let antiWind = Self.antiWind(in: frame.payload) { state.antiWind = antiWind }
        case Cmd.getBandGain:
            // Pushed as the whole curve, one gain per band. Ignored mid-preset:
            // those are half-applied curves and showing them is the scatter.
            if presetsBeingApplied == 0, frame.payload.count == state.bands.count {
                for (index, raw) in frame.payload.enumerated() {
                    state.bands[index].gainDb = Gain.decode(raw)
                }
            }
        case Cmd.getBassBoost:
            if let value = frame.payload.first { state.bassBoost = value != 0 }
        case Cmd.getPairedDeviceStatus:
            // Re-read rather than patch: the list may have reordered, so the
            // pushed index need not match the list held. Also recovers a
            // list whose last read failed.
            Task { [weak self] in await self?.refreshPairedDevices() }
        case Cmd.getCodec:
            if let value = frame.payload.first { state.codec = value }
        case Cmd.sampleRate:
            if frame.payload.count == 4 {
                state.sampleRateHz = frame.payload.reduce(0) { $0 << 8 | Int($1) }
            }
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

    /// Fails the requests in flight. Queued requests then try to send and fail
    /// on the closed transport themselves.
    private func failAllPending(_ error: Error) {
        let waiting = inFlight
        inFlight.removeAll()
        for (_, entry) in waiting { entry.continuation.resume(throwing: error) }
    }

    // MARK: - Diagnostics

    /// Read-only probe of a handful of ids with both payload forms.
    ///
    /// Several getters on this device reject an empty payload with 0x05 and
    /// answer the same id happily when given one dummy byte. The error form is
    /// indistinguishable from "unsupported", so the only way to tell them
    /// apart is to ask twice. Sends no writes. A form the allow-list refuses
    /// is reported as refused and never sent.
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
        let charge = state.chargeLabel.map { " (\($0.lowercased()))" } ?? ""
        lines.append("Battery:  \(state.batteryPercent.map { "\($0)%" } ?? "unknown")\(charge)")
        lines.append("Noise:    \(state.noiseMode?.rawValue ?? "unknown") at level \(state.noiseLevel.map(String.init) ?? "?")")
        lines.append("Bass:     \(state.bassBoost.map { $0 ? "on" : "off" } ?? "not on this firmware (needs 3.x)")")
        if state.bands.isEmpty {
            lines.append("EQ:       " + (state.needsFirmwareUpdateForEq
                                         ? "not on this firmware (added in 3.x)"
                                         : "not available"))
        } else {
            let curve = state.bands.map { "\($0.frequencyHz)Hz \(String(format: "%+.1f", $0.gainDb))dB" }
            lines.append("EQ:       " + curve.joined(separator: "  "))
        }
        if let devices = state.pairedDevices {
            let max = state.maxConnections.map { ", up to \($0) at once" } ?? ""
            lines.append("Paired:   \(devices.count) device\(devices.count == 1 ? "" : "s")\(max)")
            for device in devices {
                let marks = [device.isConnected ? "connected" : nil, device.isThisMac ? "this Mac" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                lines.append("  \(device.index): \(device.name)\(marks.isEmpty ? "" : " (\(marks))")")
            }
        }
        if let touch = try? await request(Cmd.getTouchControls).first {
            // Inverted on this device: 0 means enabled.
            lines.append("Touch:    \(touch == 0 ? "enabled" : "disabled")")
        }
        if let error = state.lastError { lines.append("Last error: \(error)") }
        return lines.joined(separator: "\n")
    }
}
