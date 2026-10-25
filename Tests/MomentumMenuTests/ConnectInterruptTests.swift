import XCTest
@testable import M4Core

/// A transport whose channel opens only when the test says so, like
/// RFCOMMTransport waiting on `rfcommChannelOpenComplete`. It opens even after
/// a release: the real one went on trying candidate channels.
@MainActor
private final class GatedTransport: GaiaTransport {
    var onFrame: ((GaiaFrame) -> Void)?
    var onDisconnect: (() -> Void)?
    var isOpen = false
    var deviceName: String? = "MOMENTUM 4"
    private(set) var sent: [GaiaFrame] = []
    var gate: CheckedContinuation<Void, Never>?
    /// Holds the model id reply until `answerModel()`.
    var holdModelReply = false
    private var heldReply: GaiaFrame?

    func connect(allowWake: Bool) async throws {
        await withCheckedContinuation { gate = $0 }
        isOpen = true
    }

    func send(_ frame: GaiaFrame) throws {
        guard isOpen else { throw TransportError.notConnected }
        sent.append(frame)
        if frame.command == Cmd.getModelId {
            let reply = Reply.ok(frame.command, Array("M4AEBT Black\0".utf8))
            if holdModelReply { heldReply = reply; return }
            Task { @MainActor in self.onFrame?(reply) }
            return
        }
        let replies = Reply.device(battery: 50)(frame)
        Task { @MainActor in for reply in replies { self.onFrame?(reply) } }
    }

    func answerModel() {
        guard let reply = heldReply else { return }
        heldReply = nil
        onFrame?(reply)
    }

    func disconnect() { isOpen = false }
    func releaseLink() {
        isOpen = false
        deviceName = nil   // RFCOMMTransport.releaseLink forgets the device
    }

    func drop() {
        isOpen = false
        onDisconnect?()
    }
}

/// What a connect does when the user lets go of the headphones, or the link
/// drops, before it finishes.
///
/// Regression: a release while the channel was still opening let the connect
/// carry on. It subscribed, refreshed and took the multipoint slot straight
/// back. A release during the model check showed "not a MOMENTUM 4".
@MainActor
final class ConnectInterruptTests: XCTestCase {

    private enum Interrupt { case none, release, quit, linkDrop }
    private enum Phase { case openingChannel, checkingModel }

    private struct Row {
        let name: String
        let interrupt: Interrupt
        let phase: Phase
    }

    private static let rows: [Row] = [
        Row(name: "no interruption, channel slow to open", interrupt: .none, phase: .openingChannel),
        Row(name: "no interruption, model check slow", interrupt: .none, phase: .checkingModel),
        Row(name: "released while the channel opens", interrupt: .release, phase: .openingChannel),
        Row(name: "released during the model check", interrupt: .release, phase: .checkingModel),
        Row(name: "app quit while the channel opens", interrupt: .quit, phase: .openingChannel),
        Row(name: "app quit during the model check", interrupt: .quit, phase: .checkingModel),
        Row(name: "link dropped during the model check", interrupt: .linkDrop, phase: .checkingModel),
    ]

    private struct Outcome {
        let sentAfterInterrupt: [UInt16]
        let connected: Bool
        let error: String?
        let released: Bool
    }

    private func run(_ row: Row) async -> Outcome? {
        let fake = GatedTransport()
        fake.holdModelReply = row.phase == .checkingModel
        let controller = HeadphoneController(transport: fake)
        let connecting = Task { await controller.connect(userInitiated: true) }
        for _ in 0..<5 { await Task.yield() }

        if row.phase == .checkingModel {
            fake.gate?.resume()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(fake.sent.last?.command, Cmd.getModelId, "\(row.name): not at the model check")
        }
        let mark = fake.sent.count
        switch row.interrupt {
        case .none: break
        case .release: controller.releaseHeadphones()
        case .quit: controller.disconnect()
        case .linkDrop: fake.drop()
        }
        if row.phase == .openingChannel { fake.gate?.resume() }
        fake.answerModel()

        guard await results(of: [connecting], within: .seconds(5)) != nil else { return nil }
        return Outcome(sentAfterInterrupt: fake.sent.dropFirst(mark).map(\.command),
                       connected: controller.state.connected,
                       error: controller.state.lastError,
                       released: controller.state.releasedByUser)
    }

    func testNothingIsSentAfterAnInterruption() async {
        for row in Self.rows where row.interrupt != .none {
            guard let outcome = await run(row) else { XCTFail("\(row.name): did not finish"); continue }
            XCTAssertEqual(outcome.sentAfterInterrupt.map { String(format: "0x%04X", $0) }, [], row.name)
        }
    }

    func testOnlyAnUninterruptedConnectEndsConnected() async {
        for row in Self.rows {
            guard let outcome = await run(row) else { XCTFail("\(row.name): did not finish"); continue }
            XCTAssertEqual(outcome.connected, row.interrupt == .none, row.name)
        }
    }

    func testAnInterruptionShowsNoError() async {
        for row in Self.rows {
            guard let outcome = await run(row) else { XCTFail("\(row.name): did not finish"); continue }
            XCTAssertNil(outcome.error, row.name)
        }
    }

    func testAReleaseStaysReleased() async {
        for row in Self.rows {
            guard let outcome = await run(row) else { XCTFail("\(row.name): did not finish"); continue }
            XCTAssertEqual(outcome.released, row.interrupt == .release, row.name)
        }
    }

    /// The popover shows its controls whenever `connected` is true, so it must
    /// stay false until the model check has passed: a click before then would
    /// write to a device that may yet be refused.
    func testNotConnectedUntilTheModelCheckPasses() async {
        let fake = GatedTransport()
        fake.holdModelReply = true
        let controller = HeadphoneController(transport: fake)
        let connecting = Task { await controller.connect(userInitiated: true) }
        for _ in 0..<5 { await Task.yield() }
        fake.gate?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.sent.last?.command, Cmd.getModelId)
        XCTAssertFalse(controller.state.connected, "connected during the model check")
        XCTAssertTrue(controller.state.isConnecting)
        fake.answerModel()
        _ = await connecting.value
        XCTAssertTrue(controller.state.connected, "not connected once the check passed")
    }
}
