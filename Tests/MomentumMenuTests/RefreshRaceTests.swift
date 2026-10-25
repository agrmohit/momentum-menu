import XCTest
@testable import M4Core

/// Whether the menu matches the headphones after a user change races a
/// background refresh.
///
/// Regression: `refresh()` read the ANC state, the user's Off landed, and the
/// refresh then wrote its stale "Adaptive" over it. Off on the device, Adaptive
/// in the menu, until the next poll.
@MainActor
final class RefreshRaceTests: XCTestCase {

    private enum Change {
        case mode(NoiseMode)
        case level(Int)
        case bass(Bool)
        case setting(DeviceSetting, Bool)

        @MainActor func apply(to controller: HeadphoneController) async {
            switch self {
            case .mode(let mode): await controller.setNoiseMode(mode)
            case .level(let level): await controller.setNoiseLevel(level)
            case .bass(let on): await controller.setBassBoost(on)
            case .setting(let setting, let on): await controller.set(setting, on: on)
            }
        }
    }

    private struct Shown: Equatable {
        let mode: NoiseMode?
        let level: Int?
        let bass: Bool?
        let settings: [DeviceSetting: Bool]
    }

    private struct Row {
        let name: String
        let startAnc: UInt8
        let startAdaptive: UInt8
        /// The user's change, made when the refresh sends this read.
        let change: Change?
        let during: UInt16?
        /// Made and finished before the refresh starts.
        var before: Change?
        /// A change made on the device by something else (the phone) just
        /// before the refresh.
        var phone: ((FakeHeadset) -> Void)?
        /// Started just before the refresh, and still running as it begins.
        var alongside: Change?
    }

    private static let rows: [Row] = [
        Row(name: "Off during the ANC read", startAnc: 1, startAdaptive: 1,
            change: .mode(.off), during: Cmd.getAncEnabled),
        Row(name: "Custom during the ANC read", startAnc: 1, startAdaptive: 1,
            change: .mode(.custom), during: Cmd.getAncEnabled),
        Row(name: "Adaptive during the ANC read", startAnc: 0, startAdaptive: 0,
            change: .mode(.adaptive), during: Cmd.getAncEnabled),
        Row(name: "Off during the mode-table read", startAnc: 1, startAdaptive: 1,
            change: .mode(.off), during: Cmd.getModeTable),
        Row(name: "level change during the level read", startAnc: 1, startAdaptive: 0,
            change: .level(80), during: Cmd.getNoiseLevel),
        Row(name: "bass on during the bass read", startAnc: 1, startAdaptive: 0,
            change: .bass(true), during: Cmd.getBassBoost),
        Row(name: "no change: the refresh shows the device", startAnc: 1, startAdaptive: 1,
            change: nil, during: nil),
        Row(name: "change finished before the refresh", startAnc: 1, startAdaptive: 1,
            change: nil, during: nil, before: .mode(.off)),
        Row(name: "change during an unrelated read", startAnc: 1, startAdaptive: 1,
            change: .mode(.off), during: Cmd.getFirmwareVersion),
        Row(name: "phone turns ANC back on after a finished user change", startAnc: 1, startAdaptive: 1,
            change: nil, during: nil, before: .mode(.off), phone: { $0.anc = 1 }),
        Row(name: "Off during the ANC read while the phone changed the level", startAnc: 1, startAdaptive: 1,
            change: .mode(.off), during: Cmd.getAncEnabled, phone: { $0.level = 70 }),
        Row(name: "level change during the level read while the phone turned bass on", startAnc: 1,
            startAdaptive: 0, change: .level(80), during: Cmd.getNoiseLevel, phone: { $0.bass = 1 }),
        Row(name: "change already running when the refresh starts", startAnc: 1, startAdaptive: 1,
            change: nil, during: nil, alongside: .mode(.off)),
        // A change keeps only its own field's reading out: the rest still land.
        Row(name: "bass on during the level read while the phone changed the level", startAnc: 1,
            startAdaptive: 0, change: .bass(true), during: Cmd.getNoiseLevel, phone: { $0.level = 70 }),
        Row(name: "level change during the bass read while the phone turned bass on", startAnc: 1,
            startAdaptive: 0, change: .level(80), during: Cmd.getBassBoost, phone: { $0.bass = 1 }),
        Row(name: "Off during the bass read while the phone turned bass on", startAnc: 1, startAdaptive: 1,
            change: .mode(.off), during: Cmd.getBassBoost, phone: { $0.bass = 1 }),
        Row(name: "Comfort Calls during the on-head read while the phone turned on-head off", startAnc: 1,
            startAdaptive: 0, change: .setting(.comfortCalls, true), during: Cmd.getOnHead,
            phone: { $0.settings[Cmd.getOnHead] = 0 }),
        Row(name: "on-head off during the on-head read", startAnc: 1, startAdaptive: 0,
            change: .setting(.onHeadDetection, false), during: Cmd.getOnHead),
        Row(name: "bass on during a settings read while the phone turned touch off", startAnc: 1,
            startAdaptive: 0, change: .bass(true), during: Cmd.getTouchControls,
            phone: { $0.settings[Cmd.getTouchControls] = 1 }),
    ]

    func testMenuMatchesTheDeviceAfterARace() async {
        for row in Self.rows {
            let device = FakeHeadset()
            device.anc = row.startAnc
            device.modeTable[5] = row.startAdaptive
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            await row.before?.apply(to: controller)

            // Only the raced read answers late, so the user's write always lands
            // first and the stale answer always arrives after it.
            fake.respond = { [weak fake] frame in
                let replies = device.respond(frame, push: { fake?.push($0) })
                guard frame.command == row.during else { return replies }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    for reply in replies { fake?.push(reply) }
                }
                return []
            }
            var userChange: Task<Void, Never>?
            fake.duringSend = { frame in
                guard frame.command == row.during, userChange == nil, let change = row.change else { return }
                userChange = Task { await change.apply(to: controller) }
            }

            row.phone?(device)
            let alongside = row.alongside.map { change in Task { await change.apply(to: controller) } }
            let refresh = Task { await controller.refresh() }
            guard await results(of: [refresh] + [alongside].compactMap { $0 }, within: .seconds(5)) != nil,
                  await results(of: userChange.map { [$0] } ?? [], within: .seconds(5)) != nil else {
                XCTFail("\(row.name): did not finish")
                continue
            }

            let shown = Shown(mode: controller.state.noiseMode, level: controller.state.noiseLevel,
                              bass: controller.state.bassBoost, settings: controller.state.settings)
            var settings: [DeviceSetting: Bool] = [:]
            for setting in DeviceSetting.allCases {
                guard let raw = device.settings[setting.getter] else { continue }
                settings[setting] = setting.isInverted ? raw == 0 : raw != 0
            }
            let actual = Shown(mode: device.mode, level: Int(device.level), bass: device.bass != 0,
                               settings: settings)
            XCTAssertEqual(shown, actual, row.name)
        }
    }
}
