import XCTest
@testable import M4Core

/// Whether the app takes a device on as its headphones.
///
/// Regression: the app used the first paired device advertising the GAIA
/// service and subscribed it to notifications, a state-changing write, without
/// checking what it was. Other Sennheiser products share the service and have
/// different command maps.
@MainActor
final class ModelCheckTests: XCTestCase {

    private enum ModelReply {
        case model(String)
        case rejected
        case silent
    }

    private struct Row {
        let name: String
        let model: ModelReply
        let deviceName: String
        let accepted: Bool
    }

    private static let rows: [Row] = [
        Row(name: "MOMENTUM 4, black", model: .model("M4AEBT Black\0"), deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "MOMENTUM 4, white", model: .model("M4AEBT White\0"), deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "MOMENTUM 4, no terminator", model: .model("M4AEBT"), deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "MOMENTUM 4 renamed by the user", model: .model("M4AEBT Black\0"), deviceName: "My cans",
            accepted: true),
        Row(name: "another model with a borrowed name", model: .model("ACC1 Black\0"), deviceName: "MOMENTUM 4",
            accepted: false),
        Row(name: "a model id that only starts alike", model: .model("M4AEBTX\0"), deviceName: "MOMENTUM 4",
            accepted: false),
        Row(name: "empty model id, MOMENTUM 4 name", model: .model(""), deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "model id rejected, MOMENTUM 4 name", model: .rejected, deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "model id rejected, other name", model: .rejected, deviceName: "ACCENTUM", accepted: false),
        Row(name: "model id unanswered, MOMENTUM 4 name", model: .silent, deviceName: "MOMENTUM 4", accepted: true),
        Row(name: "model id unanswered, no name", model: .silent, deviceName: "", accepted: false),
    ]

    private func connect(_ row: Row) async -> (HeadphoneController, FakeTransport)? {
        let fake = FakeTransport()
        fake.deviceName = row.deviceName
        let device = Reply.device(battery: 50)
        fake.respond = { frame in
            guard frame.command == Cmd.getModelId else { return device(frame) }
            switch row.model {
            case .model(let text): return [Reply.ok(frame.command, Array(text.utf8))]
            case .rejected: return [Reply.rejected(frame.command)]
            case .silent: return []
            }
        }
        let controller = HeadphoneController(transport: fake)
        let connecting = Task { await controller.connect() }
        guard await results(of: [connecting], within: .seconds(5)) != nil else { return nil }
        return (controller, fake)
    }

    func testOnlyAMomentum4IsTakenOn() async {
        for row in Self.rows {
            guard let (controller, _) = await connect(row) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            XCTAssertEqual(controller.state.connected, row.accepted, row.name)
        }
    }

    /// A refused device must not be left holding the control channel open.
    func testOnlyAMomentum4KeepsTheChannel() async {
        for row in Self.rows {
            guard let (_, fake) = await connect(row) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            XCTAssertEqual(fake.isOpen, row.accepted, row.name)
        }
    }

    /// Reads are harmless; anything else sent to a refused device is not.
    func testARefusedDeviceGetsNoWrites() async {
        for row in Self.rows {
            guard let (_, fake) = await connect(row) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            let reads: Set<UInt16> = [Cmd.getModelId]
            let beyondTheCheck = fake.sent.filter { !reads.contains($0.command) }
            XCTAssertEqual(beyondTheCheck.isEmpty, !row.accepted,
                           "\(row.name): sent \(beyondTheCheck.map { String(format: "0x%04X", $0.command) })")
        }
    }
}
