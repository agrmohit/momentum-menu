import XCTest
@testable import M4Core

/// The slider label each band shows.
///
/// Regression: the last two sliders both read "6.5k". The device reports
/// centres of 90, 325, 1500, 6500 and 6500 Hz (omarchy-momentum4
/// `PROTOCOL.md`), so the bands now carry Smart Control's labels instead.
final class EqBandLabelTests: XCTestCase {

    private struct Row {
        let name: String
        let id: Int
        let frequencyHz: Int
        let label: String
    }

    private static let rows: [Row] = [
        Row(name: "band 0, device says 90", id: 0, frequencyHz: 90, label: "63"),
        Row(name: "band 1, device says 325", id: 1, frequencyHz: 325, label: "250"),
        Row(name: "band 2, device says 1500", id: 2, frequencyHz: 1500, label: "1k"),
        Row(name: "band 3, device says 6500", id: 3, frequencyHz: 6500, label: "4k"),
        Row(name: "band 4, device also says 6500", id: 4, frequencyHz: 6500, label: "8k"),
        Row(name: "band 4, frequency unread", id: 4, frequencyHz: 0, label: "8k"),
        Row(name: "band past Smart Control's five, under 1k", id: 5, frequencyHz: 400, label: "400"),
        Row(name: "band past Smart Control's five, kHz", id: 5, frequencyHz: 12500, label: "12.5k"),
        Row(name: "band past Smart Control's five, whole kHz", id: 6, frequencyHz: 16000, label: "16k"),
    ]

    func testLabels() {
        for row in Self.rows {
            let band = EqBand(id: row.id, frequencyHz: row.frequencyHz, gainDb: 0)
            XCTAssertEqual(band.label, row.label, row.name)
        }
    }

    func testFiveBandsHaveDistinctLabels() {
        let labels = (0..<5).map { EqBand(id: $0, frequencyHz: 6500, gainDb: 0).label }
        XCTAssertEqual(Set(labels).count, 5)
    }
}
