import XCTest
@testable import M4Core

/// What the controller does when the headphones' Bluetooth link comes up.
///
/// Regression: after Bluetooth was turned back on, the popover kept saying
/// "Bluetooth is off" until Try Again or the 60 s poll.
@MainActor
final class LinkUpTests: XCTestCase {

    private enum Before {
        case neverConnected
        case bluetoothOff
        case connected
        case releasedByUser
    }

    private struct Row {
        let name: String
        let before: Before
        let linkUps: Int
        /// What a connect throws after the link comes up; nil opens.
        let connectError: TransportError?
        let connected: Bool
        /// Connects the link-ups start, beyond any in `before`.
        let newConnects: Int
    }

    private static let rows: [Row] = [
        Row(name: "no link-up", before: .neverConnected, linkUps: 0, connectError: nil,
            connected: false, newConnects: 0),
        Row(name: "headphones switched on", before: .neverConnected, linkUps: 1, connectError: nil,
            connected: true, newConnects: 1),
        Row(name: "Bluetooth turned back on", before: .bluetoothOff, linkUps: 1, connectError: nil,
            connected: true, newConnects: 1),
        Row(name: "two link-ups at once", before: .neverConnected, linkUps: 2, connectError: nil,
            connected: true, newConnects: 1),
        Row(name: "already connected", before: .connected, linkUps: 1, connectError: nil,
            connected: true, newConnects: 0),
        Row(name: "handed to another device by the user", before: .releasedByUser, linkUps: 1, connectError: nil,
            connected: false, newConnects: 0),
        Row(name: "channel not ready yet", before: .neverConnected, linkUps: 1,
            connectError: .channelOpenFailed(-1), connected: false, newConnects: 1),
    ]

    private func run(_ row: Row) async -> (FakeTransport, HeadphoneController, Int) {
        let fake = FakeTransport()
        fake.respond = Reply.device(battery: 50)
        let controller = HeadphoneController(transport: fake)
        switch row.before {
        case .neverConnected: break
        case .bluetoothOff:
            fake.connectError = .bluetoothOff
            await controller.connect()
        case .connected:
            await controller.connect()
        case .releasedByUser:
            await controller.connect()
            controller.releaseHeadphones()
        }
        let connectsBefore = fake.connects.count
        fake.connectError = row.connectError
        for _ in 0..<row.linkUps { fake.linkUp() }
        await controller.eventConnect?.value
        return (fake, controller, connectsBefore)
    }

    func testConnectedAfterLinkUp() async {
        for row in Self.rows {
            let (_, controller, _) = await run(row)
            XCTAssertEqual(controller.state.connected, row.connected, row.name)
        }
    }

    func testConnectsStartedByLinkUp() async {
        for row in Self.rows {
            let (fake, _, before) = await run(row)
            XCTAssertEqual(fake.connects.count - before, row.newConnects, row.name)
        }
    }

    /// Waking would pull the headphones off whichever device has them.
    func testLinkUpNeverWakes() async {
        for row in Self.rows {
            let (fake, _, before) = await run(row)
            XCTAssertFalse(fake.connects.dropFirst(before).contains(true), row.name)
        }
    }
}
