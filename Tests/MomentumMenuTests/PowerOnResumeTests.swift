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
        Row(name: "Bluetooth still off when the wake runs", events: [
            .connect, .powerOff, .drop, .connectsFail(.bluetoothOff), .powerOn,
        ], wakes: 1, connected: false),
    ]

    private func run(_ row: Row) async -> (wakes: Int, connected: Bool) {
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
            case .release: controller.releaseHeadphones()
            case .connectsFail(let error): fake.connectError = error
            }
            await controller.eventConnect?.value
        }
        let wakes = fake.connects.dropFirst(setupConnects).filter { $0 }.count
        return (wakes, controller.state.connected)
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
