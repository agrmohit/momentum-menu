import XCTest
@testable import M4Core

/// The on/off device settings: touch controls, on-head detection, Smart
/// Pause, auto-answer and Comfort Calls.
///
/// Each is read with an odd id and written with the even id below it. Touch
/// controls are inverted on the wire (0 = enabled). None sends a notification,
/// so the menu knows only what it last read or wrote.
@MainActor
final class DeviceSettingTests: XCTestCase {

    private func connected(_ device: FakeHeadset) async -> (HeadphoneController, FakeTransport) {
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        return (controller, fake)
    }

    private struct ReadRow {
        let name: String
        let setting: DeviceSetting
        /// The getter's answer; nil rejects the getter.
        let stored: UInt8?
        let shown: Bool?
    }

    private static let readRows: [ReadRow] = [
        ReadRow(name: "touch 0 is enabled", setting: .touchControls, stored: 0, shown: true),
        ReadRow(name: "touch 1 is disabled", setting: .touchControls, stored: 1, shown: false),
        ReadRow(name: "on-head on", setting: .onHeadDetection, stored: 1, shown: true),
        ReadRow(name: "on-head off", setting: .onHeadDetection, stored: 0, shown: false),
        ReadRow(name: "Smart Pause on", setting: .smartPause, stored: 1, shown: true),
        ReadRow(name: "Smart Pause off", setting: .smartPause, stored: 0, shown: false),
        ReadRow(name: "auto-answer on", setting: .autoAnswer, stored: 1, shown: true),
        ReadRow(name: "auto-answer off", setting: .autoAnswer, stored: 0, shown: false),
        ReadRow(name: "Comfort Calls on", setting: .comfortCalls, stored: 1, shown: true),
        ReadRow(name: "Comfort Calls off", setting: .comfortCalls, stored: 0, shown: false),
        ReadRow(name: "rejected getter is unknown", setting: .smartPause, stored: nil, shown: nil),
        ReadRow(name: "rejected touch getter is unknown", setting: .touchControls, stored: nil, shown: nil),
    ]

    func testRefreshShowsEachSettingAsStored() async {
        for row in Self.readRows {
            let device = FakeHeadset()
            if let stored = row.stored {
                device.settings[row.setting.getter] = stored
            } else {
                device.rejects.insert(row.setting.getter)
            }
            let (controller, _) = await connected(device)
            XCTAssertEqual(controller.state.settings[row.setting], row.shown, row.name)
        }
    }

    func testAGetterWithNoPayloadIsUnknown() async {
        let device = FakeHeadset()
        device.settings[Cmd.getComfortCall] = nil
        let (controller, _) = await connected(device)
        XCTAssertNil(controller.state.settings[.comfortCalls])
        XCTAssertEqual(controller.state.settings[.smartPause], true, "the other settings must still be read")
    }

    private struct WriteRow {
        let name: String
        let setting: DeviceSetting
        let on: Bool
        let frame: GaiaFrame
        var rejected = false
    }

    private static let writeRows: [WriteRow] = [
        WriteRow(name: "touch on", setting: .touchControls, on: true,
                 frame: GaiaFrame(command: 0x1606, payload: [0])),
        WriteRow(name: "touch off", setting: .touchControls, on: false,
                 frame: GaiaFrame(command: 0x1606, payload: [1])),
        WriteRow(name: "on-head on", setting: .onHeadDetection, on: true,
                 frame: GaiaFrame(command: 0x0400, payload: [1])),
        WriteRow(name: "on-head off", setting: .onHeadDetection, on: false,
                 frame: GaiaFrame(command: 0x0400, payload: [0])),
        WriteRow(name: "Smart Pause off", setting: .smartPause, on: false,
                 frame: GaiaFrame(command: 0x080C, payload: [0])),
        WriteRow(name: "auto-answer on", setting: .autoAnswer, on: true,
                 frame: GaiaFrame(command: 0x080A, payload: [1])),
        WriteRow(name: "Comfort Calls on", setting: .comfortCalls, on: true,
                 frame: GaiaFrame(command: 0x0814, payload: [1])),
        WriteRow(name: "rejected write", setting: .autoAnswer, on: true,
                 frame: GaiaFrame(command: 0x080A, payload: [1]), rejected: true),
    ]

    func testWriteSendsOneFrameWithTheWireValue() async {
        for row in Self.writeRows {
            let device = FakeHeadset()
            if row.rejected { device.rejects.insert(row.setting.setter) }
            let (controller, fake) = await connected(device)
            let before = fake.sent.count
            await controller.set(row.setting, on: row.on)
            XCTAssertEqual(Array(fake.sent[before...]), [row.frame], row.name)
        }
    }

    func testMenuShowsWhatTheDeviceHoldsAfterAWrite() async {
        for row in Self.writeRows {
            let device = FakeHeadset()
            if row.rejected { device.rejects.insert(row.setting.setter) }
            let (controller, _) = await connected(device)
            await controller.set(row.setting, on: row.on)
            let stored = device.settings[row.setting.getter]
            let actual = stored.map { row.setting.isInverted ? $0 == 0 : $0 != 0 }
            XCTAssertEqual(controller.state.settings[row.setting], actual, row.name)
            XCTAssertEqual(controller.state.lastError != nil, row.rejected, "\(row.name): error shown")
        }
    }

    /// A toggle made while a refresh's read of it is out: the refresh's older
    /// answer must not replace the user's choice.
    func testToggleDuringItsRefreshReadWins() async {
        for setting in DeviceSetting.allCases {
            let device = FakeHeadset()
            let (controller, fake) = await connected(device)
            let start = controller.state.settings[setting]
            guard start != nil else {
                XCTFail("\(setting): the first read must land")
                continue
            }

            fake.respond = { [weak fake] frame in
                let replies = device.respond(frame, push: { fake?.push($0) })
                guard frame.command == setting.getter else { return replies }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    for reply in replies { fake?.push(reply) }
                }
                return []
            }
            var toggle: Task<Void, Never>?
            fake.duringSend = { frame in
                guard frame.command == setting.getter, toggle == nil, let start else { return }
                toggle = Task { await controller.set(setting, on: !start) }
            }
            let refresh = Task { await controller.refreshSettings() }
            guard await results(of: [refresh], within: .seconds(5)) != nil,
                  await results(of: [toggle].compactMap { $0 }, within: .seconds(5)) != nil else {
                XCTFail("\(setting): did not finish")
                continue
            }
            guard toggle != nil else {
                XCTFail("\(setting): the toggle must start")
                continue
            }
            let stored = device.settings[setting.getter]
            XCTAssertEqual(controller.state.settings[setting],
                           stored.map { setting.isInverted ? $0 == 0 : $0 != 0 }, "\(setting)")
        }
    }
}
