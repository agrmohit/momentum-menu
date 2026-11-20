import XCTest
@testable import M4Core

/// The diagnostic frame log (`HeadphoneController.frameLogger`).
@MainActor
final class FrameLogTests: XCTestCase {

    /// Sent frames reach the diagnostic log once they leave. A refused
    /// frame or a failed write never left, so it is not logged as sent.
    func testTheFrameLogShowsWhatWasSent() async {
        let rows: [(String, UInt16, [UInt8], failWrite: Bool, Bool)] = [
            ("an allowed read", Cmd.getPairedDeviceCount, [], false, true),
            ("a refused command", 0x1406, [], false, false),
            ("a write that fails", Cmd.getPairedDeviceCount, [], true, false),
        ]
        for (name, command, payload, failWrite, logged) in rows {
            let (controller, fake) = await connectedController(FakeHeadset())
            if failWrite { fake.duringSend = { _ in throw TransportError.writeFailed(-1) } }
            var lines: [String] = []
            controller.frameLogger = { lines.append($0) }
            _ = try? await controller.request(command, payload: payload, timeout: .milliseconds(200))
            let sent = String(format: "0x%04X  sent", command)
            XCTAssertEqual(lines.contains { $0.hasPrefix(sent) }, logged, name)
        }
    }
}
