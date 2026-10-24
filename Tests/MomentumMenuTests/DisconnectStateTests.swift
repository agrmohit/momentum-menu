import XCTest
@testable import M4Core

/// What the controller still claims, and who is still waiting, once the link
/// is gone.
@MainActor
final class DisconnectStateTests: XCTestCase {

    private enum Ending {
        case channelDrops
        case channelDropsTwice
        case appDisconnects
        case userReleases
        /// The channel closes while a write is under way, and the write fails.
        case channelDropsDuringFailedSend
    }

    private static func end(_ ending: Ending, _ fake: FakeTransport, _ controller: HeadphoneController) {
        switch ending {
        case .channelDrops: fake.drop()
        case .channelDropsTwice:
            fake.drop()
            fake.drop()
        case .appDisconnects: controller.disconnect()
        case .userReleases: controller.releaseHeadphones()
        case .channelDropsDuringFailedSend: break   // armed on the fake before sending
        }
    }

    // MARK: - Battery and charge readings

    private struct ReadingRow {
        let name: String
        let battery: UInt8
        /// The last charging push, or nil if the device never sent one.
        let charging: Bool?
        let ending: Ending
    }

    /// Regression: the popover header shows `batteryPercent` whenever it is
    /// set, so a dropped channel left "Battery 63% · Charging" on screen.
    private static let readingRows: [ReadingRow] = [
        ReadingRow(name: "channel drops, charge never announced", battery: 63, charging: nil, ending: .channelDrops),
        ReadingRow(name: "channel drops while charging", battery: 63, charging: true, ending: .channelDrops),
        ReadingRow(name: "channel drops when known not charging", battery: 63, charging: false, ending: .channelDrops),
        ReadingRow(name: "channel drops when fully charged", battery: 100, charging: true, ending: .channelDrops),
        ReadingRow(name: "channel drops at 0%", battery: 0, charging: false, ending: .channelDrops),
        ReadingRow(name: "channel drops twice", battery: 40, charging: true, ending: .channelDropsTwice),
        ReadingRow(name: "app closes the channel", battery: 63, charging: true, ending: .appDisconnects),
        ReadingRow(name: "user releases the headphones while charging", battery: 63, charging: true,
                   ending: .userReleases),
    ]

    func testNoBatteryReadingOutlivesTheLink() async {
        for row in Self.readingRows {
            let fake = FakeTransport()
            fake.respond = Reply.device(battery: row.battery)
            let controller = HeadphoneController(transport: fake)
            await controller.connect()
            if let charging = row.charging {
                fake.push(Reply.notification(Cmd.chargingNotification, [charging ? 1 : 0]))
            }

            // The negative below means nothing unless there was a reading to clear.
            guard controller.state.batteryPercent == Int(row.battery),
                  controller.state.isCharging == row.charging else {
                XCTFail("\(row.name): no reading before the link ended")
                continue
            }

            Self.end(row.ending, fake, controller)

            let state = controller.state
            XCTAssertTrue(state.batteryPercent == nil && state.isCharging == nil,
                          "\(row.name): still shows battery \(String(describing: state.batteryPercent)), "
                          + "charging \(String(describing: state.isCharging))")
        }
    }

    // MARK: - Requests waiting on the link

    private struct InFlightRow {
        let name: String
        let ending: Ending
        /// Requests issued while the device stays silent.
        let requests: Int
    }

    /// Regression rows: `disconnect()` closes the channel without the delegate
    /// callback, so it used to leave the caller waiting out its timeout. And a
    /// close during a failing write used to resume the caller twice and trap.
    private static let inFlightRows: [InFlightRow] = [
        InFlightRow(name: "app closes the channel mid-request", ending: .appDisconnects, requests: 1),
        InFlightRow(name: "app closes the channel with one queued", ending: .appDisconnects, requests: 2),
        InFlightRow(name: "channel drops mid-request", ending: .channelDrops, requests: 1),
        InFlightRow(name: "channel drops with two queued", ending: .channelDrops, requests: 3),
        InFlightRow(name: "channel drops twice mid-request", ending: .channelDropsTwice, requests: 1),
        InFlightRow(name: "user releases mid-request", ending: .userReleases, requests: 1),
        InFlightRow(name: "channel drops during a failing send", ending: .channelDropsDuringFailedSend, requests: 1),
        InFlightRow(name: "channel drops during a failing send, one queued",
                    ending: .channelDropsDuringFailedSend, requests: 2),
    ]

    func testWaitingRequestsFailAtOnceAsNotConnected() async {
        for row in Self.inFlightRows {
            let fake = FakeTransport()
            fake.isOpen = true
            if row.ending == .channelDropsDuringFailedSend {
                fake.duringSend = { [weak fake] _ in
                    fake?.drop()
                    throw TransportError.notConnected
                }
            }
            let controller = HeadphoneController(transport: fake)

            let started = ContinuousClock.now
            let requests = (0..<row.requests).map { _ in
                Task { () -> String? in
                    do {
                        _ = try await controller.request(Cmd.getBattery, timeout: .seconds(2))
                        return "answered"
                    } catch TransportError.notConnected {
                        let elapsed = ContinuousClock.now - started
                        return elapsed < .milliseconds(500) ? nil : "not connected after \(elapsed)"
                    } catch {
                        return "\(error) after \(ContinuousClock.now - started)"
                    }
                }
            }
            while fake.sent.isEmpty { await Task.yield() }
            Self.end(row.ending, fake, controller)

            let failures = await results(of: requests, within: .seconds(5))
            XCTAssertEqual(failures?.compactMap { $0 }, [], row.name)
        }
    }
}
