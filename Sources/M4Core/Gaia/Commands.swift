import Foundation

/// Sennheiser (vendor 0x0495) command ids for the MOMENTUM 4.
///
/// Everything here is reverse-engineered by the community, not documented by
/// Sennheiser. Ids are cross-checked between the firmware-3.38.3 notes in
/// omarchy-momentum4 and the independent momentumctl implementation; the two
/// agree once you account for momentumctl naming frames by their *response*
/// id (response == request | 0x0100).
///
/// Convention on this device: odd id reads, the even id below it writes.
/// The equaliser group does not follow that rule, so it is spelled out.
enum Cmd {
    // Notifications ------------------------------------------------------
    /// Core feature, command 7: subscribe to one feature's notifications.
    /// Payload is a single feature id. Without this the device answers
    /// questions and volunteers nothing.
    static let registerNotification: UInt16 = 0x0007

    /// GAIA v3 packs the feature into the command: `feature = command >> 9`.
    /// So 0x0682 (charging) is feature 3, 0x1A05 (ANC) is 13, 0x1003 (EQ) is 8.
    enum Feature {
        static let battery: UInt8 = 3       // includes the charging push
        static let audio: UInt8 = 4         // codec and sample-rate pushes
        static let userEq: UInt8 = 8
        static let deviceManagement: UInt8 = 10   // paired-device connect push
        static let transparency: UInt8 = 12
        static let anc: UInt8 = 13
    }

    // Battery -----------------------------------------------------------
    /// -> [] ; <- [percent]. Keeps answering while charging.
    static let getBattery: UInt16 = 0x0603

    /// Push only, as 0x0682: [1] when the cable goes in, [0] when it comes out.
    /// Reported by the headphones themselves, so a wall charger counts.
    ///
    /// There is no getter for it — but subscribing to feature 3 makes the
    /// device send the current state straight away, so the state is known from
    /// connect onwards rather than only after the cable next moves.
    static let chargingNotification: UInt16 = 0x0602

    // Audio stream ------------------------------------------------------
    /// -> [] ; <- [codec]. Also pushed as 0x0880. Describes whatever the
    /// headphones are playing, from any source. Values are Smart Control's
    /// `Sound_CodecUsed` enum (see `AudioCodec`); 0xFF = no stream. Captured on
    /// FW 3.38.3 (M4C `2026-09-19_fw3.38.3_codec.json`). An even id that reads.
    static let getCodec: UInt16 = 0x0800
    /// Push only, as 0x089A: sample rate as u32 BE in Hz, 0 when stopped.
    /// Never sent: no getter is confirmed on a MOMENTUM 4.
    static let sampleRate: UInt16 = 0x081A

    // Noise control -----------------------------------------------------
    /// -> [] ; <- [0/1]. The "Off" leg of the app's three-way control.
    static let getAncEnabled: UInt16 = 0x1A05
    /// -> [0/1]
    static let setAncEnabled: UInt16 = 0x1A04
    /// -> [] ; <- [level] 0 = full ANC ... 100 = full transparency
    static let getNoiseLevel: UInt16 = 0x1A03
    /// -> [level]
    static let setNoiseLevel: UInt16 = 0x1A02
    /// -> [] ; <- [id, value] pairs: 1 = anti-wind, 2 = unknown, 3 = adaptive
    static let getModeTable: UInt16 = 0x1A01
    /// -> either the whole table or a single [id, value] pair; see ModeWriteFormat
    static let setModeTable: UInt16 = 0x1A00

    static let modeAntiWind: UInt8 = 1
    static let modeComfort: UInt8 = 2
    static let modeAdaptive: UInt8 = 3

    /// True for the only table shape seen from a MOMENTUM 4: `[1, x, 2, y, 3, z]`.
    /// Every one of 43 community capture files agrees; anything else is
    /// treated as a misread rather than written back.
    static func isFullModeTable(_ table: [UInt8]) -> Bool {
        table.count == 6 && table[0] == modeAntiWind && table[2] == modeComfort && table[4] == modeAdaptive
    }

    // Equaliser ---------------------------------------------------------
    /// -> [] ; <- [bandCount, minGain i8, maxGain i8, ...]
    static let getEqConfig: UInt16 = 0x1000
    /// -> [band, gain i8]  (gain in 0.1 dB steps)
    static let setBandGain: UInt16 = 0x1001
    /// -> [band] ; <- [gain] or [band, gain]
    static let getBandGain: UInt16 = 0x1002
    /// -> [any byte] ; <- one gain per band. An EMPTY payload is rejected.
    static let getAllGains: UInt16 = 0x1003
    /// -> [band] ; <- [band, hz u16 BE]
    static let getBandFrequency: UInt16 = 0x100B
    /// -> [0/1]
    static let setBassBoost: UInt16 = 0x1008
    /// -> [] ; <- [0/1]. Rejected on firmware 2.x.
    static let getBassBoost: UInt16 = 0x1009

    // Device ------------------------------------------------------------
    /// -> [] ; <- 3 x u16 BE, e.g. 3, 38, 3
    static let getFirmwareVersion: UInt16 = 0x1201
    /// -> [] ; <- [0/1]. INVERTED: 0 = enabled, 1 = disabled.
    static let getTouchControls: UInt16 = 0x1607
    /// -> [0/1], inverted like the getter.
    static let setTouchControls: UInt16 = 0x1606

    // Device settings ---------------------------------------------------
    /// Getters take no payload and answer [0/1]; setters take [0/1]. Each
    /// was confirmed by a write, a read-back and a restore on FW 3.38.3
    /// (omarchy-momentum4 PROTOCOL.md). None sends a notification.
    ///
    /// On-head detection also gates Smart Pause and call hold.
    static let getOnHead: UInt16 = 0x0401
    static let setOnHead: UInt16 = 0x0400
    static let getAutoAnswer: UInt16 = 0x080B
    static let setAutoAnswer: UInt16 = 0x080A
    /// Pauses playback when the headphones come off.
    static let getSmartPause: UInt16 = 0x080D
    static let setSmartPause: UInt16 = 0x080C
    static let getComfortCall: UInt16 = 0x0815
    static let setComfortCall: UInt16 = 0x0814
    /// -> [] ; <- ASCII model id, NUL-terminated: "M4AEBT Black" on a
    /// MOMENTUM 4 (community capture, FW 3.37.3).
    static let getModelId: UInt16 = 0x1206
    static let momentum4ModelPrefix = "M4AEBT"

    // Paired devices ----------------------------------------------------
    /// Devices are addressed by a 0-based index alone; there is no address.
    /// Indexes can reorder when a device reconnects, so a name read with the
    /// index is checked again before acting on it. Every layout below is
    /// from momentum4-control's captures on FW 3.37.3 and 3.38.3.
    ///
    /// -> [] ; <- count as u16 BE
    static let getPairedDeviceCount: UInt16 = 0x1400
    /// -> [index] ; <- [index, priority, connected 0/1, name..., 00]
    static let getPairedDevice: UInt16 = 0x1401
    /// -> [index] ; <- empty OK at once, before the link is up.
    static let connectPairedDevice: UInt16 = 0x1402
    /// -> [index] ; <- empty OK. Disconnects and keeps the pairing on
    /// FW 3.38.3; erased a pairing on 2.13.42. `HeadphoneController.request`
    /// refuses it below 3.38.3 (`DeviceState.canDisconnectOthers`).
    static let disconnectPairedDevice: UInt16 = 0x1403
    /// -> [index] ; <- [index, connected 0/1]. Also pushed as 0x1484.
    static let getPairedDeviceStatus: UInt16 = 0x1404
    /// -> [] ; <- [index] of the device asking, i.e. this Mac.
    static let getOwnDeviceIndex: UInt16 = 0x1407
    /// -> [] ; <- [n]. 2 on a MOMENTUM 4.
    static let getMaxConnections: UInt16 = 0x1409
    /// The most devices the app reads, and the largest index it sends.
    static let maxPairedDevices = 16
}

/// Commands that must never be sent, and why.
///
/// These are not style preferences. Each was observed to do real damage during
/// the community reverse-engineering work, and three of them cost somebody a
/// re-pairing or a power cycle to discover. Both `HeadphoneController.request`
/// and `RFCOMMTransport.send` enforce it, so no call site can route around it.
enum CommandSafety {
    /// Takes the headphones offline; they drop off the bus and need a power
    /// cycle. Two independent sweeps died here.
    static let bricksLink: Set<UInt16> = [0x0607, 0x0613, 0x0685]

    /// Setters for voice prompts, sidetone and low latency (momentum4-control
    /// catalogue). Only the prompts write is verified there; the app sends
    /// none of them.
    static let untestedWrites: Set<UInt16> = [0x0801, 0x0805, 0x0817]

    /// The 0x06xx group is power/system space and is known to reset the link
    /// at more ids than the three above. Only battery is allowed out of it.
    static let powerGroupAllowlist: Set<UInt16> = [Cmd.getBattery]

    static func rejectionReason(for command: UInt16) -> String? {
        if bricksLink.contains(command) {
            return String(format: "0x%04X takes the headphones offline (power cycle required)", command)
        }
        if untestedWrites.contains(command) {
            return String(format: "0x%04X is a setter the app does not use", command)
        }
        if (0x0600...0x06FF).contains(command), !powerGroupAllowlist.contains(command) {
            return String(format: "0x%04X is in the 0x06xx power/system group, which resets the link", command)
        }
        return nil
    }

    /// The only frames the app may send: each command with the payloads it uses.
    ///
    /// An allow-list on top of the deny-list above, because community
    /// catalogues name more dangerous ids than any deny-list keeps up with:
    /// factory reset 0x0040, firmware upgrade 0x0200, pairing deletes 0x1405
    /// and 0x1406, MMI reset 0x1604. Reads take exactly the payload the app
    /// sends: a getter given a byte it does not expect may act as a setter.
    private static let allowed: [UInt16: ([UInt8]) -> Bool] = {
        let flag: ([UInt8]) -> Bool = { $0 == [0] || $0 == [1] }
        let features: Set<UInt8> = [Cmd.Feature.battery, Cmd.Feature.audio, Cmd.Feature.userEq,
                                    Cmd.Feature.deviceManagement, Cmd.Feature.transparency, Cmd.Feature.anc]
        let pairedIndex: ([UInt8]) -> Bool = { $0.count == 1 && Int($0[0]) < Cmd.maxPairedDevices }
        var rules: [UInt16: ([UInt8]) -> Bool] = [
            Cmd.registerNotification: { $0.count == 1 && features.contains($0[0]) },
            Cmd.setAncEnabled: flag,
            Cmd.setNoiseLevel: { $0.count == 1 && $0[0] <= 100 },
            // The app only ever writes the adaptive entry, or the whole table.
            Cmd.setModeTable: { $0 == [Cmd.modeAdaptive, 0] || $0 == [Cmd.modeAdaptive, 1]
                                || Cmd.isFullModeTable($0) },
            // 16 bands is the most the controller accepts from the device.
            Cmd.setBandGain: { $0.count == 2 && $0[0] < 16 },
            Cmd.setBassBoost: flag,
            Cmd.setTouchControls: flag,
            Cmd.setOnHead: flag,
            Cmd.setAutoAnswer: flag,
            Cmd.setSmartPause: flag,
            Cmd.setComfortCall: flag,
            // Rejected when empty; the byte is ignored.
            Cmd.getAllGains: { $0.count == 1 },
            Cmd.getBandGain: { $0.count == 1 && $0[0] < 16 },
            Cmd.getBandFrequency: { $0.count == 1 && $0[0] < 16 },
            Cmd.getPairedDevice: pairedIndex,
            Cmd.getPairedDeviceStatus: pairedIndex,
            // The group's two actions; the deletes stay out. Disconnect is
            // also gated on firmware, which this static list cannot see.
            Cmd.connectPairedDevice: pairedIndex,
            Cmd.disconnectPairedDevice: pairedIndex,
        ]
        // Strictly empty. The settings getters sit beside untested setters,
        // and "an id that answers an indexed payload with an empty OK is an
        // action" (omarchy-momentum4 PROTOCOL.md). The battery read is the
        // one id let out of the 0x06xx power group.
        for id in [Cmd.getOnHead, Cmd.getAutoAnswer, Cmd.getSmartPause, Cmd.getComfortCall, Cmd.getCodec,
                   Cmd.getBattery, Cmd.getAncEnabled, Cmd.getNoiseLevel, Cmd.getModeTable, Cmd.getEqConfig,
                   Cmd.getBassBoost, Cmd.getFirmwareVersion, Cmd.getTouchControls, Cmd.getModelId,
                   Cmd.getPairedDeviceCount, Cmd.getOwnDeviceIndex, Cmd.getMaxConnections] {
            rules[id] = { $0.isEmpty }
        }
        return rules
    }()

    /// Every rule here is about Sennheiser's ids. Under another vendor the same
    /// id means something else (Qualcomm's 0x1A00 is a battery read), so any
    /// other vendor is refused outright.
    static func rejectionReason(for command: UInt16, payload: [UInt8],
                                vendor: UInt16 = GaiaFrame.vendorSennheiser) -> String? {
        guard vendor == GaiaFrame.vendorSennheiser else {
            return String(format: "0x%04X:0x%04X is not a command this app sends", vendor, command)
        }
        if let reason = rejectionReason(for: command) { return reason }
        guard let rule = allowed[command] else {
            return String(format: "0x%04X is not a command this app sends", command)
        }
        guard rule(payload) else {
            let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(format: "0x%04X does not take the payload [%@]", command, hex)
        }
        return nil
    }

    static func isSafe(_ command: UInt16) -> Bool { rejectionReason(for: command) == nil }
}

/// The one place the two sources contradict each other.
///
/// momentumctl writes a single [id, value] pair to 0x1A00; the firmware-3.38.3
/// notes say the device takes the whole table and rejects partial writes. The
/// Windows project flags the same contradiction as unresolved. Rather than
/// pick, we try the cheap form once and remember what the device accepted.
enum ModeWriteFormat {
    case unknown
    case singlePair
    case fullTable
}

/// Error codes seen in error-form replies.
enum GaiaError {
    static let malformedOrWrongLength: UInt8 = 0x05
    static let indexOutOfRange: UInt8 = 0x83
}

/// Gains travel as a signed byte in tenths of a decibel.
enum Gain {
    static let minDb = -12.8
    static let maxDb = 12.7

    static func encode(db: Double) -> UInt8 {
        let clamped = max(minDb, min(maxDb, db))
        return UInt8(bitPattern: Int8(clamping: Int((clamped * 10).rounded())))
    }

    static func decode(_ raw: UInt8) -> Double {
        Double(Int8(bitPattern: raw)) / 10.0
    }
}
