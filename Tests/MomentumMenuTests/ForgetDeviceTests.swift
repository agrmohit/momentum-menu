import XCTest
@testable import M4Core

/// Forgetting a paired device (0x1405).
///
/// FW 3.38.3 was captured leaving a gap; `FakeHeadset.forgetEffect` also
/// covers the list closing up and an OK that changes nothing.
@MainActor
final class ForgetDeviceTests: XCTestCase {

    private static let untestedFirmware = TransportError.blockedCommand(
        reason: "0x1405 is allowed only on firmware 3.38.3, the version it was tested on").localizedDescription

    private static func describe(_ devices: [PairedDevice]?) -> [String]? {
        devices?.map { "\($0.index) \($0.name) \($0.isConnected ? "on" : "off")\($0.isThisMac ? " mac" : "")" }
    }

    private struct Row {
        let name: String
        var paired: [(name: String, connected: Bool)] = [("MacBook", true), ("iPhone", false)]
        var ownIndex: UInt8 = 0
        var firmware: [Int]? = [3, 38, 3]
        var effect = FakeHeadset.ForgetEffect.leavesGap
        var countRejectsAfterForget = 0
        var target = PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false)
        var changeBeforeClick: ((FakeHeadset) -> Void)?
        var rejects: Set<UInt16> = []
        /// The index 0x1405 went out for, if any.
        let sends: Int?
        let error: String?
        /// "index name on|off [mac]" after the forget; nil when unknown.
        let shown: [String]?
    }

    private static let gone = ["0 MacBook on mac"]

    private static let rows: [Row] = [
        // Happy paths, one per possible effect and position.
        // Regression: the live run on FW 3.38.3. The gap marker and the
        // count that leaves it out made every re-read fail.
        Row(name: "captured: index 2 of five, gap left",
            paired: [("Mohit's S25", true), ("mohit-unifize", true), ("Nishant’s iPhone", false),
                     ("Mohit’s MacBook", false), ("motoji", false)],
            ownIndex: 1, target: PairedDevice(index: 2, name: "Nishant’s iPhone", isConnected: false, isThisMac: false),
            sends: 2, error: nil,
            shown: ["0 Mohit's S25 on", "1 mohit-unifize on mac", "3 Mohit’s MacBook off", "4 motoji off"]),
        Row(name: "phone forgotten, gap left", sends: 1, error: nil, shown: gone),
        Row(name: "phone forgotten, list closes up", effect: .closesUp, sends: 1, error: nil, shown: gone),
        Row(name: "middle device, gap left",
            paired: [("MacBook", true), ("iPhone", false), ("iPad", false)],
            sends: 1, error: nil, shown: ["0 MacBook on mac", "2 iPad off"]),
        Row(name: "middle device, list closes up", paired: [("MacBook", true), ("iPhone", false), ("iPad", false)],
            effect: .closesUp, sends: 1, error: nil, shown: ["0 MacBook on mac", "1 iPad off"]),
        Row(name: "first slot, this Mac after it, list closes up",
            paired: [("iPhone", false), ("MacBook", true), ("iPad", true)], ownIndex: 1, effect: .closesUp,
            target: PairedDevice(index: 0, name: "iPhone", isConnected: false, isThisMac: false),
            sends: 0, error: nil, shown: ["0 MacBook on mac", "1 iPad on"]),
        Row(name: "last of sixteen slots", paired: [("MacBook", true)] + (1..<16).map { ("D\($0)", false) },
            target: PairedDevice(index: 15, name: "D15", isConnected: false, isThisMac: false),
            sends: 15, error: nil,
            shown: ["0 MacBook on mac"] + (1..<15).map { "\($0) D\($0) off" }),
        // The firmware bug Sennheiser's app names: re-reads fail for a while.
        Row(name: "list unreadable twice after the forget", countRejectsAfterForget: 2,
            sends: 1, error: nil, shown: gone),
        // Failures after sending.
        Row(name: "OK that changes nothing", effect: .nothing, sends: 1,
            error: "The headphones did not forget iPhone. It is still in their list.",
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "list never readable after the forget", countRejectsAfterForget: .max, sends: 1,
            error: "Couldn't read the paired devices to check that iPhone was forgotten.", shown: nil),
        Row(name: "headphones reject the forget", rejects: [Cmd.forgetPairedDevice], sends: 1,
            error: TransportError.deviceRejected(command: Cmd.forgetPairedDevice, code: 0x05).localizedDescription,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        // Refused before sending.
        Row(name: "connected device", paired: [("MacBook", true), ("iPhone", true)],
            target: PairedDevice(index: 1, name: "iPhone", isConnected: true, isThisMac: false),
            sends: nil, error: "Disconnect iPhone before forgetting it.",
            shown: ["0 MacBook on mac", "1 iPhone on"]),
        Row(name: "this Mac", target: PairedDevice(index: 0, name: "MacBook", isConnected: true, isThisMac: true),
            sends: nil, error: "Disconnect MacBook before forgetting it.",
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "connected since the list was shown", changeBeforeClick: { $0.paired[1].connected = true },
            sends: nil, error: "Disconnect iPhone before forgetting it.",
            shown: ["0 MacBook on mac", "1 iPhone on"]),
        Row(name: "list reordered", changeBeforeClick: { $0.paired.swapAt(0, 1); $0.ownIndex = 1 },
            sends: nil, error: "The paired devices changed. Check the list and try again.",
            shown: ["0 iPhone off", "1 MacBook on mac"]),
        Row(name: "already gone", changeBeforeClick: { $0.paired.removeLast() },
            sends: nil, error: "The paired devices changed. Check the list and try again.",
            shown: ["0 MacBook on mac"]),
        Row(name: "two devices share the name", paired: [("MacBook", true), ("iPhone", false), ("iPhone", false)],
            sends: nil, error: "Two paired devices are called iPhone, so the app can't tell them apart.",
            shown: ["0 MacBook on mac", "1 iPhone off", "2 iPhone off"]),
        // The own index on the target's slot, which says not connected: a
        // misread flag on this Mac's own slot. Nothing is erased.
        Row(name: "own index on the target's slot", ownIndex: 1, sends: nil,
            error: "Couldn't tell which paired device is this Mac, so nothing was changed.",
            shown: ["0 MacBook on", "1 iPhone off"]),
        Row(name: "this Mac not identified", ownIndex: 5, sends: nil,
            error: "Couldn't tell which paired device is this Mac, so nothing was changed.",
            shown: ["0 MacBook on", "1 iPhone off"]),
        Row(name: "list unreadable before", rejects: [Cmd.getPairedDeviceCount],
            sends: nil, error: "Couldn't read the headphones' paired devices.", shown: nil),
        Row(name: "firmware 3.38.4", firmware: [3, 38, 4], sends: nil,
            error: untestedFirmware,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "firmware 3.40.0", firmware: [3, 40, 0], sends: nil,
            error: untestedFirmware,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "firmware 3.38.2", firmware: [3, 38, 2], sends: nil,
            error: untestedFirmware,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "firmware 2.13.42", firmware: [2, 13, 42], sends: nil,
            error: untestedFirmware,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
        Row(name: "firmware unknown", firmware: nil, sends: nil,
            error: untestedFirmware,
            shown: ["0 MacBook on mac", "1 iPhone off"]),
    ]

    private func run(_ row: Row) async -> (HeadphoneController, FakeTransport, Bool) {
        let device = FakeHeadset()
        device.paired = row.paired
        device.ownIndex = row.ownIndex
        device.firmware = row.firmware
        device.forgetEffect = row.effect
        let (controller, fake) = await connectedController(device)
        row.changeBeforeClick?(device)
        device.rejects = row.rejects
        device.countRejectsAfterForget = row.countRejectsAfterForget
        let forgotten = await controller.forget(row.target)
        return (controller, fake, forgotten)
    }

    func testForgetIsSentOnlyWhenSafe() async {
        for row in Self.rows {
            let (_, fake, _) = await run(row)
            let sent = fake.sent.filter { $0.command == Cmd.forgetPairedDevice }.map(\.payload)
            XCTAssertEqual(sent, row.sends.map { [[UInt8($0)]] } ?? [], row.name)
        }
    }

    func testForgetReportsWhatWentWrong() async {
        for row in Self.rows {
            let (controller, _, _) = await run(row)
            XCTAssertEqual(controller.state.lastError, row.error, row.name)
        }
    }

    func testForgetSaysWhetherTheNameIsGone() async {
        for row in Self.rows {
            let (_, _, forgotten) = await run(row)
            XCTAssertEqual(forgotten, row.sends != nil && row.error == nil, row.name)
        }
    }

    func testForgetLeavesTheListAsTheHeadphonesHaveIt() async {
        for row in Self.rows {
            let (controller, _, _) = await run(row)
            XCTAssertEqual(Self.describe(controller.state.pairedDevices), row.shown, row.name)
        }
    }

    func testForgetClearsItsBusyMarkWhenDone() async {
        for row in Self.rows {
            let (controller, _, _) = await run(row)
            XCTAssertNil(controller.state.pairedAction, row.name)
        }
    }

    // MARK: - Overlap and the link

    /// The positive for the test above: the mark names the device while
    /// the forget is on the wire.
    func testTheBusyMarkNamesTheDeviceMeanwhile() async {
        let device = FakeHeadset()
        device.firmware = [3, 38, 3]
        let (controller, _) = await connectedController(device)
        device.onForget = { [weak controller] _ in
            XCTAssertEqual(controller?.state.pairedAction, .forgetting("iPhone"))
            XCTAssertEqual(controller?.state.pairedSummary, "Forgetting iPhone")
        }
        await controller.forget(PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false))
        XCTAssertEqual(device.forgets, [1])
    }

    /// Two clicks before the first finishes send one forget, as do a
    /// forget and a connect started together.
    func testOverlappingActionsSendOne() async {
        let rows: [(String, Bool)] = [("forget twice", false), ("forget, then connect", true)]
        for (name, connectToo) in rows {
            let device = FakeHeadset()
            device.firmware = [3, 38, 3]
            device.paired = [("MacBook", true), ("iPhone", false)]
            let (controller, _) = await connectedController(device)
            let phone = PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false)
            let first = Task { await controller.forget(phone) }
            await settle { controller.state.pairedAction != nil }
            if connectToo {
                await controller.connect(to: phone)
            } else {
                _ = await controller.forget(phone)
            }
            _ = await first.value
            XCTAssertEqual(device.forgets, [1], name)
            XCTAssertEqual(device.connects, [], name)
        }
    }

    /// A drop ends the forget quietly: no error, no busy mark. Before the
    /// OK, the send fails; during a re-read, the poll stops.
    func testALinkDropEndsTheForgetQuietly() async {
        let rows: [(String, dropOnReread: Bool)] = [("drop before the OK", false), ("drop during a re-read", true)]
        for (name, dropOnReread) in rows {
            let device = FakeHeadset()
            device.firmware = [3, 38, 3]
            device.forgetEffect = .nothing
            let (controller, fake) = await connectedController(device) { frame, fake in
                guard dropOnReread, !device.forgets.isEmpty, frame.command == Cmd.getPairedDeviceCount else { return nil }
                fake.drop()
                return []
            }
            if !dropOnReread { device.onForget = { _ in Task { @MainActor in fake.drop() } } }
            let forgotten = await controller.forget(
                PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false))
            XCTAssertEqual(device.forgets, [1], name)
            XCTAssertFalse(forgotten, name)
            XCTAssertNil(controller.state.lastError, name)
            XCTAssertNil(controller.state.pairedAction, name)
        }
    }

    /// Without the headphones there is nothing to forget, and no error.
    func testForgetDoesNothingWhileDisconnected() async {
        let device = FakeHeadset()
        device.firmware = [3, 38, 3]
        let (controller, fake) = await connectedController(device)
        fake.drop()
        let forgotten = await controller.forget(
            PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false))
        XCTAssertFalse(forgotten)
        XCTAssertEqual(device.forgets, [])
        XCTAssertNil(controller.state.lastError)
    }

    /// The positive for the test above: the same click while connected
    /// does send.
    func testForgetSendsWhileConnected() async {
        let device = FakeHeadset()
        device.firmware = [3, 38, 3]
        let (controller, _) = await connectedController(device)
        await controller.forget(PairedDevice(index: 1, name: "iPhone", isConnected: false, isThisMac: false))
        XCTAssertEqual(device.forgets, [1])
    }

    /// Regression: the firmware read on one link approved pairing changes on
    /// the next, even when that link's read failed or found new firmware.
    func testOnlyThisLinksFirmwareApprovesAPairingChange() async {
        let rows: [(String, [Int]?, Bool)] = [
            ("still 3.38.3 after the reconnect", [3, 38, 3], true),
            ("updated to 3.40.0 meanwhile", [3, 40, 0], false),
            ("firmware read fails on the new link", nil, false),
        ]
        for command in [Cmd.disconnectPairedDevice, Cmd.forgetPairedDevice] {
            for (name, firmwareAfter, reachesWire) in rows {
                let device = FakeHeadset()
                device.firmware = [3, 38, 3]
                let (controller, fake) = await connectedController(device)
                fake.drop()
                device.firmware = firmwareAfter
                await controller.connect()
                let before = fake.sent.count
                _ = try? await controller.request(command, payload: [1], timeout: .milliseconds(200))
                XCTAssertEqual(fake.sent.dropFirst(before).contains { $0.command == command }, reachesWire,
                               String(format: "0x%04X, %@", command, name))
            }
        }
    }
}
