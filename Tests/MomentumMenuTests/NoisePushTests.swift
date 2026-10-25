import XCTest
@testable import M4Core

/// The noise mode the menu shows after the headset's button or the phone app
/// changes it, as told by the ANC (0x1A05) and mode-table (0x1A01) pushes.
///
/// Regression: turning ANC on from the headset while the menu showed Off left
/// it at Off. The ANC push said "on", but only "off" was acted on, and the
/// mode-table push was ignored while the menu said Off.
@MainActor
final class NoisePushTests: XCTestCase {

    private enum Push {
        case anc(UInt8)
        case table(adaptive: UInt8)
    }

    private struct Row {
        let name: String
        let anc: UInt8
        let adaptive: UInt8
        let pushes: [Push]
        let shown: NoiseMode
    }

    private static let rows: [Row] = [
        Row(name: "Off, ANC on, table Adaptive", anc: 0, adaptive: 1, pushes: [.anc(1)], shown: .adaptive),
        Row(name: "Off, ANC on, table Custom", anc: 0, adaptive: 0, pushes: [.anc(1)], shown: .custom),
        Row(name: "Off, table then ANC on", anc: 0, adaptive: 0, pushes: [.table(adaptive: 1), .anc(1)],
            shown: .adaptive),
        Row(name: "Off, ANC on then table", anc: 0, adaptive: 0, pushes: [.anc(1), .table(adaptive: 1)],
            shown: .adaptive),
        Row(name: "Off, table alone", anc: 0, adaptive: 0, pushes: [.table(adaptive: 1)], shown: .off),
        Row(name: "Custom, ANC off", anc: 1, adaptive: 0, pushes: [.anc(0)], shown: .off),
        Row(name: "Custom, ANC on again", anc: 1, adaptive: 0, pushes: [.anc(1)], shown: .custom),
        Row(name: "Adaptive, table Custom", anc: 1, adaptive: 1, pushes: [.table(adaptive: 0)], shown: .custom),
        Row(name: "Custom, table Adaptive", anc: 1, adaptive: 0, pushes: [.table(adaptive: 1)], shown: .adaptive),
        Row(name: "no pushes", anc: 0, adaptive: 1, pushes: [], shown: .off),
    ]

    func testTheMenuFollowsThePushes() async {
        for row in Self.rows {
            let device = FakeHeadset()
            device.anc = row.anc
            device.modeTable = [1, 0, 2, 0, 3, row.adaptive]
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            for push in row.pushes {
                switch push {
                case .anc(let value):
                    fake.push(Reply.notification(Cmd.getAncEnabled, [value]))
                case .table(let adaptive):
                    fake.push(Reply.notification(Cmd.getModeTable, [1, 0, 2, 0, 3, adaptive]))
                }
            }
            XCTAssertEqual(controller.state.noiseMode, row.shown, row.name)
        }
    }
}
