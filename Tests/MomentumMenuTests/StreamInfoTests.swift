import XCTest
@testable import M4Core

/// The codec and sample rate of whatever the headphones are playing, from
/// any source device.
///
/// Read with `0x0800` and pushed as `0x0880` (codec) and `0x089A` (rate).
/// Codec numbers are Smart Control's `Sound_CodecUsed` enum; 0xFF means no
/// stream.
@MainActor
final class StreamInfoTests: XCTestCase {

    private struct LabelRow {
        let name: String
        let codec: UInt8?
        let rate: Int?
        let label: String?
    }

    private static let labelRows: [LabelRow] = [
        LabelRow(name: "AAC at 44.1 kHz", codec: 1, rate: 44100, label: "AAC · 44.1 kHz"),
        LabelRow(name: "aptX HD at 48 kHz", codec: 5, rate: 48000, label: "aptX HD · 48 kHz"),
        LabelRow(name: "SBC, the zero value", codec: 0, rate: 44100, label: "SBC · 44.1 kHz"),
        LabelRow(name: "aptX Adaptive", codec: 8, rate: 96000, label: "aptX Adaptive · 96 kHz"),
        LabelRow(name: "LC3, the last known value", codec: 10, rate: 32000, label: "LC3 · 32 kHz"),
        LabelRow(name: "call audio", codec: 1, rate: 16000, label: "AAC · 16 kHz"),
        LabelRow(name: "rate not pushed yet", codec: 2, rate: nil, label: "aptX"),
        LabelRow(name: "stream stopped", codec: 1, rate: 0, label: "AAC"),
        LabelRow(name: "a value outside the enum", codec: 11, rate: 44100, label: "Codec 11 · 44.1 kHz"),
        LabelRow(name: "nothing playing", codec: 0xFF, rate: 44100, label: nil),
        LabelRow(name: "codec unknown", codec: nil, rate: 44100, label: nil),
        LabelRow(name: "nothing known", codec: nil, rate: nil, label: nil),
    ]

    func testLabelNamesCodecAndRate() {
        for row in Self.labelRows {
            var state = DeviceState()
            state.codec = row.codec
            state.sampleRateHz = row.rate
            XCTAssertEqual(state.streamLabel, row.label, row.name)
        }
    }

    private func connected(_ device: FakeHeadset = FakeHeadset()) async -> (HeadphoneController, FakeTransport) {
        let fake = FakeTransport()
        fake.respond = { [weak fake] in device.respond($0, push: { fake?.push($0) }) }
        let controller = HeadphoneController(transport: fake)
        await controller.connect()
        return (controller, fake)
    }

    func testConnectReadsTheCodecAndSubscribesToStreamPushes() async {
        let device = FakeHeadset()
        device.codec = 5
        let (controller, fake) = await connected(device)
        XCTAssertEqual(controller.state.codec, 5)
        XCTAssertTrue(fake.sent.contains(GaiaFrame(command: Cmd.registerNotification, payload: [4])))
    }

    private struct PushRow {
        let name: String
        let pushes: [GaiaFrame]
        let codec: UInt8?
        let rate: Int?
    }

    private static let pushRows: [PushRow] = [
        PushRow(name: "codec change", pushes: [Reply.notification(Cmd.getCodec, [2])], codec: 2, rate: nil),
        PushRow(name: "rate 48 kHz", pushes: [Reply.notification(Cmd.sampleRate, [0, 0, 0xBB, 0x80])],
                codec: 1, rate: 48000),
        PushRow(name: "rate stopped", pushes: [Reply.notification(Cmd.sampleRate, [0, 0, 0, 0])],
                codec: 1, rate: 0),
        PushRow(name: "stream ends", pushes: [Reply.notification(Cmd.getCodec, [0xFF])], codec: 0xFF, rate: nil),
        PushRow(name: "both, rate first",
                pushes: [Reply.notification(Cmd.sampleRate, [0, 0, 0xAC, 0x44]),
                         Reply.notification(Cmd.getCodec, [5])], codec: 5, rate: 44100),
        PushRow(name: "rate cut short is ignored", pushes: [Reply.notification(Cmd.sampleRate, [0, 0xBB, 0x80])],
                codec: 1, rate: nil),
        PushRow(name: "empty codec push is ignored", pushes: [Reply.notification(Cmd.getCodec, [])],
                codec: 1, rate: nil),
    ]

    func testPushesUpdateCodecAndRate() async {
        for row in Self.pushRows {
            let (controller, fake) = await connected()
            guard controller.state.codec == 1 else {
                XCTFail("\(row.name): the codec read must land before the pushes")
                continue
            }
            for push in row.pushes { fake.push(push) }
            XCTAssertTrue(controller.state.codec == row.codec && controller.state.sampleRateHz == row.rate,
                          "\(row.name): codec \(String(describing: controller.state.codec)), "
                          + "rate \(String(describing: controller.state.sampleRateHz))")
        }
    }

    /// Both belong to the link that closed, like the battery.
    func testDisconnectClearsTheStream() async {
        let (controller, fake) = await connected()
        fake.push(Reply.notification(Cmd.sampleRate, [0, 0, 0xAC, 0x44]))
        guard controller.state.streamLabel != nil else { return XCTFail("the stream must be known first") }
        fake.drop()
        XCTAssertNil(controller.state.streamLabel)
    }
}
