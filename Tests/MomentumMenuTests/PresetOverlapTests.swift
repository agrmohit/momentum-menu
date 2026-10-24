import XCTest
@testable import M4Core

/// The equaliser curve the popover and the headphones end up with after
/// presets and slider moves overlap.
///
/// The device echoes a half-applied curve after every band write; those echoes
/// are ignored while a preset is being written. Regressions: a plain flag let
/// the first of two overlapping presets unmute the second one's echoes; and a
/// slider moved mid-preset was overwritten on the device by the preset's later
/// write for that band, while the popover kept showing the slider value.
@MainActor
final class PresetOverlapTests: XCTestCase {

    /// What the device echoes mid-preset: nothing anyone chose.
    private static let halfApplied: [Double] = [-5, -5, -5, -5, -5]
    private static let later: [Double] = [1, 1, 1, 1, 1]

    /// A slider released while a preset is writing `whileWriting`.
    private struct Slider {
        let band: Int
        let db: Double
        let whileWriting: UInt8
    }

    private struct Row {
        let name: String
        let presets: [EqPreset]
        var slider: Slider?
        /// A slider moved first; the presets are clicked while its write is out.
        var sliderFirst: (band: Int, db: Double)?
        /// Band index whose write the device rejects, if any.
        var rejectBand: UInt8?
        /// A curve the phone sets on the device after everything has finished.
        var phoneAfter: [Double]?
        /// False models firmware 2.x, which rejects the equaliser commands.
        var equaliserSupported = true
        let shown: [Double]
        /// The device's curve, when it differs from what is shown.
        var device: [Double]?
    }

    private static func pop(with band: Int, at db: Double) -> [Double] {
        var gains = EqPreset.pop.gains
        gains[band] = db
        return gains
    }

    private static let tenClicks: [EqPreset] = (0..<10).map { $0 % 2 == 0 ? .pop : .treble }

    private static let rows: [Row] = [
        Row(name: "one preset",
            presets: [.pop], shown: EqPreset.pop.gains),
        Row(name: "two presets overlapping",
            presets: [.pop, .bassLift], shown: EqPreset.bassLift.gains),
        Row(name: "three presets overlapping",
            presets: [.pop, .bassLift, .treble], shown: EqPreset.treble.gains),
        Row(name: "the same preset twice",
            presets: [.voice, .voice], shown: EqPreset.voice.gains),
        Row(name: "ten preset clicks in a row",
            presets: tenClicks, shown: EqPreset.treble.gains),
        Row(name: "slider on a band the preset has not reached",
            presets: [.pop], slider: Slider(band: 3, db: -4, whileWriting: 1), shown: pop(with: 3, at: -4)),
        Row(name: "slider on a band the preset already wrote",
            presets: [.pop], slider: Slider(band: 0, db: 3, whileWriting: 2), shown: pop(with: 0, at: 3)),
        Row(name: "slider on the band being written",
            presets: [.pop], slider: Slider(band: 1, db: -1, whileWriting: 1), shown: pop(with: 1, at: -1)),
        Row(name: "preset clicked while a slider write is out",
            presets: [.pop], sliderFirst: (band: 3, db: -4), shown: EqPreset.pop.gains),
        Row(name: "the phone's change after one preset is shown",
            presets: [.pop], phoneAfter: later, shown: later),
        Row(name: "the phone's change after overlapping presets is shown",
            presets: [.pop, .bassLift], phoneAfter: later, shown: later),
        Row(name: "the phone's change after a rejected write is shown",
            presets: [.pop], rejectBand: 2, phoneAfter: later, shown: later),
        Row(name: "a rejected write shows what the device kept",
            presets: [.pop], rejectBand: 2, shown: [0, 2, 0, 0, 0]),
        Row(name: "equaliser unsupported: nothing to show",
            presets: [.pop], equaliserSupported: false, shown: [], device: [0, 0, 0, 0, 0]),
    ]

    func testPopoverAndDeviceEndOnTheLastChoice() async {
        for row in Self.rows {
            let headset = FakeHeadset()
            let fake = FakeTransport()
            let echo = Reply.notification(Cmd.getBandGain, Self.halfApplied.map { Gain.encode(db: $0) })
            fake.respond = { [weak fake] frame in
                if !row.equaliserSupported, frame.command == Cmd.getEqConfig {
                    return [Reply.rejected(frame.command)]
                }
                guard frame.command == Cmd.setBandGain else {
                    return headset.respond(frame, push: { fake?.push($0) })
                }
                if frame.payload.first == row.rejectBand { return [Reply.rejected(frame.command)] }
                return [echo] + headset.respond(frame, push: { fake?.push($0) })
            }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            fake.replyDelay = .milliseconds(5)

            var sliderMove: Task<Void, Never>?
            var applies: [Task<Void, Never>] = []
            fake.duringSend = { frame in
                guard frame.command == Cmd.setBandGain else { return }
                if let first = row.sliderFirst, applies.isEmpty, frame.payload.first == UInt8(first.band) {
                    applies = row.presets.map { preset in Task { await controller.apply(preset) } }
                }
                guard let slider = row.slider, sliderMove == nil,
                      frame.payload.first == slider.whileWriting else { return }
                sliderMove = Task { await controller.setBandGain(band: slider.band, db: slider.db) }
            }

            if let first = row.sliderFirst {
                sliderMove = Task { await controller.setBandGain(band: first.band, db: first.db) }
                _ = await results(of: [sliderMove].compactMap { $0 }, within: .seconds(5))
            } else {
                applies = row.presets.map { preset in Task { await controller.apply(preset) } }
            }
            guard await results(of: applies, within: .seconds(5)) != nil,
                  await results(of: [sliderMove].compactMap { $0 }, within: .seconds(5)) != nil else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            if let curve = row.phoneAfter {
                headset.bands = curve.map { Gain.encode(db: $0) }
                fake.push(Reply.notification(Cmd.getBandGain, headset.bands))
            }

            let shown = controller.state.bands.map(\.gainDb)
            XCTAssertTrue(shown == row.shown && headset.curve == (row.device ?? row.shown),
                          "\(row.name): popover \(shown), device \(headset.curve)")
        }
    }

    private struct WriteCountRow {
        let name: String
        let presets: [EqPreset]
        let bandWrites: Int
    }

    /// Regression rows: superseded presets used to write all five bands each,
    /// so ten clicks queued 50 writes that drained for up to 100 s.
    private static let writeCountRows: [WriteCountRow] = [
        WriteCountRow(name: "one preset", presets: [.pop], bandWrites: 5),
        WriteCountRow(name: "two presets: the first stops after its first band",
                      presets: [.pop, .bassLift], bandWrites: 6),
        WriteCountRow(name: "ten presets: each stops after its first band", presets: tenClicks, bandWrites: 14),
    ]

    func testSupersededPresetsStopWriting() async {
        for row in Self.writeCountRows {
            let headset = FakeHeadset()
            let fake = FakeTransport()
            fake.respond = { [weak fake] in headset.respond($0, push: { fake?.push($0) }) }
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            fake.replyDelay = .milliseconds(5)
            let before = fake.sent.count

            let applies = row.presets.map { preset in Task { await controller.apply(preset) } }
            guard await results(of: applies, within: .seconds(5)) != nil else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            let bandWrites = fake.sent.dropFirst(before).filter { $0.command == Cmd.setBandGain }.count
            XCTAssertEqual(bandWrites, row.bandWrites, row.name)
        }
    }
}
