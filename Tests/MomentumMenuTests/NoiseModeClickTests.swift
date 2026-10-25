import XCTest
@testable import M4Core

/// Where the menu and the headphones end up after quick noise-mode clicks.
///
/// Regression: each click is two writes (ANC on/off, then the adaptive entry).
/// Clicked quickly, Adaptive's second write landed after Off's, and Adaptive
/// set the menu last: the device was Off while the menu said Adaptive.
@MainActor
final class NoiseModeClickTests: XCTestCase {

    private struct Row {
        let name: String
        let clicks: [NoiseMode]
        var acceptsPair = true
        /// Clicked when the first click's mode-table write goes out, rather
        /// than straight away.
        var duringModeWrite: NoiseMode?
    }

    private static let rows: [Row] = [
        Row(name: "Adaptive", clicks: [.adaptive]),
        Row(name: "Off", clicks: [.off]),
        Row(name: "Custom while already Custom", clicks: [.custom]),
        Row(name: "Adaptive then Off", clicks: [.adaptive, .off]),
        Row(name: "Off then Adaptive", clicks: [.off, .adaptive]),
        Row(name: "Adaptive then Custom", clicks: [.adaptive, .custom]),
        Row(name: "Custom, Adaptive, Off", clicks: [.custom, .adaptive, .off]),
        Row(name: "Off twice", clicks: [.off, .off]),
        Row(name: "Adaptive then Off, full-table firmware", clicks: [.adaptive, .off], acceptsPair: false),
        Row(name: "Off then Adaptive, full-table firmware", clicks: [.off, .adaptive], acceptsPair: false),
        Row(name: "Off while Adaptive's mode-table write is out", clicks: [.adaptive], duringModeWrite: .off),
        Row(name: "Custom while Adaptive's mode-table write is out", clicks: [.adaptive], duringModeWrite: .custom),
    ]

    /// Runs the clicks; returns the controller and the device once all finish.
    private func run(_ row: Row) async -> (HeadphoneController, FakeHeadset)? {
        let device = FakeHeadset()   // starts in Custom: ANC on, adaptive off
        device.acceptsModePair = row.acceptsPair
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        let writesBefore = device.modeWrites.count
        if row.duringModeWrite != nil {
            // The mode-table write is acknowledged last, so the newer click
            // finishes first and the older one must not overwrite it.
            fake.respond = { [weak fake] frame in
                let replies = device.respond(frame, push: { fake?.push($0) })
                guard frame.command == Cmd.setModeTable else { return replies }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    for reply in replies { fake?.push(reply) }
                }
                return []
            }
        }
        // Slow enough that later clicks start before earlier ones finish.
        fake.replyDelay = .milliseconds(5)

        var late: Task<Void, Never>?
        fake.duringSend = { frame in
            guard let mode = row.duringModeWrite, late == nil, frame.command == Cmd.setModeTable else { return }
            late = Task { await controller.setNoiseMode(mode) }
        }
        let clicks = row.clicks.map { mode in Task { await controller.setNoiseMode(mode) } }
        guard await results(of: clicks, within: .seconds(5)) != nil,
              await results(of: [late].compactMap { $0 }, within: .seconds(5)) != nil else { return nil }
        guard writesBefore == 0 else {
            XCTFail("\(row.name): connecting must not write the mode table")
            return nil
        }
        return (controller, device)
    }

    func testMenuAndDeviceEndOnTheLastClick() async {
        for row in Self.rows {
            guard let (controller, device) = await run(row) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            let last = row.duringModeWrite ?? row.clicks.last
            XCTAssertTrue(controller.state.noiseMode == last && device.mode == last,
                          "\(row.name): menu \(String(describing: controller.state.noiseMode)), "
                          + "device \(device.mode), last click \(String(describing: last))")
        }
    }

    private struct WriteRow {
        let name: String
        let clicks: [NoiseMode]
        var acceptsPair = true
        let modeWrites: [[UInt8]]
    }

    /// Any 0x1A00 write, even with unchanged values, turns Transparent Hearing
    /// off and the level to 0 (community captures, FW 3.37.3). So a click that
    /// a newer one has overtaken must not write the table at all.
    private static let writeRows: [WriteRow] = [
        WriteRow(name: "Adaptive alone", clicks: [.adaptive], modeWrites: [[3, 1]]),
        WriteRow(name: "Off alone", clicks: [.off], modeWrites: []),
        WriteRow(name: "Adaptive overtaken by Off", clicks: [.adaptive, .off], modeWrites: []),
        // The device already holds Custom's value, so nothing is written.
        WriteRow(name: "Adaptive overtaken by Custom", clicks: [.adaptive, .custom], modeWrites: []),
        WriteRow(name: "Custom while already Custom", clicks: [.custom], modeWrites: []),
        WriteRow(name: "Off then Custom", clicks: [.off, .custom], modeWrites: []),
        WriteRow(name: "Off overtaken by Adaptive", clicks: [.off, .adaptive], modeWrites: [[3, 1]]),
        WriteRow(name: "Adaptive overtaken by Off, full-table firmware", clicks: [.adaptive, .off],
                 acceptsPair: false, modeWrites: []),
    ]

    func testOvertakenClicksWriteNoModeTable() async {
        for row in Self.writeRows {
            guard let (_, device) = await run(Row(name: row.name, clicks: row.clicks,
                                                  acceptsPair: row.acceptsPair)) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            XCTAssertEqual(device.modeWrites, row.modeWrites, row.name)
        }
    }

    private struct LevelRow {
        let name: String
        let anc: UInt8
        let adaptive: UInt8
        var acceptsPair = true
        let click: NoiseMode
        let levelKept: Bool
    }

    /// Regression: clicking the mode already shown rewrote the adaptive entry,
    /// and that write reset the user's noise level to 0.
    private static let levelRows: [LevelRow] = [
        LevelRow(name: "Custom while Custom", anc: 1, adaptive: 0, click: .custom, levelKept: true),
        LevelRow(name: "Adaptive while Adaptive", anc: 1, adaptive: 1, click: .adaptive, levelKept: true),
        LevelRow(name: "Custom from Off, table already Custom", anc: 0, adaptive: 0, click: .custom, levelKept: true),
        LevelRow(name: "Adaptive from Off, table already Adaptive", anc: 0, adaptive: 1, click: .adaptive,
                 levelKept: true),
        LevelRow(name: "Custom while Custom, full-table firmware", anc: 1, adaptive: 0, acceptsPair: false,
                 click: .custom, levelKept: true),
        LevelRow(name: "Off", anc: 1, adaptive: 0, click: .off, levelKept: true),
        // A real change still writes, and the device's reset still shows.
        LevelRow(name: "Adaptive from Custom", anc: 1, adaptive: 0, click: .adaptive, levelKept: false),
        LevelRow(name: "Custom from Adaptive", anc: 1, adaptive: 1, click: .custom, levelKept: false),
        LevelRow(name: "Adaptive from Off, table Custom", anc: 0, adaptive: 0, click: .adaptive, levelKept: false),
    ]

    /// Connects to a device at level 40 whose mode-table writes reset it to 0,
    /// then clicks.
    private func click(_ row: LevelRow) async -> (HeadphoneController, FakeHeadset) {
        let device = FakeHeadset()
        device.anc = row.anc
        device.modeTable = [1, 0, 2, 0, 3, row.adaptive]
        device.acceptsModePair = row.acceptsPair
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        device.levelAfterModeWrite = 0
        await controller.setNoiseMode(row.click)
        return (controller, device)
    }

    func testOnlyARealModeChangeResetsTheLevel() async {
        for row in Self.levelRows {
            let (_, device) = await click(row)
            XCTAssertEqual(device.level == 40, row.levelKept, "\(row.name): device level \(device.level)")
        }
    }

    func testTheShownLevelMatchesTheDevice() async {
        for row in Self.levelRows {
            let (controller, device) = await click(row)
            XCTAssertEqual(controller.state.noiseLevel, Int(device.level), row.name)
        }
    }

    private struct AwayRow {
        let name: String
        /// The adaptive entry the phone leaves while this Mac is away.
        let phoneAdaptive: UInt8?
        let click: NoiseMode
    }

    /// What this Mac knew of the mode table is dropped with the link: the phone
    /// may change it meanwhile, and a stale "already Custom" would skip the
    /// write the click needs. The reconnect's ANC read fails here, so the
    /// refresh skips the mode table and nothing replaces the old value.
    private static let awayRows: [AwayRow] = [
        AwayRow(name: "phone set Adaptive, click Custom", phoneAdaptive: 1, click: .custom),
        AwayRow(name: "phone set Custom, click Adaptive", phoneAdaptive: 0, click: .adaptive),
        AwayRow(name: "phone changed nothing, click Custom", phoneAdaptive: nil, click: .custom),
        AwayRow(name: "phone changed nothing, click Adaptive", phoneAdaptive: nil, click: .adaptive),
    ]

    func testAModeChangedWhileAwayStillLands() async {
        for row in Self.awayRows {
            let device = FakeHeadset()   // Custom
            let fake = FakeTransport()
            fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            fake.drop()
            if let adaptive = row.phoneAdaptive { device.modeTable[5] = adaptive }
            device.rejects = [Cmd.getAncEnabled]
            await controller.connect()
            await controller.setNoiseMode(row.click)
            XCTAssertEqual(device.mode, row.click, row.name)
        }
    }

    /// The pair of the two above: a skipped write must not skip the mode.
    func testTheClickedModeLands() async {
        for row in Self.levelRows {
            let (controller, device) = await click(row)
            XCTAssertTrue(device.mode == row.click && controller.state.noiseMode == row.click,
                          "\(row.name): device \(device.mode), menu \(String(describing: controller.state.noiseMode))")
        }
    }
}
