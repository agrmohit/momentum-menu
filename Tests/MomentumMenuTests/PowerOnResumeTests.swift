import XCTest
@testable import M4Core

/// Whether turning Bluetooth back on wakes the headphones onto this Mac.
///
/// Regression: after Bluetooth off and on, headphones still on the phone never
/// relinked to the Mac, and nothing but Try Again would reconnect them. The
/// rule: wake once, only if this Mac had them when Bluetooth went off.
@MainActor
final class PowerOnResumeTests: XCTestCase {

    private enum Event {
        case connect
        /// The channel closing under the app.
        case drop
        case wait(Duration)
        case powerOff
        case powerOn
        /// A release landing after the power-on notice, before its connect runs.
        case powerOnThenRelease
        /// Try Again clicked after the power-on notice, before its connect runs.
        case powerOnThenTryAgain
        /// Power-on while the 60 s poll's connect is opening; that connect fails.
        case powerOnDuringFailingPoll
        /// The 60 s poll's connect.
        case poll
        case release
        /// Makes later connects throw this; nil lets them open.
        case connectsFail(TransportError?)
    }

    private struct Row {
        let name: String
        let events: [Event]
        /// Waking connects started after the setup's own connects.
        let wakes: Int
        let connected: Bool
    }

    private static let rows: [Row] = [
        // Measured on 2026-11-12: the channel closed 150 ms before the
        // power-off broadcast.
        Row(name: "connected, drop then power-off", events: [
            .connect, .drop, .wait(.milliseconds(150)), .powerOff, .powerOn,
        ], wakes: 1, connected: true),
        Row(name: "connected, power-off then drop", events: [
            .connect, .powerOff, .drop, .powerOn,
        ], wakes: 1, connected: true),
        Row(name: "drop just inside the window", events: [
            .connect, .drop, .wait(.milliseconds(1999)), .powerOff, .powerOn,
        ], wakes: 1, connected: true),
        Row(name: "drop exactly at the window", events: [
            .connect, .drop, .wait(.seconds(2)), .powerOff, .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "headphones switched off long before", events: [
            .connect, .drop, .wait(.seconds(30)), .powerOff, .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "never connected", events: [.powerOff, .powerOn], wakes: 0, connected: false),
        Row(name: "power-on with no power-off", events: [.connect, .drop, .powerOn], wakes: 0, connected: false),
        Row(name: "handed off by the user", events: [
            .connect, .release, .powerOff, .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "handed off while Bluetooth is off", events: [
            .connect, .powerOff, .drop, .release, .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "handed off between the power-on notice and its connect", events: [
            .connect, .powerOff, .drop, .powerOnThenRelease,
        ], wakes: 0, connected: false),
        // A non-MOMENTUM 4 GAIA device can close the channel before it counts
        // as connected.
        Row(name: "drop while never connected", events: [.drop, .powerOff, .powerOn], wakes: 0, connected: false),
        Row(name: "power-on just inside the resume limit", events: [
            .connect, .powerOff, .drop, .wait(.seconds(30 * 60 - 1)), .powerOn,
        ], wakes: 1, connected: true),
        Row(name: "power-on exactly at the resume limit", events: [
            .connect, .powerOff, .drop, .wait(.seconds(30 * 60)), .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "power-on days later", events: [
            .connect, .powerOff, .drop, .wait(.seconds(3 * 24 * 3600)), .powerOn,
        ], wakes: 0, connected: false),
        Row(name: "wake fails, then a repeated power-on notice", events: [
            .connect, .powerOff, .drop, .connectsFail(.notConnected), .powerOn, .powerOn,
        ], wakes: 1, connected: false),
        Row(name: "two power-ons", events: [
            .connect, .powerOff, .drop, .powerOn, .powerOn,
        ], wakes: 1, connected: true),
        Row(name: "wake fails, then a second off and on", events: [
            .connect, .powerOff, .drop, .connectsFail(.notConnected), .powerOn, .wait(.seconds(5)),
            .powerOff, .powerOn,
        ], wakes: 1, connected: false),
        // Greptile, PR #3: a busy moment at power-on dropped the wake for good.
        Row(name: "power-on while the poll is connecting; the next poll wakes", events: [
            .connect, .powerOff, .drop, .powerOnDuringFailingPoll, .poll,
        ], wakes: 1, connected: true),
        Row(name: "an unused wake ends at the next power-off", events: [
            .connect, .powerOff, .drop, .powerOnDuringFailingPoll, .wait(.seconds(30)), .powerOff, .powerOn, .poll,
        ], wakes: 0, connected: true),
        Row(name: "Try Again uses up the wake", events: [
            .connect, .powerOff, .drop, .powerOnThenTryAgain, .drop, .poll,
        ], wakes: 1, connected: true),
        Row(name: "Bluetooth still off when the wake runs", events: [
            .connect, .powerOff, .drop, .connectsFail(.bluetoothOff), .powerOn,
        ], wakes: 1, connected: false),
    ]

    private func run(_ row: Row) async -> (wakes: Int, connected: Bool, controller: HeadphoneController) {
        let fake = FakeTransport()
        fake.respond = Reply.device(battery: 50)
        let controller = HeadphoneController(transport: fake)
        var clock = ContinuousClock.now
        controller.now = { clock }
        var setupConnects = 0
        for event in row.events {
            switch event {
            case .connect:
                await controller.connect()
                setupConnects = fake.connects.count
            case .drop: fake.drop()
            case .wait(let duration): clock += duration
            case .powerOff: fake.power(on: false)
            case .powerOn: fake.power(on: true)
            case .powerOnThenRelease:
                fake.power(on: true)
                controller.releaseHeadphones()
            case .powerOnThenTryAgain:
                fake.power(on: true)
                await controller.connect(userInitiated: true)
            case .powerOnDuringFailingPoll:
                fake.connectError = .notConnected
                fake.holdConnects = true
                let poll = Task { await controller.connect() }
                while !fake.isHoldingConnect { await Task.yield() }
                fake.power(on: true)
                await controller.eventConnect?.value
                fake.holdConnects = false
                fake.releaseHeldConnect()
                await poll.value
                fake.connectError = nil
            case .poll: await controller.connect()
            case .release: controller.releaseHeadphones()
            case .connectsFail(let error): fake.connectError = error
            }
            await controller.eventConnect?.value
        }
        let wakes = fake.connects.dropFirst(setupConnects).filter { $0 }.count
        return (wakes, controller.state.connected, controller)
    }

    // MARK: - What the popover says

    private struct MessageRow {
        let name: String
        let events: [Event]
        let message: String?
        let hint: String
    }

    private static let offMessage = TransportError.bluetoothOff.errorDescription
    private static let offHint = DeviceState.bluetoothOffHint
    private static let awayHint = DeviceState.headphonesAwayHint

    /// Greptile, PR #3: an open popover kept the pairing advice after
    /// Bluetooth went off, until the next poll.
    private static let messageRows: [MessageRow] = [
        MessageRow(name: "drop then power-off", events: [.connect, .drop, .powerOff],
                   message: offMessage, hint: offHint),
        MessageRow(name: "power-off then drop", events: [.connect, .powerOff, .drop],
                   message: offMessage, hint: offHint),
        MessageRow(name: "power-off while never connected", events: [.powerOff],
                   message: offMessage, hint: offHint),
        MessageRow(name: "power-off then on, nothing to resume", events: [.powerOff, .powerOn],
                   message: nil, hint: awayHint),
        MessageRow(name: "power-off then on, resume fails", events: [
            .connect, .powerOff, .drop, .connectsFail(.notConnected), .powerOn,
        ], message: TransportError.notConnected.errorDescription, hint: awayHint),
        MessageRow(name: "power-on alone keeps another error", events: [
            .connectsFail(.headphonesNotFound), .poll, .powerOn,
        ], message: TransportError.headphonesNotFound.errorDescription, hint: awayHint),
        MessageRow(name: "power-off twice", events: [.powerOff, .powerOff],
                   message: offMessage, hint: offHint),
    ]

    func testMessageFollowsPower() async {
        for row in Self.messageRows {
            let controller = await run(Row(name: row.name, events: row.events, wakes: 0, connected: false)).controller
            XCTAssertEqual(controller.state.lastError, row.message, row.name)
            XCTAssertEqual(controller.state.disconnectedHint, row.hint, row.name)
        }
    }

    func testWakesOnPowerOn() async {
        for row in Self.rows {
            let result = await run(row)
            XCTAssertEqual(result.wakes, row.wakes, row.name)
        }
    }

    func testConnectedAfterPowerOn() async {
        for row in Self.rows {
            let result = await run(row)
            XCTAssertEqual(result.connected, row.connected, row.name)
        }
    }
}
