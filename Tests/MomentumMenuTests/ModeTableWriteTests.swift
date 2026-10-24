import XCTest
@testable import M4Core

/// What the app writes to the mode table, and what it then shows.
///
/// On firmware that rejects the `[3, value]` pair, the app reads the whole
/// table and writes it back with adaptive patched. Regressions: a misread table
/// was written back as is, or skipped while still reporting success, and a
/// read slower than 2 s was abandoned. Captures show replies in 17-40 ms and
/// other tools wait 5 s.
@MainActor
final class ModeTableWriteTests: XCTestCase {

    private struct Row {
        let name: String
        var acceptsPair = false
        /// The table the device reports when read, if not its real one.
        var misread: [UInt8]?
        var readDelay: Duration = .zero
        /// Clicks after connecting, starting from Custom.
        var clicks: [NoiseMode] = [.adaptive]
        /// Every mode-table write that reaches the device, rejected ones included.
        let writes: [[UInt8]]
        /// What the menu shows afterwards.
        let shown: NoiseMode
    }

    private static let start: [UInt8] = [1, 2, 2, 0, 3, 0]

    private static let rows: [Row] = [
        Row(name: "pair accepted", acceptsPair: true,
            writes: [[3, 1]], shown: .adaptive),
        Row(name: "full table, anti-wind kept",
            writes: [[3, 1], [1, 2, 2, 0, 3, 1]], shown: .adaptive),
        Row(name: "full table, remembered for the next click", clicks: [.adaptive, .custom],
            writes: [[3, 1], [1, 2, 2, 0, 3, 1], [1, 2, 2, 0, 3, 0]], shown: .custom),
        Row(name: "full table read slower than 2 s", readDelay: .milliseconds(2500),
            writes: [[3, 1], [1, 2, 2, 0, 3, 1]], shown: .adaptive),
        Row(name: "misread: table too short", misread: [1, 2, 2, 0],
            writes: [[3, 1]], shown: .custom),
        Row(name: "misread: table too long", misread: [1, 2, 2, 0, 3, 0, 4, 0],
            writes: [[3, 1]], shown: .custom),
        Row(name: "misread: ids out of order", misread: [3, 0, 1, 2, 2, 0],
            writes: [[3, 1]], shown: .custom),
        Row(name: "misread: empty table", misread: [],
            writes: [[3, 1]], shown: .custom),
    ]

    private func run(_ row: Row) async -> (writes: [[UInt8]], shown: NoiseMode?)? {
        let device = FakeHeadset()
        device.modeTable = Self.start
        device.acceptsModePair = row.acceptsPair
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        device.modeTableReply = row.misread
        device.modeTableDelay = row.readDelay

        let clicks = Task {
            for mode in row.clicks { await controller.setNoiseMode(mode) }
        }
        guard await results(of: [clicks], within: .seconds(10)) != nil else { return nil }
        return (device.modeWrites, controller.state.noiseMode)
    }

    func testOnlyAWellFormedTableIsWrittenBack() async {
        for row in Self.rows {
            let outcome = await run(row)
            XCTAssertEqual(outcome?.writes, row.writes, row.name)
        }
    }

    func testMenuShowsAModeOnlyOnceTheDeviceTookIt() async {
        for row in Self.rows {
            let outcome = await run(row)
            XCTAssertEqual(outcome?.shown, row.shown, row.name)
        }
    }
}
