import XCTest
@testable import M4Core

/// The headphones' paired devices (0x1400-0x1409), and connecting one (0x1402).
///
/// Reply layouts are from momentum4-control's captures on FW 3.37.3 and
/// 3.38.3: an entry is `[index, priority, connected, name..., 00]`.
@MainActor
final class PairedDeviceTests: XCTestCase {

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private func connected(_ device: FakeHeadset,
                           wrap: ((GaiaFrame, FakeTransport) -> [GaiaFrame]?)? = nil)
        async -> (HeadphoneController, FakeTransport) {
        let fake = FakeTransport()
        fake.respond = { [weak fake] frame in
            guard let fake else { return [] }
            if let replies = wrap?(frame, fake) { return replies }
            return device.respond(frame, push: { fake.push($0) })
        }
        let controller = HeadphoneController(transport: fake)
        // Generous: only rows that never connect wait for the deadline.
        controller.peerPollInterval = .milliseconds(5)
        controller.peerConnectTimeout = .milliseconds(500)
        await controller.connect()
        return (controller, fake)
    }

    /// Waits for a condition instead of a fixed sleep, up to a limit.
    private func settle(within limit: Duration = .seconds(2), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func entry(_ index: UInt8, priority: UInt8? = nil, _ connected: UInt8, _ name: [UInt8]) -> [UInt8] {
        [index, priority ?? index, connected] + name
    }

    private static func describe(_ devices: [PairedDevice]?) -> [String]? {
        devices?.map { "\($0.name) \($0.isConnected ? "on" : "off")\($0.isThisMac ? " mac" : "")" }
    }

    // MARK: - Labels

    private struct SummaryRow {
        let name: String
        let devices: [(String, Bool, Bool)]?   // name, connected, this Mac
        var max: Int? = 2
        var connecting: String?
        var disconnecting: String?
        let summary: String?
        let full: Bool
    }

    private static let summaryRows: [SummaryRow] = [
        SummaryRow(name: "only this Mac", devices: [("Mac", true, true), ("iPhone", false, false)],
                   summary: "Only this Mac", full: false),
        SummaryRow(name: "phone also on", devices: [("Mac", true, true), ("iPhone", true, false)],
                   summary: "Also on iPhone", full: true),
        SummaryRow(name: "two others on, three slots",
                   devices: [("Mac", true, true), ("iPhone", true, false), ("iPad", true, false)], max: 3,
                   summary: "Also on iPhone, iPad", full: true),
        SummaryRow(name: "one other on, three slots", devices: [("Mac", true, true), ("iPhone", true, false)],
                   max: 3, summary: "Also on iPhone", full: false),
        SummaryRow(name: "connecting", devices: [("Mac", true, true), ("iPhone", false, false)],
                   connecting: "iPhone", summary: "Connecting iPhone", full: false),
        SummaryRow(name: "disconnecting", devices: [("Mac", true, true), ("iPhone", true, false)],
                   disconnecting: "iPhone", summary: "Disconnecting iPhone", full: true),
        SummaryRow(name: "this Mac unidentified, phone on", devices: [("Mac", true, false), ("iPhone", true, false)],
                   summary: "Also on Mac, iPhone", full: true),
        SummaryRow(name: "limit unknown", devices: [("Mac", true, true), ("iPhone", true, false)], max: nil,
                   summary: "Also on iPhone", full: false),
        SummaryRow(name: "no devices", devices: [], summary: "Only this Mac", full: false),
        SummaryRow(name: "list unknown", devices: nil, summary: nil, full: false),
    ]

    private static func state(_ row: SummaryRow) -> DeviceState {
        var state = DeviceState()
        state.pairedDevices = row.devices?.enumerated().map {
            PairedDevice(index: $0.offset, name: $0.element.0, isConnected: $0.element.1, isThisMac: $0.element.2)
        }
        state.maxConnections = row.max
        state.pairedAction = row.connecting.map(PairedAction.connecting)
            ?? row.disconnecting.map(PairedAction.disconnecting)
        return state
    }

    func testSummaryNamesTheOtherConnectedDevices() {
        for row in Self.summaryRows {
            XCTAssertEqual(Self.state(row).pairedSummary, row.summary, row.name)
        }
    }

    func testSlotsAreFullAtTheLimit() {
        for row in Self.summaryRows {
            XCTAssertEqual(Self.state(row).connectionSlotsFull, row.full, row.name)
        }
    }

    // MARK: - Wire bytes

    /// Frames as momentum4-control captured them, so a typo in an id fails.
    func testFramesMatchTheCaptures() {
        let rows: [(String, GaiaFrame, [UInt8])] = [
            ("count", GaiaFrame(command: Cmd.getPairedDeviceCount, payload: []),
             [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x14, 0x00]),
            ("entry 0", GaiaFrame(command: Cmd.getPairedDevice, payload: [0]),
             [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x14, 0x01, 0x00]),
            ("connect 2", GaiaFrame(command: Cmd.connectPairedDevice, payload: [2]),
             [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x14, 0x02, 0x02]),
            ("disconnect 3", GaiaFrame(command: Cmd.disconnectPairedDevice, payload: [3]),
             [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x14, 0x03, 0x03]),
            ("status 2", GaiaFrame(command: Cmd.getPairedDeviceStatus, payload: [2]),
             [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x14, 0x04, 0x02]),
            ("own index", GaiaFrame(command: Cmd.getOwnDeviceIndex, payload: []),
             [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x14, 0x07]),
            ("max connections", GaiaFrame(command: Cmd.getMaxConnections, payload: []),
             [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x14, 0x09]),
            ("subscribe 10", GaiaFrame(command: Cmd.registerNotification, payload: [Cmd.Feature.deviceManagement]),
             [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x00, 0x07, 0x0A]),
        ]
        for (name, frame, bytes) in rows {
            XCTAssertEqual(frame.encoded(), bytes, name)
        }
    }

    /// `FF 03 00 02 04 95 14 84 02 01` from multipoint-connect.json.
    func testTheCapturedPushIsAStatusNotification() {
        var buffer: [UInt8] = [0xFF, 0x03, 0x00, 0x02, 0x04, 0x95, 0x14, 0x84, 0x02, 0x01]
        let frame = GaiaFrame.decode(consuming: &buffer)
        XCTAssertEqual(frame?.baseCommand, Cmd.getPairedDeviceStatus)
        XCTAssertEqual(frame?.responseKind, .notification)
    }

    // MARK: - Reading the list

    private struct ListRow {
        let name: String
        var paired: [(name: String, connected: Bool)] = [("MacBook", true), ("iPhone", false)]
        var ownIndex: UInt8 = 0
        var ownIndexReply: [UInt8]?
        var countReply: [UInt8]?
        var entryReplies: [Int: [UInt8]] = [:]
        var rejects: Set<UInt16> = []
        /// "name on|off [mac]"; nil when the list is unknown.
        let shown: [String]?
    }

    private static let sixteen = Dictionary(uniqueKeysWithValues: (0..<20).map {
        ($0, entry(UInt8($0), $0 == 0 ? 1 : 0, Array("D\($0)".utf8) + [0]))
    })

    private static let listRows: [ListRow] = [
        ListRow(name: "this Mac and a phone", shown: ["MacBook on mac", "iPhone off"]),
        ListRow(name: "four devices, phone connected",
                paired: [("MacBook", true), ("iPhone", true), ("iPad", false), ("PC", false)],
                shown: ["MacBook on mac", "iPhone on", "iPad off", "PC off"]),
        ListRow(name: "this Mac not first", paired: [("iPhone", true), ("MacBook", true)], ownIndex: 1,
                shown: ["iPhone on", "MacBook on mac"]),
        ListRow(name: "own index on a disconnected slot is not trusted", ownIndex: 1,
                shown: ["MacBook on", "iPhone off"]),
        ListRow(name: "own index past the end", ownIndex: 5, shown: ["MacBook on", "iPhone off"]),
        ListRow(name: "own index rejected", rejects: [Cmd.getOwnDeviceIndex], shown: ["MacBook on", "iPhone off"]),
        ListRow(name: "own index of two bytes", ownIndexReply: [0, 0], shown: ["MacBook on", "iPhone off"]),
        ListRow(name: "own index empty", ownIndexReply: [], shown: ["MacBook on", "iPhone off"]),
        ListRow(name: "limit rejected, list still read", rejects: [Cmd.getMaxConnections],
                shown: ["MacBook on mac", "iPhone off"]),
        ListRow(name: "no paired devices", paired: [], shown: []),
        ListRow(name: "count rejected", rejects: [Cmd.getPairedDeviceCount], shown: nil),
        ListRow(name: "count of one byte", countReply: [2], shown: nil),
        ListRow(name: "empty count", countReply: [], shown: nil),
        ListRow(name: "count over the cap reads 16", countReply: [0, 20], entryReplies: sixteen,
                shown: ["D0 on mac"] + (1..<16).map { "D\($0) off" }),
        ListRow(name: "count with a high byte reads 16", countReply: [1, 0], entryReplies: sixteen,
                shown: ["D0 on mac"] + (1..<16).map { "D\($0) off" }),
        ListRow(name: "entry with the wrong index", entryReplies: [1: entry(0, priority: 1, 0, [0x41, 0])],
                shown: nil),
        ListRow(name: "entry answered with an empty OK", entryReplies: [1: []], shown: nil),
        ListRow(name: "entry too short", entryReplies: [1: [1, 1]], shown: nil),
        ListRow(name: "entry rejected", rejects: [Cmd.getPairedDevice], shown: nil),
        ListRow(name: "count larger than the entries", countReply: [0, 3], shown: nil),
        ListRow(name: "entry with no name at all", entryReplies: [1: entry(1, 0, [])],
                shown: ["MacBook on mac", " off"]),
        ListRow(name: "name without its NUL", entryReplies: [1: entry(1, 0, Array("Pixel".utf8))],
                shown: ["MacBook on mac", "Pixel off"]),
        ListRow(name: "name with UTF-8", paired: [("MacBook", true), ("Zoë’s iPhone", false)],
                shown: ["MacBook on mac", "Zoë’s iPhone off"]),
        ListRow(name: "empty name", entryReplies: [1: entry(1, 0, [0])], shown: ["MacBook on mac", " off"]),
        ListRow(name: "two devices with one name", paired: [("MacBook", true), ("iPhone", false), ("iPhone", true)],
                shown: ["MacBook on mac", "iPhone off", "iPhone on"]),
    ]

    func testConnectReadsThePairedDevices() async {
        for row in Self.listRows {
            let device = FakeHeadset()
            device.paired = row.paired
            device.ownIndex = row.ownIndex
            device.ownIndexReply = row.ownIndexReply
            device.pairedCountReply = row.countReply
            device.pairedEntryReplies = row.entryReplies
            device.rejects = row.rejects
            let (controller, _) = await connected(device)
            XCTAssertEqual(Self.describe(controller.state.pairedDevices), row.shown, row.name)
        }
    }

    func testConnectReadsTheConnectionLimit() async {
        let rows: [(String, [UInt8]?, Bool, Int?)] = [
            ("two", [2], false, 2),
            ("one", [1], false, 1),
            ("three", [3], false, 3),
            ("rejected", nil, true, nil),
            ("empty", [], false, nil),
            ("two bytes", [2, 0], false, nil),
        ]
        for (name, reply, rejected, limit) in rows {
            let device = FakeHeadset()
            if let reply { device.maxConnectionsReply = reply }
            if rejected { device.rejects = [Cmd.getMaxConnections] }
            let (controller, _) = await connected(device)
            XCTAssertEqual(controller.state.maxConnections, limit, name)
        }
    }

    func testConnectSubscribesToPairedDevicePushes() async {
        let (_, fake) = await connected(FakeHeadset())
        XCTAssertTrue(fake.sent.contains(GaiaFrame(command: Cmd.registerNotification,
                                                   payload: [Cmd.Feature.deviceManagement])))
    }

    func testDisconnectForgetsTheList() async {
        let (controller, fake) = await connected(FakeHeadset())
        XCTAssertNotNil(controller.state.pairedDevices, "read before the drop")
        XCTAssertNotNil(controller.state.maxConnections, "read before the drop")
        fake.drop()
        XCTAssertNil(controller.state.pairedDevices)
        XCTAssertNil(controller.state.maxConnections)
    }

    // MARK: - Pushes

    private struct PushRow {
        let name: String
        let before: [(name: String, connected: Bool)]
        let after: [(name: String, connected: Bool)]
        let push: [UInt8]
        var ownAfter: UInt8 = 0
        var listKnown = true
        let shown: [String]
    }

    private static let pushRows: [PushRow] = [
        PushRow(name: "phone connects", before: [("MacBook", true), ("iPhone", false)],
                after: [("MacBook", true), ("iPhone", true)], push: [1, 1],
                shown: ["MacBook on mac", "iPhone on"]),
        PushRow(name: "phone disconnects", before: [("MacBook", true), ("iPhone", true)],
                after: [("MacBook", true), ("iPhone", false)], push: [1, 0],
                shown: ["MacBook on mac", "iPhone off"]),
        // The pushed index names the new order, not the list held.
        PushRow(name: "phone connects and the list reorders", before: [("MacBook", true), ("iPhone", false)],
                after: [("iPhone", true), ("MacBook", true)], push: [0, 1], ownAfter: 1,
                shown: ["iPhone on", "MacBook on mac"]),
        PushRow(name: "a device paired meanwhile", before: [("MacBook", true)],
                after: [("MacBook", true), ("iPad", true)], push: [1, 1],
                shown: ["MacBook on mac", "iPad on"]),
        PushRow(name: "push of the wrong length still re-reads", before: [("MacBook", true), ("iPhone", false)],
                after: [("MacBook", true), ("iPhone", true)], push: [1],
                shown: ["MacBook on mac", "iPhone on"]),
        // Regression: a failed read used to mute every later push.
        PushRow(name: "push recovers a list whose read failed", before: [("MacBook", true)],
                after: [("MacBook", true), ("iPhone", true)], push: [1, 1], listKnown: false,
                shown: ["MacBook on mac", "iPhone on"]),
    ]

    func testAPushRereadsTheList() async {
        for row in Self.pushRows {
            let device = FakeHeadset()
            device.paired = row.before
            if !row.listKnown { device.pairedCountReply = [] }
            let (controller, fake) = await connected(device)
            device.paired = row.after
            device.ownIndex = row.ownAfter
            device.pairedCountReply = nil
            fake.push(Reply.notification(Cmd.getPairedDeviceStatus, row.push))
            await settle { Self.describe(controller.state.pairedDevices) == row.shown }
            XCTAssertEqual(Self.describe(controller.state.pairedDevices), row.shown, row.name)
        }
    }

    /// A slow read that started first must not land last: here it finishes
    /// with four devices after a newer read saw two, and would bring the
    /// removed ones back.
    ///
    /// Entry reads share one queue, so the two reads take turns. Started
    /// while the older read waits on entry 1, the newer one's last entry
    /// queues before the older one's.
    func testAnOlderReadNeverReplacesANewerOne() async {
        let device = FakeHeadset()
        device.paired = [("MacBook", true), ("iPhone", false), ("iPad", false), ("PC", false)]
        let (controller, fake) = await connected(device)
        device.pairedEntryDelays = Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, .milliseconds(30)) })
        let entryOne = { fake.sent.filter { $0.command == Cmd.getPairedDevice && $0.payload == [1] }.count }
        let before = entryOne()   // the read made on connect
        let older = Task { await controller.refreshPairedDevices() }
        await settle { entryOne() > before }
        device.paired = [("MacBook", true), ("iPhone", true)]
        // Entries 2 and 3 still answer, as stale slots would.
        device.pairedEntryReplies = [2: Self.entry(2, 0, Array("iPad".utf8) + [0]),
                                     3: Self.entry(3, 0, Array("PC".utf8) + [0])]
        fake.push(Reply.notification(Cmd.getPairedDeviceStatus, [1, 1]))
        await settle { Self.describe(controller.state.pairedDevices) == ["MacBook on mac", "iPhone on"] }
        _ = await older.value
        XCTAssertEqual(Self.describe(controller.state.pairedDevices), ["MacBook on mac", "iPhone on"])
    }

    /// A read whose last reply arrives just before the link drops must not
    /// show its list on the dead link.
    func testAReadThatOutlivesTheLinkShowsNothing() async {
        let device = FakeHeadset()
        let armed = Box(false)
        let (controller, fake) = await connected(device) { frame, fake in
            guard armed.value, frame.command == Cmd.getPairedDevice, frame.payload == [1] else { return nil }
            // The reply first, then the drop, before the read resumes.
            let replies = device.respond(frame, push: { fake.push($0) })
            Task { @MainActor in
                for reply in replies { fake.push(reply) }
                fake.drop()
            }
            return []
        }
        XCTAssertNotNil(controller.state.pairedDevices, "read while connected")
        armed.value = true
        await controller.refreshPairedDevices()
        XCTAssertNil(controller.state.pairedDevices)
    }

    // MARK: - Connecting

    private enum Polls: Equatable {
        /// Stops at the first poll that shows the device up.
        case untilUp
        /// Runs to the deadline: no reply ever counted as up.
        case toDeadline
        case none
    }

    private struct ConnectRow {
        let name: String
        var paired: [(name: String, connected: Bool)] = [("MacBook", true), ("iPhone", false)]
        var ownIndex: UInt8 = 0
        var maxConnections: UInt8 = 2
        var pollsToConnect: Int? = 0
        /// The device as the user saw it; defaults to index 1, "iPhone".
        var target = PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false)
        /// Applied to the fake after the list is shown and before the click.
        var changeBeforeClick: ((FakeHeadset) -> Void)?
        var rejects: Set<UInt16> = []
        var statusReply: [UInt8]?
        var pushes = false
        var priorError = false
        var dropOnPoll = false
        /// Drops the link on this list read after the click: 1 before, 2 after.
        var dropOnListRead: Int?
        let sendsConnect: Bool
        let showsError: Bool
        var polls: Polls = .none
    }

    private static let connectRows: [ConnectRow] = [
        ConnectRow(name: "free slot, connects at once", sendsConnect: true, showsError: false, polls: .untilUp),
        ConnectRow(name: "connects after a few polls", pollsToConnect: 4, sendsConnect: true, showsError: false,
                   polls: .untilUp),
        ConnectRow(name: "third of four devices",
                   paired: [("MacBook", true), ("iPhone", false), ("iPad", false), ("PC", false)],
                   target: PairedDevice(index: 2, name: "iPad", isConnected: false, isThisMac: false),
                   sendsConnect: true, showsError: false, polls: .untilUp),
        ConnectRow(name: "connects with the captured pushes", pushes: true, sendsConnect: true, showsError: false,
                   polls: .untilUp),
        ConnectRow(name: "success clears an earlier error", priorError: true, sendsConnect: true,
                   showsError: false, polls: .untilUp),
        ConnectRow(name: "never connects", pollsToConnect: nil, sendsConnect: true, showsError: true,
                   polls: .toDeadline),
        ConnectRow(name: "never connects, with the captured pushes", pollsToConnect: nil, pushes: true,
                   sendsConnect: true, showsError: true, polls: .toDeadline),
        ConnectRow(name: "device rejects the connect", rejects: [Cmd.connectPairedDevice],
                   sendsConnect: true, showsError: true),
        // A poll that fails or misreads is "not up yet", and the fresh list
        // decides. The fake never comes up when it rejects the poll, and
        // does come up behind a misread status.
        ConnectRow(name: "status polls rejected", rejects: [Cmd.getPairedDeviceStatus],
                   sendsConnect: true, showsError: true, polls: .toDeadline),
        ConnectRow(name: "status with the wrong index", statusReply: [9, 1], sendsConnect: true,
                   showsError: false, polls: .toDeadline),
        ConnectRow(name: "status of one byte", statusReply: [1], sendsConnect: true, showsError: false,
                   polls: .toDeadline),
        ConnectRow(name: "status as an empty OK", statusReply: [], sendsConnect: true, showsError: false,
                   polls: .toDeadline),
        ConnectRow(name: "list reordered since it was shown",
                   changeBeforeClick: { $0.paired = [("iPhone", false), ("MacBook", true)]; $0.ownIndex = 1 },
                   sendsConnect: false, showsError: true),
        ConnectRow(name: "device removed since it was shown",
                   changeBeforeClick: { $0.paired = [("MacBook", true)] }, sendsConnect: false, showsError: true),
        ConnectRow(name: "connected elsewhere since it was shown",
                   changeBeforeClick: { $0.paired[1].connected = true }, sendsConnect: false, showsError: false),
        ConnectRow(name: "connected elsewhere clears an earlier error",
                   changeBeforeClick: { $0.paired[1].connected = true }, priorError: true,
                   sendsConnect: false, showsError: false),
        ConnectRow(name: "target is this Mac",
                   target: PairedDevice(index: 0, name: "MacBook", isConnected: true, isThisMac: true),
                   sendsConnect: false, showsError: false),
        ConnectRow(name: "two devices share the name",
                   paired: [("MacBook", true), ("iPhone", false), ("iPhone", false)],
                   sendsConnect: false, showsError: true),
        ConnectRow(name: "shares this Mac's name",
                   paired: [("MacBook", true), ("MacBook", false)],
                   target: PairedDevice(index: 1, name: "MacBook", isConnected: false, isThisMac: false),
                   sendsConnect: false, showsError: true),
        ConnectRow(name: "every slot taken",
                   paired: [("MacBook", true), ("iPhone", true), ("iPad", false)],
                   target: PairedDevice(index: 2, name: "iPad", isConnected: false, isThisMac: false),
                   sendsConnect: false, showsError: true),
        ConnectRow(name: "one slot, already this Mac's", maxConnections: 1, sendsConnect: false, showsError: true),
        ConnectRow(name: "three slots, two taken",
                   paired: [("MacBook", true), ("iPhone", true), ("iPad", false)], maxConnections: 3,
                   target: PairedDevice(index: 2, name: "iPad", isConnected: false, isThisMac: false),
                   sendsConnect: true, showsError: false, polls: .untilUp),
        ConnectRow(name: "limit unknown", rejects: [Cmd.getMaxConnections], sendsConnect: false, showsError: true),
        ConnectRow(name: "this Mac not identified", ownIndex: 1, sendsConnect: false, showsError: true),
        ConnectRow(name: "list unreadable", rejects: [Cmd.getPairedDeviceCount], sendsConnect: false,
                   showsError: true),
        ConnectRow(name: "link drops while polling", pollsToConnect: nil, dropOnPoll: true,
                   sendsConnect: true, showsError: false),
        ConnectRow(name: "link drops reading the list first", dropOnListRead: 1, sendsConnect: false,
                   showsError: false),
        ConnectRow(name: "link drops reading the list after", dropOnListRead: 2, sendsConnect: true,
                   showsError: false),
    ]

    private func runConnect(_ row: ConnectRow) async -> (FakeHeadset, HeadphoneController, FakeTransport) {
        let device = FakeHeadset()
        device.paired = row.paired
        device.ownIndex = row.ownIndex
        device.maxConnections = row.maxConnections
        device.pollsToConnect = row.pollsToConnect
        device.pushesDuringConnect = row.pushes
        let listReads = Box(-1)   // the connect's own read is read 0
        let (controller, fake) = await connected(device) { frame, fake in
            if row.dropOnPoll, frame.command == Cmd.getPairedDeviceStatus {
                fake.drop()
                return []
            }
            if frame.command == Cmd.getPairedDeviceCount {
                listReads.value += 1
                if listReads.value == row.dropOnListRead {
                    fake.drop()
                    return []
                }
            }
            return nil
        }
        if row.priorError {
            await controller.connect(to: PairedDevice(index: 1, name: "Gone", isConnected: false, isThisMac: false))
            XCTAssertNotNil(controller.state.lastError, "\(row.name): the earlier error is set")
        }
        row.changeBeforeClick?(device)
        device.rejects = row.rejects
        device.statusReply = row.statusReply
        await controller.connect(to: row.target)
        return (device, controller, fake)
    }

    func testConnectIsSentOnlyWhenSafe() async {
        for row in Self.connectRows {
            let (_, _, fake) = await runConnect(row)
            let sent = fake.sent.contains { $0.command == Cmd.connectPairedDevice }
            XCTAssertEqual(sent, row.sendsConnect, row.name)
        }
    }

    func testConnectReportsWhatWentWrong() async {
        for row in Self.connectRows {
            let (_, controller, _) = await runConnect(row)
            XCTAssertEqual(controller.state.lastError != nil, row.showsError,
                           "\(row.name): \(controller.state.lastError ?? "no error")")
        }
    }

    /// Polling stops on the first reply that shows the device up, and only
    /// a well-formed reply for the right index counts.
    func testPollingStopsOnceTheDeviceIsUp() async {
        for row in Self.connectRows where row.polls != .none {
            let (_, _, fake) = await runConnect(row)
            let polls = fake.sent.filter { $0.command == Cmd.getPairedDeviceStatus }.count
            switch row.polls {
            case .untilUp: XCTAssertEqual(polls, (row.pollsToConnect ?? 0) + 1, row.name)
            case .toDeadline: XCTAssertGreaterThan(polls, 6, row.name)
            case .none: break
            }
        }
    }

    func testConnectEndsWithTheDevicesWordForIt() async {
        for row in Self.connectRows where !row.dropOnPoll && row.dropOnListRead == nil {
            let (device, controller, _) = await runConnect(row)
            let expected = device.paired.map { "\($0.name) \($0.connected ? "on" : "off")" }
            let shown = controller.state.pairedDevices?.map { "\($0.name) \($0.isConnected ? "on" : "off")" }
            if row.rejects.contains(Cmd.getPairedDeviceCount) {
                XCTAssertNil(shown, row.name)
            } else {
                XCTAssertEqual(shown, expected, row.name)
            }
        }
    }

    func testConnectClearsItsBusyMarkWhenDone() async {
        for row in Self.connectRows {
            let (_, controller, _) = await runConnect(row)
            XCTAssertNil(controller.state.pairedAction, row.name)
        }
    }

    /// The positive for the test above: the mark names the device while
    /// the connect is on the wire.
    func testTheBusyMarkNamesTheDeviceMeanwhile() async {
        let device = FakeHeadset()
        let seen = Box<PairedAction?>(nil)
        let owner = Box<HeadphoneController?>(nil)
        let (controller, _) = await connected(device) { frame, _ in
            if frame.command == Cmd.connectPairedDevice { seen.value = owner.value?.state.pairedAction }
            return nil
        }
        owner.value = controller
        await controller.connect(to: PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false))
        XCTAssertEqual(seen.value, .connecting("iPhone"))
    }

    /// A drop mid-poll ends the connect at once rather than polling a dead
    /// link until the deadline.
    func testALinkDropEndsTheConnectAtOnce() async {
        let row = Self.connectRows.first { $0.dropOnPoll }!
        let start = ContinuousClock.now
        _ = await runConnect(row)
        // runConnect includes connecting; the deadline alone is 500 ms.
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(400))
    }

    // MARK: - Disconnecting

    func testDisconnectNeedsFirmware3383OrNewer() {
        let rows: [(String, [Int]?, Bool)] = [
            ("3.38.3, the captured one", [3, 38, 3], true),
            ("3.38.4", [3, 38, 4], true),
            ("3.40.0", [3, 40, 0], true),
            ("4.0.0", [4, 0, 0], true),
            ("3.38.2", [3, 38, 2], false),
            ("3.37.3, never tested", [3, 37, 3], false),
            ("2.13.42, erased a pairing", [2, 13, 42], false),
            ("unknown", nil, false),
        ]
        for (name, version, allowed) in rows {
            var state = DeviceState()
            state.firmwareVersion = version
            XCTAssertEqual(state.canDisconnectOthers, allowed, name)
        }
    }

    /// The firmware rule holds at the one place every frame passes, not
    /// only in `disconnect(_:)`: a direct request is refused too.
    func testARawDisconnectIsRefusedOnOlderFirmware() async {
        let rows: [(String, [Int]?, Bool)] = [
            ("3.38.3", [3, 38, 3], true),
            ("3.41.0", [3, 41, 0], true),
            ("3.37.3", [3, 37, 3], false),
            ("2.13.42", [2, 13, 42], false),
            ("unknown", nil, false),
        ]
        for (name, firmware, reachesWire) in rows {
            let device = FakeHeadset()
            device.firmware = firmware
            let (controller, fake) = await connected(device)
            _ = try? await controller.request(Cmd.disconnectPairedDevice, payload: [1], timeout: .milliseconds(200))
            XCTAssertEqual(fake.sent.contains { $0.command == Cmd.disconnectPairedDevice }, reachesWire, name)
        }
    }

    private struct DisconnectRow {
        let name: String
        var paired: [(name: String, connected: Bool)] = [("MacBook", true), ("iPhone", true)]
        var ownIndex: UInt8 = 0
        var firmware: [Int]? = [3, 38, 3]
        var pollsToDisconnect: Int? = 0
        var target = PairedDevice(index: 1, name: "iPhone", isConnected: true, isThisMac: false)
        var changeBeforeClick: ((FakeHeadset) -> Void)?
        var rejects: Set<UInt16> = []
        let sendsDisconnect: Bool
        let showsError: Bool
    }

    private static let disconnectRows: [DisconnectRow] = [
        DisconnectRow(name: "phone disconnects", sendsDisconnect: true, showsError: false),
        DisconnectRow(name: "phone disconnects after a few polls", pollsToDisconnect: 3,
                      sendsDisconnect: true, showsError: false),
        DisconnectRow(name: "newer firmware", firmware: [3, 40, 1], sendsDisconnect: true, showsError: false),
        DisconnectRow(name: "third device of three",
                      paired: [("MacBook", true), ("iPad", false), ("iPhone", true)],
                      target: PairedDevice(index: 2, name: "iPhone", isConnected: true, isThisMac: false),
                      sendsDisconnect: true, showsError: false),
        DisconnectRow(name: "firmware 3.37.3", firmware: [3, 37, 3], sendsDisconnect: false, showsError: true),
        DisconnectRow(name: "firmware 2.13.42", firmware: [2, 13, 42], sendsDisconnect: false, showsError: true),
        DisconnectRow(name: "firmware unknown", firmware: nil, sendsDisconnect: false, showsError: true),
        DisconnectRow(name: "never disconnects", pollsToDisconnect: nil, sendsDisconnect: true, showsError: true),
        DisconnectRow(name: "device rejects the disconnect", rejects: [Cmd.disconnectPairedDevice],
                      sendsDisconnect: true, showsError: true),
        DisconnectRow(name: "already disconnected", changeBeforeClick: { $0.paired[1].connected = false },
                      sendsDisconnect: false, showsError: false),
        DisconnectRow(name: "list reordered", changeBeforeClick: { $0.paired.swapAt(0, 1); $0.ownIndex = 1 },
                      sendsDisconnect: false, showsError: true),
        DisconnectRow(name: "two devices share the name",
                      paired: [("MacBook", true), ("iPhone", true), ("iPhone", false)],
                      sendsDisconnect: false, showsError: true),
        // Its own slot must never take 0x1403: it cannot be told apart.
        DisconnectRow(name: "this Mac not identified", ownIndex: 5, sendsDisconnect: false, showsError: true),
        // A misread own index on the phone's connected slot labels the phone
        // as this Mac; its Disconnect then sends nothing.
        DisconnectRow(name: "own index on the phone's slot", ownIndex: 1, sendsDisconnect: false, showsError: false),
        DisconnectRow(name: "list unreadable", rejects: [Cmd.getPairedDeviceCount],
                      sendsDisconnect: false, showsError: true),
    ]

    private func runDisconnect(_ row: DisconnectRow) async -> (HeadphoneController, FakeTransport) {
        let device = FakeHeadset()
        device.paired = row.paired
        device.ownIndex = row.ownIndex
        device.firmware = row.firmware
        device.pollsToConnect = row.pollsToDisconnect
        let (controller, fake) = await connected(device)
        row.changeBeforeClick?(device)
        device.rejects = row.rejects
        await controller.disconnect(row.target)
        return (controller, fake)
    }

    func testDisconnectIsSentOnlyWhenSafe() async {
        for row in Self.disconnectRows {
            let (_, fake) = await runDisconnect(row)
            let sent = fake.sent.contains { $0.command == Cmd.disconnectPairedDevice }
            XCTAssertEqual(sent, row.sendsDisconnect, row.name)
        }
    }

    func testDisconnectReportsWhatWentWrong() async {
        for row in Self.disconnectRows {
            let (controller, _) = await runDisconnect(row)
            XCTAssertEqual(controller.state.lastError != nil, row.showsError,
                           "\(row.name): \(controller.state.lastError ?? "no error")")
        }
    }

    func testDisconnectShowsTheDeviceGone() async {
        for row in Self.disconnectRows where row.sendsDisconnect && !row.showsError {
            let (controller, _) = await runDisconnect(row)
            let phone = controller.state.pairedDevices?.first { $0.name == row.target.name }
            XCTAssertEqual(phone?.isConnected, false, row.name)
        }
    }

    /// This Mac's own Disconnect is the hand-over: the link is released and
    /// no 0x1403 goes out, whatever the firmware.
    func testDisconnectingThisMacHandsOver() async {
        for firmware: [Int]? in [[3, 38, 3], [2, 13, 42], nil] {
            let device = FakeHeadset()
            device.firmware = firmware
            let (controller, fake) = await connected(device)
            await controller.disconnect(PairedDevice(index: 0, name: "MacBook", isConnected: true, isThisMac: true))
            XCTAssertTrue(controller.state.releasedByUser, "\(String(describing: firmware))")
            XCTAssertFalse(fake.sent.contains { $0.command == Cmd.disconnectPairedDevice })
        }
    }

    /// Two clicks at once send one connect: the second is ignored while the
    /// first is under way.
    func testOverlappingConnectsSendOne() async {
        let device = FakeHeadset()
        device.pollsToConnect = 3
        let (controller, _) = await connected(device)
        let target = PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false)
        let first = Task { await controller.connect(to: target) }
        let second = Task { await controller.connect(to: target) }
        _ = await (first.value, second.value)
        XCTAssertEqual(device.connects, [1])
    }
}
