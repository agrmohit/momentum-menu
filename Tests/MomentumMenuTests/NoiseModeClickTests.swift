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
        precondition(writesBefore == 0, "connecting must not write the mode table")
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
        WriteRow(name: "Adaptive overtaken by Custom", clicks: [.adaptive, .custom], modeWrites: [[3, 0]]),
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
}
