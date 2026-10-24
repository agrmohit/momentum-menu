import XCTest
@testable import M4Core

/// Which curve each preset writes, and which preset the device's curve is.
///
/// Regression: the "Pop" button wrote 0/2/2.5/1.5/-2, which is Smart Control's
/// Rock. The expected bytes come from Smart Control as transcribed in
/// omarchy-momentum4's `presets.json`.
final class EqPresetTests: XCTestCase {

    private struct BytesRow {
        let name: String
        let bytes: [UInt8]
    }

    private static let sennheiser: [BytesRow] = [
        BytesRow(name: "Neutral", bytes: [0x00, 0x00, 0x00, 0x00, 0x00]),
        BytesRow(name: "Rock", bytes: [0x00, 0x14, 0x19, 0x0F, 0xEC]),
        BytesRow(name: "Pop", bytes: [0x00, 0xE7, 0x00, 0x19, 0x00]),
        BytesRow(name: "Dance", bytes: [0x23, 0x14, 0xF1, 0x0F, 0x1E]),
        BytesRow(name: "Hip-Hop", bytes: [0x1E, 0x0F, 0xF1, 0x00, 0xF1]),
        BytesRow(name: "Classical", bytes: [0xEC, 0xF1, 0x00, 0x23, 0x28]),
        BytesRow(name: "Movie", bytes: [0x00, 0x00, 0x14, 0x14, 0xEC]),
        BytesRow(name: "Jazz", bytes: [0xE0, 0x00, 0x16, 0x16, 0x00]),
    ]

    func testSennheiserPresetsWriteSmartControlsBytes() {
        for row in Self.sennheiser {
            let preset = EqPreset.all.first { $0.name == row.name }
            XCTAssertEqual(preset?.gains.map { Gain.encode(db: $0) }, row.bytes, row.name)
        }
    }

    func testOnlySennheiserCurvesAreMarkedVerified() {
        let verified = EqPreset.all.filter(\.verified).map(\.name)
        XCTAssertEqual(verified, Self.sennheiser.map(\.name))
    }

    private struct MatchRow {
        let name: String
        let gains: [Double]
        let preset: String?
    }

    private static let matchRows: [MatchRow] = [
        MatchRow(name: "all zero is Neutral", gains: [0, 0, 0, 0, 0], preset: "Neutral"),
        MatchRow(name: "Rock", gains: [0, 2, 2.5, 1.5, -2], preset: "Rock"),
        MatchRow(name: "Pop", gains: [0, -2.5, 0, 2.5, 0], preset: "Pop"),
        MatchRow(name: "Jazz, with its tenths", gains: [-3.2, 0, 2.2, 2.2, 0], preset: "Jazz"),
        MatchRow(name: "one of our own curves", gains: [4, 2, 0, 0, 0], preset: "Bass lift"),
        MatchRow(name: "decoded from the wire", gains: [0x23, 0x14, 0xF1, 0x0F, 0x1E].map(Gain.decode),
                 preset: "Dance"),
        MatchRow(name: "float noise just above a tenth", gains: [0, 2.0000001, 2.5, 1.5, -2], preset: "Rock"),
        MatchRow(name: "float noise just below a tenth", gains: [0, 1.9999999, 2.5, 1.5, -2], preset: "Rock"),
        MatchRow(name: "one band off by a tenth", gains: [0, 2.1, 2.5, 1.5, -2], preset: nil),
        MatchRow(name: "a hand-made curve", gains: [1, 1, 1, 1, 1], preset: nil),
        MatchRow(name: "no bands read yet", gains: [], preset: nil),
        MatchRow(name: "fewer bands than a preset", gains: [0, 0, 0, 0], preset: nil),
        MatchRow(name: "more bands than a preset", gains: [0, 0, 0, 0, 0, 0], preset: nil),
    ]

    func testMatchingNamesThePresetTheDeviceHolds() {
        for row in Self.matchRows {
            XCTAssertEqual(EqPreset.matching(row.gains)?.name, row.preset, row.name)
        }
    }
}
