import XCTest
@testable import M4Core

/// Whether the equaliser shown matches the headphones after a preset or a
/// slider move races a background refresh.
///
/// Regression: `refresh()` read the gains, the user clicked a preset, and the
/// refresh then showed its stale gains over the preset. The device held the
/// preset; the popover showed the old curve until the next poll.
@MainActor
final class EqRefreshRaceTests: XCTestCase {

    private static let preset = EqPreset(name: "Test", gains: [3, -2, 0, 1.5, 4], verified: false)
    private static let phone: [Double] = [-1, -1, 2, 2, 0]

    private enum Edit {
        case preset
        case slider(band: Int, db: Double)

        @MainActor func apply(to controller: HeadphoneController) async {
            switch self {
            case .preset: await controller.apply(EqRefreshRaceTests.preset)
            case .slider(let band, let db): await controller.setBandGain(band: band, db: db)
            }
        }
    }

    private struct Row {
        let name: String
        /// The user's edit, made when the refresh sends this read.
        var edit: Edit?
        var during: UInt16?
        /// Made and finished before the refresh starts.
        var before: Edit?
        /// Started just before the refresh, and still running as it begins.
        var alongside: Edit?
        /// A curve the phone sets on the device just before the refresh.
        var phone: [Double]?
        /// Band writes answer late, so one is still out when the gains read goes.
        var slowWrites = false
        let shown: [Double]
    }

    private static func flat(with band: Int, at db: Double) -> [Double] {
        var gains: [Double] = [0, 0, 0, 0, 0]
        gains[band] = db
        return gains
    }

    private static let rows: [Row] = [
        Row(name: "preset during the gains read",
            edit: .preset, during: Cmd.getAllGains, shown: preset.gains),
        Row(name: "preset during a band-frequency read",
            edit: .preset, during: Cmd.getBandFrequency, shown: preset.gains),
        Row(name: "preset during the EQ config read",
            edit: .preset, during: Cmd.getEqConfig, shown: preset.gains),
        Row(name: "slider during the gains read",
            edit: .slider(band: 2, db: -3), during: Cmd.getAllGains, shown: flat(with: 2, at: -3)),
        Row(name: "slider during a band-frequency read",
            edit: .slider(band: 4, db: 5), during: Cmd.getBandFrequency, shown: flat(with: 4, at: 5)),
        Row(name: "preset already writing when the refresh starts",
            alongside: .preset, shown: preset.gains),
        Row(name: "slider already writing when the refresh starts",
            alongside: .slider(band: 0, db: 2), shown: flat(with: 0, at: 2)),
        Row(name: "preset still writing, slowly, when the gains read goes",
            alongside: .preset, slowWrites: true, shown: preset.gains),
        Row(name: "slider still writing, slowly, when the gains read goes",
            alongside: .slider(band: 3, db: -4), slowWrites: true, shown: flat(with: 3, at: -4)),
        Row(name: "preset half written for the gains read, done before the refresh ends",
            during: Cmd.getBandFrequency, alongside: .preset, slowWrites: true, shown: preset.gains),
        Row(name: "no edit: the refresh shows the device",
            shown: [0, 0, 0, 0, 0]),
        Row(name: "no edit: the phone's curve is shown",
            phone: phone, shown: phone),
        Row(name: "preset finished before the refresh, then the phone's curve",
            before: .preset, phone: phone, shown: phone),
        Row(name: "slider finished before the refresh, then the phone's curve",
            before: .slider(band: 1, db: 4), phone: phone, shown: phone),
        Row(name: "preset during an unrelated read",
            edit: .preset, during: Cmd.getFirmwareVersion, shown: preset.gains),
    ]

    func testEqualiserMatchesTheDeviceAfterARace() async {
        for row in Self.rows {
            let device = FakeHeadset()
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            await row.before?.apply(to: controller)

            // Only the raced read answers late, so the user's writes always land
            // first and the stale answer arrives after. Slow band writes take
            // 20 ms each: a whole preset finishes inside five raced reads.
            fake.respond = { [weak fake] frame in
                let replies = device.respond(frame, push: { fake?.push($0) })
                let delay: Duration
                if frame.command == row.during {
                    delay = .milliseconds(50)
                } else if row.slowWrites, frame.command == Cmd.setBandGain {
                    delay = .milliseconds(20)
                } else {
                    return replies
                }
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    for reply in replies { fake?.push(reply) }
                }
                return []
            }
            var userEdit: Task<Void, Never>?
            fake.duringSend = { frame in
                guard frame.command == row.during, userEdit == nil, let edit = row.edit else { return }
                userEdit = Task { await edit.apply(to: controller) }
            }

            if let phone = row.phone { device.bands = phone.map { Gain.encode(db: $0) } }
            let alongside = row.alongside.map { edit in Task { await edit.apply(to: controller) } }
            let refresh = Task { await controller.refresh() }
            guard await results(of: [refresh] + [alongside].compactMap { $0 }, within: .seconds(5)) != nil,
                  await results(of: userEdit.map { [$0] } ?? [], within: .seconds(5)) != nil else {
                XCTFail("\(row.name): did not finish")
                continue
            }

            XCTAssertEqual(controller.state.bands.map(\.gainDb), device.curve, "\(row.name): shown vs device")
            XCTAssertEqual(device.curve, row.shown, "\(row.name): device")
        }
    }
}
