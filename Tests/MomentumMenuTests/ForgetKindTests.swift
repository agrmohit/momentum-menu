import XCTest
@testable import MomentumMenu

/// Forgetting a device drops only its own saved icon choice.
///
/// `Preferences` is the app's singleton; these names are unique to the test
/// and every row restores what it changed.
@MainActor
final class ForgetKindTests: XCTestCase {

    private struct Row {
        let name: String
        let saved: [String: DeviceKind]
        let forget: String
        var times = 1
        let left: [String: DeviceKind]
    }

    private static let rows: [Row] = [
        Row(name: "the only choice", saved: ["test-Pixel": .tablet], forget: "test-Pixel", left: [:]),
        Row(name: "one of two", saved: ["test-Pixel": .tablet, "test-iPad": .phone], forget: "test-Pixel",
            left: ["test-iPad": .phone]),
        Row(name: "a name never chosen", saved: ["test-iPad": .phone], forget: "test-Pixel",
            left: ["test-iPad": .phone]),
        Row(name: "nothing saved", saved: [:], forget: "test-Pixel", left: [:]),
        Row(name: "forgotten twice", saved: ["test-Pixel": .tablet], forget: "test-Pixel", times: 2, left: [:]),
    ]

    func testForgetKindDropsOnlyThatName() {
        let preferences = Preferences.shared
        let before = preferences.deviceKinds
        defer { preferences.deviceKinds = before }
        for row in Self.rows {
            preferences.deviceKinds = row.saved
            for _ in 0..<row.times { preferences.forgetKind(of: row.forget) }
            XCTAssertEqual(preferences.deviceKinds, row.left, row.name)
        }
    }
}
