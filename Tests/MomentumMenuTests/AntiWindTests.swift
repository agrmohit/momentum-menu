import XCTest
@testable import M4Core

/// Anti-wind: byte 1 of the mode table, written back as the whole table.
///
/// It has three states (0 off, 1 max, 2 auto), so writing 1 for "on" would
/// silently discard Auto. Every table write is a read-modify-write, so two of
/// them in flight at once could each write back the other's stale entry.
@MainActor
final class AntiWindTests: XCTestCase {

    private enum Action {
        case wind(AntiWind)
        case mode(NoiseMode)

        @MainActor func apply(to controller: HeadphoneController) async {
            switch self {
            case .wind(let setting): await controller.setAntiWind(setting)
            case .mode(let mode): await controller.setNoiseMode(mode)
            }
        }
    }

    private struct Row {
        let name: String
        var start: [UInt8] = [1, 2, 2, 0, 3, 0]
        var acceptsPair = false
        var misread: [UInt8]?
        var rejectsFullTable = false
        let actions: [Action]
        /// Run all actions at once rather than one after another.
        var together = false
        var readDelay: Duration = .zero
        /// Every mode-table write that reaches the device.
        let writes: [[UInt8]]
        /// The device's table at the end.
        let table: [UInt8]
    }

    private static let rows: [Row] = [
        Row(name: "Auto to Max", actions: [.wind(.max)],
            writes: [[1, 1, 2, 0, 3, 0]], table: [1, 1, 2, 0, 3, 0]),
        Row(name: "Auto to Off", actions: [.wind(.off)],
            writes: [[1, 0, 2, 0, 3, 0]], table: [1, 0, 2, 0, 3, 0]),
        Row(name: "Off to Auto", start: [1, 0, 2, 0, 3, 0], actions: [.wind(.auto)],
            writes: [[1, 2, 2, 0, 3, 0]], table: [1, 2, 2, 0, 3, 0]),
        Row(name: "adaptive kept", start: [1, 2, 2, 0, 3, 1], actions: [.wind(.max)],
            writes: [[1, 1, 2, 0, 3, 1]], table: [1, 1, 2, 0, 3, 1]),
        Row(name: "already Auto: nothing written", actions: [.wind(.auto)],
            writes: [], table: [1, 2, 2, 0, 3, 0]),
        Row(name: "pair firmware still writes the whole table", acceptsPair: true, actions: [.wind(.max)],
            writes: [[1, 1, 2, 0, 3, 0]], table: [1, 1, 2, 0, 3, 0]),
        Row(name: "two clicks, last wins", actions: [.wind(.max), .wind(.off)],
            writes: [[1, 1, 2, 0, 3, 0], [1, 0, 2, 0, 3, 0]], table: [1, 0, 2, 0, 3, 0]),
        Row(name: "misread: table too short", misread: [1, 2, 2, 0], actions: [.wind(.max)],
            writes: [], table: [1, 2, 2, 0, 3, 0]),
        Row(name: "misread: ids out of order", misread: [3, 0, 1, 2, 2, 0], actions: [.wind(.max)],
            writes: [], table: [1, 2, 2, 0, 3, 0]),
        Row(name: "device rejects the write", rejectsFullTable: true, actions: [.wind(.max)],
            writes: [[1, 1, 2, 0, 3, 0]], table: [1, 2, 2, 0, 3, 0]),
        // Adaptive's ANC write goes out first, so anti-wind reaches the table
        // first either way; Adaptive's edit must wait and read the new table.
        Row(name: "anti-wind and Adaptive at once", actions: [.wind(.max), .mode(.adaptive)],
            together: true, readDelay: .milliseconds(30),
            writes: [[1, 1, 2, 0, 3, 0], [3, 1], [1, 1, 2, 0, 3, 1]], table: [1, 1, 2, 0, 3, 1]),
        Row(name: "Adaptive and anti-wind at once", actions: [.mode(.adaptive), .wind(.max)],
            together: true, readDelay: .milliseconds(30),
            writes: [[1, 1, 2, 0, 3, 0], [3, 1], [1, 1, 2, 0, 3, 1]], table: [1, 1, 2, 0, 3, 1]),
        Row(name: "anti-wind and Adaptive at once, pair firmware", acceptsPair: true,
            actions: [.wind(.max), .mode(.adaptive)], together: true, readDelay: .milliseconds(30),
            writes: [[1, 1, 2, 0, 3, 0], [3, 1]], table: [1, 1, 2, 0, 3, 1]),
    ]

    private struct Outcome {
        let writes: [[UInt8]]
        let table: [UInt8]
        let shown: AntiWind?
        let device: AntiWind?
    }

    private func run(_ row: Row) async -> Outcome? {
        let device = FakeHeadset()
        device.modeTable = row.start
        device.acceptsModePair = row.acceptsPair
        device.rejectsFullTable = row.rejectsFullTable
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        device.modeTableReply = row.misread
        device.modeTableDelay = row.readDelay

        let work: [Task<Void, Never>]
        if row.together {
            work = row.actions.map { action in Task { await action.apply(to: controller) } }
        } else {
            work = [Task { for action in row.actions { await action.apply(to: controller) } }]
        }
        guard await results(of: work, within: .seconds(10)) != nil else { return nil }
        return Outcome(writes: device.modeWrites, table: device.modeTable,
                       shown: controller.state.antiWind, device: AntiWind(rawValue: device.modeTable[1]))
    }

    func testOnlyTheAntiWindEntryChanges() async {
        for row in Self.rows {
            let outcome = await run(row)
            XCTAssertEqual(outcome?.writes, row.writes, row.name)
        }
    }

    func testDeviceKeepsEveryChange() async {
        for row in Self.rows {
            let outcome = await run(row)
            XCTAssertEqual(outcome?.table, row.table, row.name)
        }
    }

    func testMenuShowsWhatTheDeviceHolds() async {
        for row in Self.rows {
            guard let outcome = await run(row) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            XCTAssertNotNil(outcome.shown, "\(row.name): anti-wind was never read")
            XCTAssertEqual(outcome.shown, outcome.device, row.name)
        }
    }

    private struct ReadRow {
        let name: String
        let table: [UInt8]
        let shown: AntiWind?
    }

    private static let readRows: [ReadRow] = [
        ReadRow(name: "off", table: [1, 0, 2, 0, 3, 0], shown: .off),
        ReadRow(name: "max", table: [1, 1, 2, 0, 3, 1], shown: .max),
        ReadRow(name: "auto", table: [1, 2, 2, 0, 3, 0], shown: .auto),
        ReadRow(name: "a value no app has set", table: [1, 3, 2, 0, 3, 0], shown: nil),
        ReadRow(name: "table too short", table: [1, 2], shown: nil),
        ReadRow(name: "ids out of order", table: [2, 0, 1, 1, 3, 0], shown: nil),
        ReadRow(name: "empty table", table: [], shown: nil),
    ]

    func testRefreshReadsAntiWindFromTheTable() async {
        for row in Self.readRows {
            let device = FakeHeadset()
            device.modeTableReply = row.table
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            XCTAssertEqual(controller.state.antiWind, row.shown, row.name)
        }
    }

    func testPushedTableUpdatesAntiWind() async {
        for row in Self.readRows {
            let device = FakeHeadset()
            device.modeTable = [1, 1, 2, 0, 3, 0]
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            precondition(controller.state.antiWind == .max, "the read before the push must land")
            fake.push(Reply.notification(Cmd.getModeTable, row.table))
            // A malformed push leaves the last good reading alone.
            XCTAssertEqual(controller.state.antiWind, row.shown ?? .max, row.name)
        }
    }

    private struct LevelRow {
        let name: String
        let action: Action
        var acceptsPair = false
        let levelAfterWrite: UInt8?
    }

    private static let levelRows: [LevelRow] = [
        LevelRow(name: "anti-wind write resets the level", action: .wind(.max), levelAfterWrite: 0),
        LevelRow(name: "full-table mode write resets the level", action: .mode(.adaptive), levelAfterWrite: 0),
        LevelRow(name: "pair mode write resets the level", action: .mode(.adaptive), acceptsPair: true,
                 levelAfterWrite: 0),
        LevelRow(name: "write leaves the level alone", action: .wind(.max), levelAfterWrite: nil),
    ]

    /// On FW 3.37.3 any mode-table write set the level to 0 (M4C captures).
    func testLevelIsReadBackAfterATableWrite() async {
        for row in Self.levelRows {
            let device = FakeHeadset()
            device.level = 40
            device.acceptsModePair = row.acceptsPair
            device.levelAfterModeWrite = row.levelAfterWrite
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            precondition(controller.state.noiseLevel == 40, "the level must be read before the write")
            await row.action.apply(to: controller)
            precondition(!device.modeWrites.isEmpty, "the action must write the table")
            XCTAssertEqual(controller.state.noiseLevel, Int(device.level), row.name)
        }
    }

    /// The slider moved while the read-back is out: the read-back's older
    /// answer must not replace the user's level.
    func testSliderMovedDuringTheReadBackWins() async {
        for row in Self.levelRows {
            let device = FakeHeadset()
            device.acceptsModePair = row.acceptsPair
            device.levelAfterModeWrite = row.levelAfterWrite
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()

            // Only the read-back answers late, so the slider's write lands first.
            fake.respond = { [weak fake] frame in
                let replies = device.respond(frame, push: { fake?.push($0) })
                guard frame.command == Cmd.getNoiseLevel else { return replies }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    for reply in replies { fake?.push(reply) }
                }
                return []
            }
            var slider: Task<Void, Never>?
            fake.duringSend = { frame in
                guard frame.command == Cmd.getNoiseLevel, slider == nil else { return }
                slider = Task { await controller.setNoiseLevel(80) }
            }
            await row.action.apply(to: controller)
            guard await results(of: [slider].compactMap { $0 }, within: .seconds(5)) != nil else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            precondition(slider != nil, "the read-back must go out")
            XCTAssertEqual(controller.state.noiseLevel, Int(device.level), row.name)
        }
    }
}
